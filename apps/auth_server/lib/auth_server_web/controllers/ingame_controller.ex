defmodule AuthServerWeb.IngameController do
  use AuthServerWeb, :controller
  require Logger

  def login(conn, _params) do
    render(conn, "login.html")
  end

  def login_post(conn, params) do
    Logger.debug("login_post: #{inspect(params, pretty: true)}")

    # Check if the user exists
    # {:ok, account} = Accounts.find_by_username(params.username)
    # if account != nil do
    #   # Check if the password is correct
    #   salt = account.salt
    #   hashed_password = Bcrypt.Base.hash_password(params.password, salt)
    #   if account.password == hashed_password do
    #     # Generate code
    #     code = Bcrypt.Base.hash_password(account.id, Bcrypt.Base.gen_salt())
    #     # Create a new session
    #     account_session = %Tables.User.AccountSession{
    #       account_id: account.id,
    #       code_id: code,
    #       ip: conn.remote_ip,
    #       port: conn.remote_port
    #     }

    #     # Put code into data
    #     data = %{code: code}

    #     # Redirect to login_success
    #     redirect(conn, to: Routes.ingame_path(conn, :login_success, data))
    #   end
    # else
    #   # Put error flash and redirect to login
    #   flash = %{error: "Invalid username or password"}
    #   redirect(conn, to: Routes.ingame_path(conn, :login, flash))
    # end
    username = params["username"] || "dev_user"

    code =
      username
      |> AuthServer.AuthWorker.build_session_claims(session_claim_options(params))
      |> AuthServer.AuthWorker.issue_token()

    data = %{code: code}
    redirect(conn, to: Routes.ingame_path(conn, :login_success, data))
  end

  def login_success(conn, _params) do
    render(conn, "login_success.html")
  end

  defp session_claim_options(params) do
    []
    |> Keyword.put(:source, "ingame_login")
    |> maybe_put(:cid, params["cid"])
    |> maybe_put(:allowed_cids, parse_allowed_cids(params["allowed_cids"]))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, []), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_allowed_cids(nil), do: nil

  defp parse_allowed_cids(values) when is_list(values), do: values

  defp parse_allowed_cids(values) when is_binary(values) do
    values
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end
end
