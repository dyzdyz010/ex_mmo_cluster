defmodule NpcServer.Http do
  @moduledoc "全局系统功能：NPC 模型适配器共用的 JSON HTTP 发送器，不解释决策或技能。"
  # 缺省请求超时（毫秒）；endpoint 的 `timeout_ms` 覆盖它。高推理强度的大上下文请求（如 design_house 后几轮）
  # 常超过 60 s：超时的请求已经计费却拿不到结果（2026-10-08 长跑 run03：gpt-6.1-sol / high 设计会话 6 次败 5 次）。
  @timeout_ms 60_000

  @doc "发送一次请求，返回 JSON 响应或明确的传输错误；超时取 endpoint 的 `timeout_ms`（缺省 #{@timeout_ms} ms）。"
  def request(endpoint, body) do
    ssl =
      [
        verify: :verify_peer,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ] ++
        case endpoint do
          %{cacertfile: path} -> [cacertfile: String.to_charlist(path)]
          _ -> [cacerts: :public_key.cacerts_get()]
        end

    headers = [{~c"authorization", String.to_charlist("Bearer " <> endpoint.key)}]

    request =
      {String.to_charlist(endpoint.url), headers, ~c"application/json", Jason.encode!(body)}

    timeout = Map.get(endpoint, :timeout_ms, @timeout_ms)

    case :httpc.request(:post, request, [ssl: ssl, timeout: timeout], body_format: :binary) do
      {:ok, {{_, 200, _}, _, response}} -> {:ok, Jason.decode!(response)}
      {:ok, {{_, status, _}, _, response}} -> {:error, {status, String.slice(response, 0, 300)}}
      {:error, reason} -> {:error, reason}
    end
  end
end
