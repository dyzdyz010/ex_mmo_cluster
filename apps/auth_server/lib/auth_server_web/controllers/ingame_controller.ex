defmodule AuthServerWeb.IngameController do
  @moduledoc """
  HTTP façade for the in-game login flow.

  The controller keeps request handling thin: it renders the login page,
  converts POST parameters into signed claims, and redirects the browser to a
  success page that can hand the token to the game client.

  ## Route map

  - `GET /ingame/login` -> `login/2`
  - `POST /ingame/login_post` -> `login_post/2`
  - `GET /ingame/login_success` -> `login_success/2`

  ## Flow

      browser params
           ↓
      session_claim_options/1
           ↓
      AuthServer.AuthWorker.build_session_claims/2
           ↓
      AuthServer.AuthWorker.issue_token/1
           ↓
      redirect to /ingame/login_success?code=...

  ## Request fields

  - `username` defaults to `"dev_user"` when omitted
  - `cid` is passed through as a claim when present
  - `allowed_cids` may be a comma-separated string or a list
  """

  use AuthServerWeb, :controller
  require Logger

  @doc """
  Render the in-game login form.

  This action does not inspect any token state; it just serves the HTML page
  used to collect the username and optional character restrictions.
  """
  def login(conn, _params) do
    render(conn, "login.html")
  end

  @doc """
  Turn the submitted login form into a signed token and redirect to success.

  The action accepts a plain params map from the browser. If `username` is
  missing, the controller falls back to `"dev_user"` so the development flow
  stays usable without a full account lookup. `allowed_cids` is normalized
  before it reaches `AuthServer.AuthWorker`.

  Account resolution is best-effort at login time. When an account is found,
  its identifier is embedded into the issued claims. When lookup fails, the
  later gate-side authorization step can still resolve ownership by username.

  The response redirects to `Routes.ingame_path(conn, :login_success, %{code: token})`.
  """
  def login_post(conn, params) do
    Logger.debug("login_post: #{inspect(params, pretty: true)}")

    username = params["username"] || "dev_user"
    account = resolve_account(username)

    code =
      username
      |> AuthServer.AuthWorker.build_session_claims(session_claim_options(params, account))
      |> AuthServer.AuthWorker.issue_token()

    data = %{code: code}
    redirect(conn, to: Routes.ingame_path(conn, :login_success, data))
  end

  @doc """
  Render the success page shown after a token is issued.

  The browser reaches this page after `login_post/2` redirects with the signed
  token embedded in the query payload.
  """
  def login_success(conn, _params) do
    render(conn, "login_success.html")
  end

  defp session_claim_options(params, account) do
    # Normalize browser form values so AuthWorker only sees the claim-shaping
    # options it understands. `allowed_cids` arrives from the form as text.
    []
    |> Keyword.put(:source, "ingame_login")
    |> maybe_put(:account_id, account_id(account))
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

  defp resolve_account(username) do
    case AuthServer.Accounts.find_by_username(username) do
      {:ok, account} -> account
      {:error, _reason} -> nil
    end
  end

  defp account_id(%{id: account_id}), do: account_id
  defp account_id(_), do: nil
end
