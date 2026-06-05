defmodule AuthServer.Accounts do
  @moduledoc """
  Auth-owned accessors for account and character ownership data.

  The gate server should not talk to `data_service` directly for identity
  decisions. Instead, auth owns the boundary and resolves account/character
  lookups through the co-located `data_service` data layer.

  `auth_server` and `data_service` always run in the same BEAM (see the MVP
  `ex_mmo_cluster` release and `AuthServer.Interface`), so these accessors call
  `DataService.Worker`'s stateless functions directly. The historical
  `DataService.Dispatcher` GenServer (a redundant serial layer stacked on top of
  Ecto's own connection pool) has been removed.

  All `DataService.Worker.*` accessors are plain Ecto calls; the only failure we
  translate here is an unexpected crash, surfaced as `:data_service_unavailable`
  so callers keep their existing error contract.
  """

  @spec find_by_username(binary()) :: {:ok, struct() | nil} | {:error, atom()}
  @doc "Looks up an account by username through the auth-owned data-service boundary."
  def find_by_username(username) when is_binary(username) do
    guard(fn -> DataService.Worker.account_by_username(username) end)
  end

  @spec character_owned_by_account?(integer(), integer()) ::
          {:ok, struct() | nil} | {:error, atom()}
  @doc "Returns the character when it is owned by the given account ID."
  def character_owned_by_account?(account_id, cid)
      when is_integer(account_id) and is_integer(cid) do
    guard(fn -> DataService.Worker.character_owned_by_account(account_id, cid) end)
  end

  def character_owned_by_account?(_account_id, _cid), do: {:error, :invalid_account}

  @spec upsert_dev(binary()) ::
          {:ok, %{account: struct(), character: struct()}} | {:error, atom() | tuple()}
  @doc """
  Dev-only upsert: ensures an account and companion character exist for `username`.

  Reuses existing rows when present. Returns the resolved account + character.
  """
  def upsert_dev(username) when is_binary(username) do
    guard(fn -> DataService.Worker.upsert_dev_account(username) end)
  end

  def upsert_dev(_username), do: {:error, :invalid_username}

  # Runs `fun` and normalizes any process/DB failure (e.g. the Repo not being
  # started, or the connection pool being unavailable) into the stable
  # `{:error, :data_service_unavailable}` contract callers already handle.
  #
  # Both failure shapes must be covered to actually fail closed: Ecto *raises*
  # (e.g. `RuntimeError` "could not lookup Ecto repo ... because it was not
  # started", `DBConnection.ConnectionError`) for an unavailable Repo/connection,
  # while a pool/connection process going down surfaces as an `:exit`.
  defp guard(fun) do
    fun.()
  rescue
    _error -> {:error, :data_service_unavailable}
  catch
    :exit, _reason -> {:error, :data_service_unavailable}
  end
end
