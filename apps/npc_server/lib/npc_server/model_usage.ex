defmodule NpcServer.ModelUsage do
  @moduledoc "统一记录 NPC 直接模型请求的开始、结束与供应商回执中的 token 用量。"

  require Logger

  @doc """
  执行一次模型请求并返回 `{原发送结果, 用量或 nil}`。上下文包含 `cid`、`operation`、`api` 和可选 `trigger`。

  请求 ID 可在同一节点的一次启动内配对；worker 在途终止时只有开始记录。用量在业务解析前收集，
  `input_tokens` 和 `output_tokens` 为各自的完整计数，缓存分项同时可见。缺少有效计数时用量为 nil。
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
        request_model: model(Map.get(endpoint, :model))
      })

    started_at = System.monotonic_time(:millisecond)
    log(Map.put(fields, :event, :started))

    result =
      try do
        send_fn.(endpoint, body)
      rescue
        error in Jason.DecodeError ->
          finish(fields, started_at, %{status: :invalid_json}, nil)
          reraise error, __STACKTRACE__
      end

    {outcome, usage} = response(result, api)
    finish(fields, started_at, outcome, usage)
    {result, usage}
  end

  defp finish(fields, started_at, outcome, usage) do
    fields
    |> Map.merge(%{
      event: :finished,
      duration_ms: System.monotonic_time(:millisecond) - started_at,
      response_model: nil,
      usage: usage
    })
    |> Map.merge(outcome)
    |> log()
  end

  defp log(fields), do: Logger.info(fn -> "npc_model_request " <> Jason.encode!(fields) end)

  defp response({:ok, response}, api) when is_map(response) do
    outcome = %{status: :response, response_model: model(response["model"])}
    {outcome, usage(api, response["usage"])}
  end

  defp response({:ok, _}, _api), do: {%{status: :response}, nil}

  defp response({:error, {code, _}}, _api) when is_integer(code),
    do: {%{status: :http_error, status_code: code}, nil}

  defp response({:error, reason}, _api) when reason in [:timeout, :invalid_json],
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
