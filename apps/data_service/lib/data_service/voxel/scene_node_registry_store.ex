defmodule DataService.Voxel.SceneNodeRegistryStore do
  @moduledoc """
  Durable backing store for `WorldServer.Voxel.SceneNodeRegistry`.

  Stores the latest registry snapshot (`join_order`, `region_assignments`,
  `round_robin_cursor`) in a single row of `voxel_scene_node_registry_snapshots`.
  The payload is a `:erlang.term_to_binary/1` blob so node-atom keys and the
  region-assignment map round-trip exactly with no JSON flattening; on load we
  use `:erlang.binary_to_term/2` with the `:safe` option so unknown atoms cannot
  leak in from a corrupted row.

  This is the **authoritative** record of region ownership on the World side
  (Phase 3 / S1 — process identity registration). `SceneNodeRegistry`'s
  in-memory GenServer state is a derived cache hydrated from this row at
  (re)start; the row, not the process, is the source of truth. A scene_node
  restart must not lose region assignments, so every registry mutation upserts
  this row and every registry boot reads it back.

  ## Accepted payload shape

  * `join_order` — a list of `node()` atoms.
  * `region_assignments` — a `%{region_id => node()}` map.
  * `round_robin_cursor` — a non-negative integer.

  Anything else is rejected (`{:error, ...}`) so a stale or malformed row turns
  into a recoverable error rather than silent state corruption — the registry
  decides how to degrade (see `WorldServer.Voxel.SceneNodeRegistry`).
  """

  import Ecto.Query, only: [from: 2]

  alias DataService.Schema.VoxelSceneNodeRegistrySnapshot

  @row_id 1
  @expected_keys [:join_order, :region_assignments, :round_robin_cursor]

  @type registry_state :: %{
          required(:join_order) => [node()],
          required(:region_assignments) => %{optional(non_neg_integer()) => node()},
          required(:round_robin_cursor) => non_neg_integer()
        }

  @doc """
  Persists the supplied registry state.

  Atomic for a single repo round trip: the row is upserted in one statement so a
  partial write cannot leave the snapshot torn between two terms. Only the
  durable keys (`join_order`, `region_assignments`, `round_robin_cursor`) are
  written; any transient fields the registry carries (e.g. `persist_fn`) are
  stripped first.
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
           VoxelSceneNodeRegistrySnapshot,
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
  Loads the persisted registry state if any exists.

  Returns `{:ok, %{}}` when the table is empty so a fresh deployment starts with
  the in-memory defaults. A row whose payload does not decode to the expected
  shape returns `{:error, reason}` (never a silent empty default) so the caller
  can choose its degraded path explicitly.
  """
  @spec load_state(Ecto.Repo.t()) ::
          {:ok, %{} | registry_state()} | {:error, term()}
  def load_state(repo) do
    case repo.one(from(s in VoxelSceneNodeRegistrySnapshot, where: s.id == ^@row_id)) do
      nil ->
        {:ok, %{}}

      %VoxelSceneNodeRegistrySnapshot{payload: payload} when is_binary(payload) ->
        decode_payload(payload)

      _other ->
        {:error, :unexpected_row_shape}
    end
  rescue
    exception ->
      {:error, Exception.message(exception)}
  end

  @doc "Returns a 1-arity persist function bound to `repo` for `SceneNodeRegistry.persist_fn` opts."
  @spec persist_fn(Ecto.Repo.t()) :: (map() -> :ok | {:error, term()})
  def persist_fn(repo), do: fn state -> save_state(repo, state) end

  @doc "Returns a 0-arity load function bound to `repo` for `SceneNodeRegistry.load_fn` opts."
  @spec load_fn(Ecto.Repo.t()) :: (-> {:ok, map()} | {:error, term()})
  def load_fn(repo), do: fn -> load_state(repo) end

  defp decode_payload(payload) do
    term = :erlang.binary_to_term(payload, [:safe])

    cond do
      not is_map(term) ->
        {:error, :unexpected_payload_shape}

      Enum.any?(Map.keys(term), fn key -> key not in @expected_keys end) ->
        {:error, {:unexpected_keys, Map.keys(term) -- @expected_keys}}

      not valid_join_order?(Map.get(term, :join_order, [])) ->
        {:error, :unexpected_join_order_shape}

      not is_map(Map.get(term, :region_assignments, %{})) ->
        {:error, :unexpected_region_assignments_shape}

      not valid_cursor?(Map.get(term, :round_robin_cursor, 0)) ->
        {:error, :unexpected_round_robin_cursor_shape}

      true ->
        {:ok, term}
    end
  rescue
    exception in [ArgumentError] -> {:error, Exception.message(exception)}
  end

  defp valid_join_order?(join_order) do
    is_list(join_order) and Enum.all?(join_order, &is_atom/1)
  end

  defp valid_cursor?(cursor), do: is_integer(cursor) and cursor >= 0
end
