defmodule AuthServerWeb.Plugs.ClientIp do
  @moduledoc """
  全局系统功能：反向代理后的真实来源地址。

  公网部署由同机 nginx 转发（对端为回环地址），nginx 用 `proxy_set_header X-Real-IP $remote_addr`
  覆盖该头。只信任回环对端给出的 X-Real-IP；直连客户端自报的头一律忽略，避免伪造来源绕过限流。
  限流、邮件来源等都读取 `conn.remote_ip`，因此本插件必须位于它们之前。
  """
  import Plug.Conn
  @doc false
  def init(options), do: options
  @doc false
  def call(%{remote_ip: peer} = conn, _) do
    with true <- loopback?(peer),
         [value] <- get_req_header(conn, "x-real-ip"),
         {:ok, ip} <- value |> String.trim() |> String.to_charlist() |> :inet.parse_strict_address() do
      %{conn | remote_ip: ip}
    else
      _ -> conn
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0xFFFF, a, _}), do: div(a, 256) == 127
  defp loopback?(_), do: false
end
