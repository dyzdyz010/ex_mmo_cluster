defmodule AuthServerWeb.IngameController do
  use AuthServerWeb, :controller
  require Logger

  alias AuthServer.Accounts
  alias DataInit.TableDef, as: Tables

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
    code = "3e4fg34gf32g4g43"
    data = %{code: code}
    redirect(conn, to: Routes.ingame_path(conn, :login_success, data))
  end

  def login_success(conn, _params) do
    render(conn, "login_success.html")
  end
end
