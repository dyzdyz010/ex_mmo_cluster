defmodule AuthServerWeb.Plugs.PlaytestAccess do
  @moduledoc "公网内测的 HTTP 接纳边界；邀请码身份由服务端持有，旧开发入口在此部署中关闭。"
  import Plug.Conn

  @doc false
  def init(options), do: options

  @doc false
  def call(conn, _options) do
    case Application.get_env(:auth_server, :playtest_access_file) do
      nil ->
        if String.starts_with?(conn.request_path, "/playtest/"),
          do: conn |> send_resp(404, "") |> halt(),
          else: conn

      path ->
        authorize(conn, path)
    end
  end

  defp authorize(%{method: "POST", request_path: route} = conn, path)
       when route in ["/playtest/login", "/playtest/regions"] do
    with ["Bearer " <> code] <- get_req_header(conn, "authorization"),
         digest = :crypto.hash(:sha256, code) |> Base.encode16(case: :lower),
         {:ok, username} <- path |> File.read!() |> Jason.decode!() |> Map.fetch(digest) do
      assign(conn, :playtest_username, username)
    else
      _ ->
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> put_resp_content_type("application/json")
        |> send_resp(401, ~s({"error":"invalid_invite"}))
        |> halt()
    end
  end

  defp authorize(conn, _path), do: conn |> send_resp(404, "") |> halt()
end

