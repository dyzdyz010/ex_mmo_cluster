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

  本模块不重试、不重问、不打日志：失败原因原样返回（见 `write/3`），由调用方带上 cid 写进日志。
  """
  alias NpcServer.Http

  # 离线测量与网关核实时请求带的版本（直连上游时必须带；网关不要求）。
  @anthropic_version "2023-06-01"

  # `max_tokens` 管的是“思考 + 正文”的总量。取 2000 的依据（§10.11 第 4 条）：magpie 网关不执行这个参数
  # （核实时设 120，output 仍有 748–814 token 且 `end_turn`）；网关核实的 8 次 output 644–814 token
  # （其中思考 367–476），S1-X2 的思考约 270–640、正文约 300–350。2000 是一个即使被执行也不会截断这些的值。
  # 换到会执行这个参数（或思考参数）的入口时，必须重测写作。
  @max_tokens 2000

  @doc """
  写一次日记：`config` 为 `%{url: 完整的 /v1/messages 地址, key: API key, model: 模型名}`，可带 `timeout_ms`
  （单次请求，缺省同 `NpcServer.Http`）与 `cacertfile`；`system` 是系统提示词，`user` 是这一问的用户消息。

  成功返回 `{:ok, %{text: 正文, usage: 应答的 usage 原样}}`，`text` 是全部 `text` 块按次序连起来的原文
  （同离线脚本的 `"".join`），不去空白、不做检查。失败返回 `{:error, 原因}`，可直接写进日志：

      {:http_status, 状态码, 响应体前 300 字}  非 200
      :timeout                                请求超时
      {:transport, 原因}                      连接等传输错误（`:httpc` 的原因原样）
      :invalid_json                           200 但响应体不是 JSON
      :invalid_response                       是 JSON 但没有 `content` 列表（不是 Messages 应答的形状）
      {:stop_reason, 实际值}                  `stop_reason` 不是 "end_turn"（如 "max_tokens"；缺这个字段为 nil）
      :no_text                                `stop_reason` 是 "end_turn"，但 `content` 里没有 `text` 块
  """
  def write(config, system, user) do
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

    case send_request(endpoint, body) do
      {:ok, response} ->
        read(response)

      {:error, {status, excerpt}} when is_integer(status) ->
        {:error, {:http_status, status, excerpt}}

      {:error, reason} when reason in [:timeout, :invalid_json] ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  # `Http.request/2` 对 200 但不是 JSON 的响应体用 `Jason.decode!` 直接抛错；改它会改变现有调用方的行为，
  # 所以这里只把这一种异常在本模块的边界变成失败原因，别的异常照常抛出。
  defp send_request(endpoint, body) do
    Http.request(endpoint, body)
  rescue
    Jason.DecodeError -> {:error, :invalid_json}
  end

  defp read(%{"stop_reason" => "end_turn", "content" => blocks} = response)
       when is_list(blocks) do
    case for(%{"type" => "text", "text" => text} <- blocks, do: text) do
      [] -> {:error, :no_text}
      texts -> {:ok, %{text: Enum.join(texts), usage: response["usage"]}}
    end
  end

  defp read(%{"content" => blocks} = response) when is_list(blocks),
    do: {:error, {:stop_reason, response["stop_reason"]}}

  defp read(_response), do: {:error, :invalid_response}
end
