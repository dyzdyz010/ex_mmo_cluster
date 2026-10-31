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

  require Logger

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
          :exit, reason ->
            # 退出原因里带着原消息（可能含凭据），日志只记请求类型和退出类别。
            Logger.warning("auth_data_service_call_failed request=#{elem(message, 0)} reason=#{inspect(exit_kind(reason))}")
            {:error, :data_service_unavailable}
        end
    end
  end

  defp exit_kind({kind, {GenServer, :call, _args}}), do: kind
  defp exit_kind(kind) when is_atom(kind), do: kind
  defp exit_kind(_reason), do: :other

  defp data_service_target do
    if Process.whereis(DataService.Dispatcher),
      do: DataService.Dispatcher,
      else: {:error, :data_service_unavailable}
  end
end
