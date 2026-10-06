defmodule GateServer.Npc.Http do
  @moduledoc "全局系统功能：NPC 模型适配器共用的 JSON HTTP 发送器，不解释决策或技能。"
  @doc "发送一次请求，返回 JSON 响应或明确的传输错误。"
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

    case :httpc.request(:post, request, [ssl: ssl, timeout: 60_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, response}} -> {:ok, Jason.decode!(response)}
      {:ok, {{_, status, _}, _, response}} -> {:error, {status, String.slice(response, 0, 300)}}
      {:error, reason} -> {:error, reason}
    end
  end
end
