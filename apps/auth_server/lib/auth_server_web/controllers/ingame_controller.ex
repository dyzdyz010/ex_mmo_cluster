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
  """

  use AuthServerWeb, :controller
  require Logger

  @doc "Render the in-game login form."
  def login(conn, _params) do
    render(conn, :login)
  end

  @doc """
  Turn the submitted login form into a signed token and redirect to success.
  """
  def login_post(conn, params) do
    Logger.debug("login_post: #{inspect(params, pretty: true)}")

    username = params["username"] || "dev_user"
    account = resolve_account(username)

    code =
      username
      |> AuthServer.AuthWorker.build_session_claims(session_claim_options(params, account))
      |> AuthServer.AuthWorker.issue_token()

    redirect(conn, to: ~p"/ingame/login_success?#{[code: code]}")
  end

  @doc "Render the success page shown after a token is issued."
  def login_success(conn, _params) do
    render(conn, :login_success)
  end

  @doc """
  Dev-only JSON auto-login. Upserts account+character then returns a signed token.

  Gated by `config :auth_server, :dev_auto_login`. Responds 403 when disabled.
  """
  def auto_login(conn, params) do
    if Application.get_env(:auth_server, :dev_auto_login, false) do
      do_auto_login(conn, params)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "dev_auto_login_disabled"})
    end
  end

  defp do_auto_login(conn, params) do
    username = params["username"] |> normalize_username()

    cond do
      username == nil ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_username"})

      true ->
        case AuthServer.Accounts.upsert_dev(username) do
          {:ok, %{account: account, character: character}} ->
            token =
              username
              |> AuthServer.AuthWorker.build_session_claims(
                source: "ingame_auto_login",
                account_id: account.id,
                cid: character.id
              )
              |> AuthServer.AuthWorker.issue_token()

            json(conn, %{token: token, cid: character.id, username: username})

          {:error, reason} ->
            Logger.warning("auto_login failed for #{username}: #{inspect(reason)}")

            conn
            |> put_status(:service_unavailable)
            |> json(%{error: "auto_login_failed"})
        end
    end
  end

  defp normalize_username(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> nil
      String.length(trimmed) > 32 -> nil
      true -> trimmed
    end
  end

  defp normalize_username(_), do: nil

  defp session_claim_options(params, account) do
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
