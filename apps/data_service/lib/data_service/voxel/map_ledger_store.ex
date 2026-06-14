defmodule DataService.Voxel.MapLedgerStore do
  # PERS-5:durable_authoritative(region 所有权目录/owner_epoch/lease,CELL-23)。见 MmoContracts.StateRegistry。
  use MmoContracts.StateClassed, class: :durable_authoritative

  @moduledoc """
  Durable backing store for `WorldServer.Voxel.MapLedger`.

  Stores the latest ledger snapshot (assignments, leases, chunk_summaries,
  migrations) in a single row of `voxel_map_ledger_snapshots`. The payload is a
  `:erlang.term_to_binary/1` blob so structs round-trip exactly with no JSON
  flattening; on load we use `:erlang.binary_to_term/2` with the `:safe` option
  so unknown atoms cannot leak in from a corrupted row.

  The keys we accept (`assignments`, `leases`, `chunk_summaries`, `migrations`)
  must each be a map; everything else is rejected as `:unexpected_payload_shape`
  so a stale or malformed row turns into a recoverable error rather than a
  silent state corruption.
  """

  import Ecto.Query, only: [from: 2]

  alias DataService.Schema.VoxelMapLedgerSnapshot

  @row_id 1
  @expected_keys [:assignments, :leases, :chunk_summaries, :migrations]

  @type ledger_state :: %{
          required(:assignments) => map(),
          required(:leases) => map(),
          required(:chunk_summaries) => map(),
          required(:migrations) => map()
        }

  @doc """
  Persists the supplied ledger state.

  Atomic for a single repo round trip: the row is upserted in one statement so a
  partial write cannot leave the snapshot torn between two terms.
  """
  @spec save_state(Ecto.Repo.t(), map()) :: :ok | {:error, term()}
  def save_state(repo, state) when is_map(state) do
    payload =
      state
      |> Map.take(@expected_keys)
      |> :erlang.term_to_binary()

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    attrs = %{
      id: @row_id,
      payload: payload,
      inserted_at: now,
      updated_at: now
    }

    case repo.insert_all(
           VoxelMapLedgerSnapshot,
           [attrs],
           on_conflict: {:replace, [:payload, :updated_at]},
           conflict_target: :id
         ) do
      {count, _} when count >= 1 -> :ok
      _other -> {:error, :persist_failed}
    end
  rescue
    exception ->
      {:error, Exception.message(exception)}
  end

  @doc """
  Loads the persisted ledger state if any exists.

  Returns `{:ok, %{}}` when the table is empty so a fresh deployment starts
  with the in-memory defaults.
  """
  @spec load_state(Ecto.Repo.t()) ::
          {:ok, %{} | ledger_state()} | {:error, term()}
  def load_state(repo) do
    case repo.one(from(s in VoxelMapLedgerSnapshot, where: s.id == ^@row_id)) do
      nil ->
        {:ok, %{}}

      %VoxelMapLedgerSnapshot{payload: payload} when is_binary(payload) ->
        decode_payload(payload)

      _other ->
        {:error, :unexpected_row_shape}
    end
  rescue
    exception ->
      {:error, Exception.message(exception)}
  end

  @doc "Returns a 0-arity persist function bound to `repo` for `MapLedger.persist_fn` opts."
  @spec persist_fn(Ecto.Repo.t()) :: (map() -> :ok | {:error, term()})
  def persist_fn(repo), do: fn state -> save_state(repo, state) end

  @doc "Returns a 0-arity load function bound to `repo` for `MapLedger.load_fn` opts."
  @spec load_fn(Ecto.Repo.t()) :: (-> {:ok, map()} | {:error, term()})
  def load_fn(repo), do: fn -> load_state(repo) end

  defp decode_payload(payload) do
    term = :erlang.binary_to_term(payload, [:safe])

    cond do
      not is_map(term) ->
        {:error, :unexpected_payload_shape}

      Enum.any?(Map.keys(term), fn key -> key not in @expected_keys end) ->
        {:error, {:unexpected_keys, Map.keys(term) -- @expected_keys}}

      Enum.any?(term, fn {_key, value} -> not is_map(value) end) ->
        {:error, :unexpected_value_shape}

      true ->
        {:ok, term}
    end
  rescue
    exception in [ArgumentError] -> {:error, Exception.message(exception)}
  end
end
