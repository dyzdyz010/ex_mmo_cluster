defmodule DataService.Voxel.TransactionCoordinatorStore do
  @moduledoc """
  Durable backing store for `WorldServer.Voxel.TransactionCoordinator`.

  Stores the latest coordinator snapshot (transactions, begin_fingerprints,
  decisions, decision_index) in a single row of
  `voxel_transaction_coordinator_snapshots`. The payload is a
  `:erlang.term_to_binary/1` blob so structs round-trip exactly with no JSON
  flattening; on load we use `:erlang.binary_to_term/2` with the `:safe` option
  so unknown atoms cannot leak in from a corrupted row.

  The keys we accept (`transactions`, `begin_fingerprints`, `decisions`,
  `decision_index`) must each be a map; everything else is rejected as
  `:unexpected_payload_shape` so a stale or malformed row turns into a
  recoverable error rather than a silent state corruption.
  """

  import Ecto.Query, only: [from: 2]

  alias DataService.Schema.VoxelTransactionCoordinatorSnapshot

  @row_id 1
  @expected_keys [:transactions, :begin_fingerprints, :decisions, :decision_index]

  @type coordinator_state :: %{
          required(:transactions) => map(),
          required(:begin_fingerprints) => map(),
          required(:decisions) => map(),
          required(:decision_index) => map()
        }

  @doc """
  Persists the supplied coordinator state.

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
           VoxelTransactionCoordinatorSnapshot,
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
  Loads the persisted coordinator state if any exists.

  Returns `{:ok, %{}}` when the table is empty so a fresh deployment starts
  with the in-memory defaults.
  """
  @spec load_state(Ecto.Repo.t()) ::
          {:ok, %{} | coordinator_state()} | {:error, term()}
  def load_state(repo) do
    case repo.one(from(s in VoxelTransactionCoordinatorSnapshot, where: s.id == ^@row_id)) do
      nil ->
        {:ok, %{}}

      %VoxelTransactionCoordinatorSnapshot{payload: payload} when is_binary(payload) ->
        decode_payload(payload)

      _other ->
        {:error, :unexpected_row_shape}
    end
  rescue
    exception ->
      {:error, Exception.message(exception)}
  end

  @doc "Returns a 1-arity persist function bound to `repo` for `TransactionCoordinator.persist_fn` opts."
  @spec persist_fn(Ecto.Repo.t()) :: (map() -> :ok | {:error, term()})
  def persist_fn(repo), do: fn state -> save_state(repo, state) end

  @doc "Returns a 0-arity load function bound to `repo` for `TransactionCoordinator.load_fn` opts."
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
