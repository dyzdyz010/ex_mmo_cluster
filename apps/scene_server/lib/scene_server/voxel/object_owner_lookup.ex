defmodule SceneServer.Voxel.ObjectOwnerLookup do
  @moduledoc """
  Phase A4-4 (D7):per-scene cache of `voxel_scene_objects` owner metadata
  used by cross-region damage routing (`VoxelDamageRouter`) and 0x6C
  ObjectStateDelta fan-out (`ObjectRegistry`)。

  Owner metadata = `(owner_region_id, owner_lease_id, covered_chunks_by_region)`
  where `covered_chunks_by_region :: %{ {region_id, lease_id} => [chunk_coord] }`
  splits the object's covered chunks by which transaction participant owns them.

  ETS-backed read-through cache:

    * Hot path (`fetch_owner/3`) does a direct `:ets.lookup` against the
      named table without going through the GenServer.
    * Miss → `GenServer.call({:resolve, ...})` reads from
      `DataService.Voxel.SceneObjectStore` and populates the row.
    * Writers (`register/3` / `evict/3`) go through the GenServer so
      register-after-commit and lazy resolve cannot race.

  ETS row layout:

      {{logical_scene_id, object_id}, owner_region_id, owner_lease_id,
        covered_chunks_by_region}

  Cold-start cache miss (server restart, no transaction context available)
  reconstructs `covered_chunks_by_region` as the degenerate
  `%{owner_key => obj.covered_chunks}`,attributing every covered chunk to
  the owner region. The live `register/3` path called from
  `BuildTransactionApplier.register_scene_objects/2` overrides that with
  the real per-region split derived from the transaction's participants.
  Phase 6 HA can add a chunk → region resolver if cold-start fan-out
  accuracy becomes a problem (see decision phase-A4 risk 4)。
  """

  use GenServer

  alias DataService.Voxel.SceneObjectStore

  @type chunk_coord :: {integer(), integer(), integer()}
  @type participant_key :: {non_neg_integer(), non_neg_integer()}
  @type covered_by_region :: %{participant_key() => [chunk_coord()]}

  @type owner_info :: %{
          owner_region_id: non_neg_integer(),
          owner_lease_id: non_neg_integer(),
          covered_chunks_by_region: covered_by_region()
        }

  ## Public API

  @doc """
  Starts the owner lookup cache.

  Required `opts`:

    * `:name` — registered atom name; the ETS table is named after it.

  Optional `opts`:

    * `:store` — module implementing `SceneObjectStore` shape (test override)
    * `:store_opts` — keyword forwarded to the store on miss-resolve
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    init_opts = Keyword.put(opts, :name, name)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @doc """
  Returns owner metadata for `(scene_id, object_id)`.

    * Hot path — direct ETS lookup when `server` is an atom.
    * Miss — falls through to a `GenServer.call({:resolve, ...})` that reads
      `SceneObjectStore.get_object/2` and writes the ETS row.

  Returns `{:error, :not_found}` if the row does not exist (or belongs to a
  different scene)。
  """
  @spec fetch_owner(GenServer.server(), non_neg_integer(), non_neg_integer()) ::
          {:ok, owner_info()} | {:error, :not_found}
  def fetch_owner(server \\ __MODULE__, scene_id, object_id)

  def fetch_owner(server, scene_id, object_id)
      when is_atom(server) and is_integer(scene_id) and is_integer(object_id) do
    case :ets.lookup(ets_name(server), {scene_id, object_id}) do
      [{_, region_id, lease_id, covered}] ->
        {:ok,
         %{
           owner_region_id: region_id,
           owner_lease_id: lease_id,
           covered_chunks_by_region: covered
         }}

      [] ->
        GenServer.call(server, {:resolve, scene_id, object_id})
    end
  rescue
    ArgumentError ->
      # ETS table may not exist yet (server still booting); fall through to call.
      GenServer.call(server, {:resolve, scene_id, object_id})
  end

  def fetch_owner(server, scene_id, object_id) do
    GenServer.call(server, {:resolve, scene_id, object_id})
  end

  @doc """
  Writes a cache entry from a transaction's `register_scene_objects` path.

  `instance` must carry `:logical_scene_id`, `:object_id`, `:owner_region_id`,
  `:owner_lease_id`. `covered_chunks_by_region` is the per-region split
  derived by the caller from `transaction.participants`.
  """
  @spec register(GenServer.server(), map(), covered_by_region()) :: :ok
  def register(server \\ __MODULE__, instance, covered_chunks_by_region)
      when is_map(instance) and is_map(covered_chunks_by_region) do
    GenServer.call(server, {:register, instance, covered_chunks_by_region})
  end

  @doc "Evicts a cache entry — called when an object is destroyed."
  @spec evict(GenServer.server(), non_neg_integer(), non_neg_integer()) :: :ok
  def evict(server \\ __MODULE__, scene_id, object_id) do
    GenServer.call(server, {:evict, scene_id, object_id})
  end

  @doc "Test hatch:drops every cache entry without touching Postgres."
  def clear(server \\ __MODULE__) do
    GenServer.call(server, :clear)
  end

  @doc "CLI / debug:returns the current cache contents as a list of rows."
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  ## Callbacks

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    table = ets_name(name)

    :ets.new(table, [
      :named_table,
      :set,
      :protected,
      read_concurrency: true
    ])

    {:ok,
     %{
       table: table,
       store: Keyword.get(opts, :store, SceneObjectStore),
       store_opts: Keyword.get(opts, :store_opts, [])
     }}
  end

  @impl true
  def handle_call({:resolve, scene_id, object_id}, _from, state) do
    case :ets.lookup(state.table, {scene_id, object_id}) do
      [{_, region_id, lease_id, covered}] ->
        {:reply, {:ok, build_info(region_id, lease_id, covered)}, state}

      [] ->
        case load_from_store(state, object_id) do
          {:ok, obj} when obj.logical_scene_id == scene_id ->
            owner_key = {obj.owner_region_id, obj.owner_lease_id}
            covered = %{owner_key => obj.covered_chunks}

            :ets.insert(
              state.table,
              {{scene_id, object_id}, obj.owner_region_id, obj.owner_lease_id, covered}
            )

            {:reply, {:ok, build_info(obj.owner_region_id, obj.owner_lease_id, covered)}, state}

          _ ->
            {:reply, {:error, :not_found}, state}
        end
    end
  end

  def handle_call({:register, instance, covered_chunks_by_region}, _from, state) do
    scene_id = Map.fetch!(instance, :logical_scene_id)
    object_id = Map.fetch!(instance, :object_id)
    region_id = Map.fetch!(instance, :owner_region_id)
    lease_id = Map.fetch!(instance, :owner_lease_id)

    :ets.insert(
      state.table,
      {{scene_id, object_id}, region_id, lease_id, covered_chunks_by_region}
    )

    {:reply, :ok, state}
  end

  def handle_call({:evict, scene_id, object_id}, _from, state) do
    :ets.delete(state.table, {scene_id, object_id})
    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  def handle_call(:snapshot, _from, state) do
    rows = :ets.tab2list(state.table)
    {:reply, rows, state}
  end

  ## Helpers

  defp build_info(region_id, lease_id, covered) do
    %{
      owner_region_id: region_id,
      owner_lease_id: lease_id,
      covered_chunks_by_region: covered
    }
  end

  defp load_from_store(state, object_id) do
    state.store.get_object(object_id, state.store_opts)
  end

  defp ets_name(server_name) when is_atom(server_name) do
    :"#{server_name}.Cache"
  end
end
