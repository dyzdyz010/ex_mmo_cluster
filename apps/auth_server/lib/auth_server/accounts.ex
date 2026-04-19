defmodule AuthServer.Accounts do
  @moduledoc """
  Auth-owned accessors for account and character ownership data.

  The gate server should not talk to `data_service` directly for identity
  decisions. Instead, auth owns the boundary and can resolve account/character
  lookups through the current data source.

  In production-like flows this module prefers the auth interface's discovered
  `data_service` node. In tests and local single-node runs it can fall back to a
  locally registered `DataService.Dispatcher` so the authorization path remains
  exercisable without a full cluster.
  """

  @spec find_by_username(binary()) :: {:ok, struct() | nil} | {:error, atom()}
  @doc "Looks up an account by username through the auth-owned data-service boundary."
  def find_by_username(username) when is_binary(username) do
    dispatch_to_data_service({:account_by_username, username})
  end

  @spec character_owned_by_account?(integer(), integer()) ::
          {:ok, struct() | nil} | {:error, atom()}
  @doc "Returns the character when it is owned by the given account ID."
  def character_owned_by_account?(account_id, cid)
      when is_integer(account_id) and is_integer(cid) do
    dispatch_to_data_service({:character_owned_by_account, account_id, cid})
  end

  def character_owned_by_account?(_account_id, _cid), do: {:error, :invalid_account}

  @spec upsert_dev(binary()) ::
          {:ok, %{account: struct(), character: struct()}} | {:error, atom() | tuple()}
  @doc """
  Dev-only upsert: ensures an account and companion character exist for `username`.

  Reuses existing rows when present. Returns the resolved account + character.
  """
  def upsert_dev(username) when is_binary(username) do
    dispatch_to_data_service({:upsert_dev_account, username})
  end

  def upsert_dev(_username), do: {:error, :invalid_username}

  defp dispatch_to_data_service(message) do
    case data_service_target() do
      {:error, _reason} = error ->
        error

      target ->
        try do
          GenServer.call(target, message)
        catch
          :exit, _reason -> {:error, :data_service_unavailable}
        end
    end
  end

  defp data_service_target do
    cond do
      Process.whereis(AuthServer.Interface) != nil ->
        case safe_call(AuthServer.Interface, :data_service) do
          {:ok, nil} -> {:error, :data_service_unavailable}
          {:ok, node} -> {DataService.Dispatcher, node}
          {:error, _reason} -> {:error, :data_service_unavailable}
        end

      Process.whereis(DataService.Dispatcher) != nil ->
        DataService.Dispatcher

      true ->
        {:error, :data_service_unavailable}
    end
  end

  defp safe_call(server, message) do
    try do
      {:ok, GenServer.call(server, message)}
    catch
      :exit, reason -> {:error, reason}
    end
  end
end
