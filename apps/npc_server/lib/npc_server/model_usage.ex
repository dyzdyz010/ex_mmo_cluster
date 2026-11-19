defmodule NpcServer.ModelUsage do
  @moduledoc "统一记录 NPC 直接模型请求的开始、结束与供应商回执中的 token 用量。"

  require Logger

  @doc """
  执行一次模型请求并返回 `{原发送结果, 用量或 nil}`。上下文包含 `cid`、`operation`、`api` 和可选 `trigger`。

  请求 ID 可在同一节点的一次启动内配对；worker 在途终止时只有开始记录。用量在业务解析前收集，
  `input_tokens` 和 `output_tokens` 为各自的完整计数，缓存分项同时可见。缺少有效计数时用量为 nil。

  两条记录都带出站车道 `lane`（`NpcServer.Http.lane/1`）；结束记录另带 `queue_ms`：从车道的 HTTP/1 池取连接等了多久
  （`NpcServer.Http.with_queue_ms/1`），HTTP/2 或注入的发送函数为 nil。取不到连接时 `status` 为 `pool_timeout`，
  HTTP/2 连不上时为 `connection_unavailable`。

  用量不为 nil 时，结束记录同时交给花费额度（`NpcServer.SpendBudget.record/1`，cast）记账；`:answers` 形状没有缓存分项，
  按命中 0 计。计价用请求时配置的模型名（`request_model`，即 `SpendBudget.Config` 启动时核过在价目表里的那个名字），
  不用应答里回报的名字（供应商常回报带版本号的名字，如配置 `jev-test`、应答 `jev-1.14.0`）。

  这里是产品用量进花费额度的信任边界：四项计数按 `SpendBudget.Price.tokens/1`（与 Hindsight 追踪行同一份规则）校验一次。
  不合法（如命中多于输入）时打 `npc_model_usage_invalid`（只带计数，不带内容），返回给调用方的用量为 nil，这一笔仍交给额度、
  按未定价记账（`nano_usd` 为空，当日后台按 `:unpriced` 停）——不能算出负金额，也不能当没花过。
  """
  def request(
        endpoint,
        body,
        %{cid: _, operation: _, api: api} = scope,
        send_fn \\ &NpcServer.Http.request/2
      ) do
    fields =
      scope
      |> Map.take([:cid, :operation, :api, :trigger])
      |> Map.merge(%{
        node: node(),
        request_id: System.unique_integer([:positive, :monotonic]),
        request_model: model(Map.get(endpoint, :model)),
        lane: NpcServer.Http.lane(endpoint)
      })

    started_at = System.monotonic_time(:millisecond)
    log(Map.put(fields, :event, :started))

    {result, queue_ms} =
      NpcServer.Http.with_queue_ms(fn ->
        try do
          send_fn.(endpoint, body)
        rescue
          error in Jason.DecodeError ->
            finish(fields, started_at, %{status: :invalid_json}, nil, nil)
            reraise error, __STACKTRACE__
        end
      end)

    {outcome, usage} = response(result, api)
    {result, finish(fields, started_at, outcome, usage, queue_ms)}
  end

  # 写结束记录并把用量交给花费额度；返回给调用方的用量（不合法的为 nil）。
  defp finish(fields, started_at, outcome, usage, queue_ms) do
    tokens = tokens(usage)
    usage = if match?({:invalid, _}, tokens), do: nil, else: usage

    finished =
      fields
      |> Map.merge(%{
        event: :finished,
        duration_ms: System.monotonic_time(:millisecond) - started_at,
        queue_ms: queue_ms,
        response_model: nil,
        usage: usage
      })
      |> Map.merge(outcome)

    log(finished)

    case tokens do
      nil ->
        :ok

      {:invalid, raw} ->
        Logger.warning(
          "npc_model_usage_invalid request_id=#{finished.request_id} operation=#{finished.operation} " <>
            "input_tokens=#{raw.input} cached_tokens=#{raw.cached} output_tokens=#{raw.output}"
        )

        spend(finished, tokens)

      {:ok, _} ->
        spend(finished, tokens)
    end

    usage
  end

  # 规范化用量 → 计价的四项（`input` 含命中，`output` 已含推理、`thoughts` 交 0），经 `Price.tokens/1` 校验：
  # `{:ok, 四项}`、`{:invalid, 原样四项}` 或没有用量时 nil。
  defp tokens(nil), do: nil

  defp tokens(usage) do
    raw = %{
      input: usage.input_tokens,
      cached: Map.get(usage, :cache_read_input_tokens, 0),
      output: usage.output_tokens,
      thoughts: 0
    }

    case NpcServer.SpendBudget.Price.tokens(raw) do
      {:ok, tokens} -> {:ok, tokens}
      :error -> {:invalid, raw}
    end
  end

  # 有用量的回执交给花费额度（`NpcServer.SpendBudget`），按请求时配置的模型名计价；没有用量的请求不计（决策稿 §7 的残余少计）。
  # 只记账，不拦请求——拒绝点在 Life 的后台触发处。
  defp spend(finished, tokens) do
    NpcServer.SpendBudget.record(%{
      request_id: finished.request_id,
      cid: finished[:cid],
      operation: finished.operation,
      model: finished.request_model,
      tokens: tokens,
      duration_ms: finished.duration_ms
    })
  end

  defp log(fields), do: Logger.info(fn -> "npc_model_request " <> Jason.encode!(fields) end)

  defp response({:ok, response}, api) when is_map(response) do
    outcome = %{status: :response, response_model: model(response["model"])}
    {outcome, usage(api, response["usage"])}
  end

  defp response({:ok, _}, _api), do: {%{status: :response}, nil}

  defp response({:error, {code, _}}, _api) when is_integer(code),
    do: {%{status: :http_error, status_code: code}, nil}

  defp response({:error, reason}, _api)
       when reason in [:timeout, :pool_timeout, :connection_unavailable, :invalid_json],
       do: {%{status: reason}, nil}

  defp response({:error, _}, _api), do: {%{status: :transport_error}, nil}

  defp usage(:answers, %{"input_tokens" => input, "output_tokens" => output})
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0,
       do: %{input_tokens: input, output_tokens: output}

  # Messages 的普通输入不含缓存读取与写入，输出已包含推理。
  defp usage(:messages, %{"input_tokens" => input, "output_tokens" => output} = usage)
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0 do
    with read when is_integer(read) and read >= 0 <-
           cache_tokens(usage, "cache_read_input_tokens"),
         creation when is_integer(creation) and creation >= 0 <-
           cache_tokens(usage, "cache_creation_input_tokens") do
      %{
        input_tokens: input + read + creation,
        output_tokens: output,
        cache_read_input_tokens: read,
        cache_creation_input_tokens: creation
      }
    else
      _ -> nil
    end
  end

  # Chat Completions 的缓存命中已包含在提示 token 中。DeepSeek 给出同一分项的顶层字段。
  defp usage(:openai, %{"prompt_tokens" => input, "completion_tokens" => output} = usage)
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0 do
    counts = %{input_tokens: input, output_tokens: output}

    case chat_cache_tokens(usage) do
      cached when is_integer(cached) and cached >= 0 ->
        Map.put(counts, :cache_read_input_tokens, cached)

      _ ->
        counts
    end
  end

  defp usage(_, _), do: nil

  defp cache_tokens(usage, key) do
    case Map.get(usage, key) do
      nil -> 0
      count -> count
    end
  end

  defp chat_cache_tokens(%{"prompt_tokens_details" => %{"cached_tokens" => cached}})
       when not is_nil(cached),
       do: cached

  defp chat_cache_tokens(usage), do: usage["prompt_cache_hit_tokens"]

  defp model(name) when is_binary(name), do: name
  defp model(_), do: nil
end
