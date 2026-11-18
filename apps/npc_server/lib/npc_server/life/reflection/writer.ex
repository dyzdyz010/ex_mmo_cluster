defmodule NpcServer.Life.Reflection.Writer do
  @moduledoc """
  全局系统功能：反思写日记的模型客户端（内容规范 `docs/10-active/cross-cutting/2026-11-13-npc-mind-content-spec.md`
  §10.11 第 4 条、§10.12 的 R2 ①）。发一次 Anthropic Messages 形状的请求，取回模型写的全文；
  提示词由 `NpcServer.Life.Reflection` 拼好传进来，应答的检查（`Reflection.check/2`）、重问与丢弃都在调用方。

  请求照离线测量 S1-X2 实际发过的条件（`docs/10-active/cross-cutting/tools/jev/s1x2_reflect.py` 的 `write_journal`；
  网关核实见 `.demo/observe/npc-slice1-20261112/s1x3/gateway/report.md`）：

      POST <url>（配置给的就是完整的 …/v1/messages 地址）
      x-api-key: <key>
      anthropic-version: 2023-06-01
      content-type: application/json
      {"model", "max_tokens", "system", "messages": [{"role": "user", "content": …}]}

  请求体不带任何思考参数：在 magpie 网关上得到的就是 S1-X2 写作时模型默认的自适应思考（网关核实：显式的思考参数
  与 `max_tokens` 都被网关丢掉）。应答的 `content` 第一块总是空的 `thinking`，因此按块的 `type` 取 `text`、不按位置取；
  `stop_reason` 不是 `"end_turn"` 一律算失败。

  本模块发一次请求，模型回执用量由 `NpcServer.ModelUsage` 记录。失败原因交给调用方处理。

  ## 两种入口形状（`config.api`）

  - `:messages`（缺省）：上面的 Anthropic Messages 形状。
  - `:openai`（OpenAI 兼容 chat completions；2026-11-18 起部署统一用 DeepSeek `deepseek-flash`）：
    `authorization: Bearer <key>`（`NpcServer.Http` 的缺省头），请求体
    `{"model", "max_tokens", "messages": [system, user]}`，`config.reasoning_effort` 给了就随请求发。
    应答取 `choices[0].message.content`（DeepSeek 的思考在另一个字段 `reasoning_content`，不取）；
    `finish_reason` 不是 `"stop"` 一律算失败。发送与用量记录同 Jev 的 `:openai` 入口，经同一个 `NpcServer.ModelUsage.request/4`。
  """
  alias NpcServer.ModelUsage

  # 离线测量与网关核实时请求带的版本（直连上游时必须带；网关不要求）。
  @anthropic_version "2023-06-01"

  # `max_tokens` 管的是“思考 + 正文”的总量。取 2000 的依据（§10.11 第 4 条）：magpie 网关不执行这个参数
  # （核实时设 120，output 仍有 748–814 token 且 `end_turn`）；网关核实的 8 次 output 644–814 token
  # （其中思考 367–476），S1-X2 的思考约 270–640、正文约 300–350。2000 是一个即使被执行也不会截断这些的值。
  # 换到会执行这个参数（或思考参数）的入口时，必须重测写作。
  @max_tokens 2000

  # `:openai` 入口的 `max_tokens`：DeepSeek 会执行这个参数，且它管“思考 + 正文”的总量（DeepSeek Chat Completions
  # 文档；思考模式缺省开、`medium` 映射为 `high`）。日记正文约 300–800 token，思考量未测；8192 与 Jev 的 `:openai`
  # 入口同量级、远大于正文，用尽时以 `{:finish_reason, "length"}` 显式失败而不是截半句。实测后再调（2026-11-18 起）。
  @openai_max_tokens 8192

  @doc """
  写一次日记：`config` 为 `%{url: 完整的 /v1/messages 地址, key: API key, model: 模型名}`（`:messages` 形状），
  或 `%{api: :openai, url: 完整的 chat completions 地址, key:, model:, reasoning_effort: 可选}`，可带 `timeout_ms`
  （单次请求，缺省同 `NpcServer.Http`）、出站车道 `lane` 与 `cacertfile`；`system` 是系统提示词，`user` 是这一问的用户消息。

  `scope` 可给出此次写作的 `cid` 与 `operation`，缺省分别为 nil 和 `:write`。
  成功返回 `{:ok, %{text: 正文, usage: 应答的 usage 原样, tokens: 归一化用量或 nil}}`，
  `text` 是全部 `text` 块按次序连起来的原文
  （同离线脚本的 `"".join`），不去空白、不做检查。失败返回 `{:error, 原因}`，可直接写进日志：

      {:http_status, 状态码, 响应体前 300 字}  非 200
      :timeout                                请求超时
      :pool_timeout                           出站车道在取连接上限内没有空闲连接（请求从未发出）
      :connection_unavailable                 HTTP/2 主机在取连接上限内连不上（DNS、拒绝连接、证书、没协商出 h2）
      {:transport, 原因}                      连接等传输错误（`NpcServer.Http` 的原因原样）
      :invalid_json                           200 但响应体不是 JSON
      :invalid_response                       是 JSON 但不是该形状的应答（Messages 没有 `content` 列表；chat 没有 `choices`）
      {:stop_reason, 实际值}                  Messages：`stop_reason` 不是 "end_turn"（如 "max_tokens"；缺这个字段为 nil）
      {:finish_reason, 实际值}                chat：`finish_reason` 不是 "stop"（如 "length" = `max_tokens` 用尽）
      :no_text                                正常结束，但没有正文（Messages 没有 `text` 块；chat 的 `content` 为空）
  """
  def write(config, system, user, scope \\ %{cid: nil, operation: :write})

  def write(%{api: :openai} = config, system, user, scope) do
    body = %{
      model: config.model,
      max_tokens: @openai_max_tokens,
      messages: [%{role: "system", content: system}, %{role: "user", content: user}]
    }

    body =
      case Map.get(config, :reasoning_effort) do
        nil -> body
        effort -> Map.put(body, :reasoning_effort, to_string(effort))
      end

    config
    |> send_request(body, Map.put(scope, :api, :openai))
    |> answer(&read_chat/2)
  end

  def write(config, system, user, scope) do
    endpoint =
      Map.put(config, :headers, [
        {"x-api-key", config.key},
        {"anthropic-version", @anthropic_version}
      ])

    body = %{
      model: config.model,
      max_tokens: @max_tokens,
      system: system,
      messages: [%{role: "user", content: user}]
    }

    endpoint
    |> send_request(body, Map.put(scope, :api, :messages))
    |> answer(&read/2)
  end

  # 两种形状共用的失败归类；成功应答交给各自的读法。
  defp answer(sent, read) do
    case sent do
      {{:ok, response}, tokens} ->
        read.(response, tokens)

      {{:error, {status, excerpt}}, _} when is_integer(status) ->
        {:error, {:http_status, status, excerpt}}

      {{:error, reason}, _}
      when reason in [:timeout, :pool_timeout, :connection_unavailable, :invalid_json] ->
        {:error, reason}

      {{:error, reason}, _} ->
        {:error, {:transport, reason}}
    end
  end

  # `Http.request/2` 对 200 但不是 JSON 的响应体用 `Jason.decode!` 直接抛错；改它会改变现有调用方的行为，
  # 所以这里只把这一种异常在本模块的边界变成失败原因，别的异常照常抛出。
  defp send_request(endpoint, body, scope) do
    ModelUsage.request(endpoint, body, scope)
  rescue
    Jason.DecodeError -> {{:error, :invalid_json}, nil}
  end

  defp read(%{"stop_reason" => "end_turn", "content" => blocks} = response, tokens)
       when is_list(blocks) do
    case for(%{"type" => "text", "text" => text} <- blocks, do: text) do
      [] -> {:error, :no_text}
      texts -> {:ok, %{text: Enum.join(texts), usage: response["usage"], tokens: tokens}}
    end
  end

  defp read(%{"content" => blocks} = response, _tokens) when is_list(blocks),
    do: {:error, {:stop_reason, response["stop_reason"]}}

  defp read(_response, _tokens), do: {:error, :invalid_response}

  defp read_chat(%{"choices" => [%{"finish_reason" => "stop"} = choice | _]} = response, tokens) do
    case get_in(choice, ["message", "content"]) do
      text when is_binary(text) and text != "" ->
        {:ok, %{text: text, usage: response["usage"], tokens: tokens}}

      _ ->
        {:error, :no_text}
    end
  end

  defp read_chat(%{"choices" => [choice | _]}, _tokens) when is_map(choice),
    do: {:error, {:finish_reason, choice["finish_reason"]}}

  defp read_chat(_response, _tokens), do: {:error, :invalid_response}
end
