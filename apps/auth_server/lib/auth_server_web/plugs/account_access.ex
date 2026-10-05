defmodule AuthServerWeb.Plugs.AccountAccess do
  @moduledoc "全局系统功能：资源 HTTP 接纳边界，只接受有效账号访问凭据。"
  import Plug.Conn
  @doc false
  def init(options), do: options
  @doc false
  def call(conn,_) do
    case AuthServer.Identity.authenticate(AuthServerWeb.AccountController.token(conn)) do
      {:ok,context} -> assign(conn,:account_context,context)
      error -> conn |> AuthServerWeb.AccountController.respond(error) |> halt()
    end
  end
end

defmodule AuthServerWeb.Plugs.AccountRateLimit do
  @moduledoc "全局系统功能：公开认证入口按实际来源限制昂贵计算；不信任自报转发 IP。"
  import Plug.Conn
  @doc false
  def init(options), do: options
  @doc false
  def call(conn,_) do
    case AuthServer.RateLimit.take({:auth_ip,conn.remote_ip},60,60) do
      :ok -> conn |> put_resp_header("cache-control","no-store")
      error -> conn |> AuthServerWeb.AccountController.respond(error) |> halt()
    end
  end
end
