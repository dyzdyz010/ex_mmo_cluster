defmodule SceneServer.Voxel.ObjectRegistry do
  @moduledoc """
  Per-scene runtime registry for `SceneObjectInstance` entries.

  Phase 4 (D5):承载活跃对象的内存真相,启动时按需从 `voxel_scene_objects`
  LOAD 指定 scene 的所有对象。ObjectRegistry 是 ChunkProcess 与
  `DataService.Voxel.SceneObjectStore` 之间的中介:

  * ChunkProcess commit 后调 `upsert_object/2`、`apply_chunk_cover_change/5`
    通知对象变化
  * Phase 4 Step 4-6 引入的 `accumulate_damage/4`、`destroy_part/3`、
    `destroy_object/3` 闭环也由 ObjectRegistry 持有(本 step 4-3 仅落基本 API)

  本 step(基本 API)实现:

  * `lookup_object/3` — 反向查 `(scene_id, object_id)` → 实例 map
  * `list_objects_in_chunk/3` — 列出某 chunk 上所有对象
  * `upsert_object/2` — 写内存 + 同步 INSERT/UPDATE Postgres
  * `apply_chunk_cover_change/5` — 维护 `covered_chunks` 字段(:add / :remove)
  * `load_scene/2` — 显式 LOAD 一个 scene 的所有对象(幂等;首次访问会 lazy load)

  实例(in-memory)形态:与 `SceneObjectStore.t:object/0` 相同,**唯一区别**
  是 `part_states` 字段值是 `[%PartState{}, ...]` 结构(LOAD 时把 store 出
  来的 plain map 转成 struct;upsert 时再转回 plain map 进 store)。

  服务端单进程串行化:GenServer 全部 handle_call,无并发竞争。Persist 失败
  会回滚内存写入,保证内存与 Postgres 不发散。
  """

  use GenServer

  alias DataService.Voxel.SceneObjectStore
  alias SceneServer.Voxel.PartState

  @type chunk_coord :: {integer(), integer(), integer()}
  @type cover_kind :: :add | :remove

  @type instance :: %{
          required(:object_id) => non_neg_integer(),
          required(:logical_scene_id) => non_neg_integer(),
          required(:parcel_id) => non_neg_integer(),
          required(:blueprint_id) => non_neg_integer(),
          required(:blueprint_version) => non_neg_integer(),
          required(:anchor_world_micro) => {integer(), integer(), integer()},
          required(:rotation) => non_neg_integer(),
          required(:owner_actor_id) => non_neg_integer(),
          required(:state_flags) => non_neg_integer(),
          required(:object_attribute_ref) => non_neg_integer(),
          required(:object_tag_set_ref) => non_neg_integer(),
          required(:covered_chunks) => [chunk_coord()],
          required(:part_states) => [PartState.t()],
          required(:object_version) => non_neg_integer()
        }

  ## Public API

  @doc "Starts the object registry."
  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    server_opts = Keyword.put_new(server_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc "Returns the in-memory instance for `(scene_id, object_id)`, or nil."
  @spec lookup_object(GenServer.server(), non_neg_integer(), non_neg_integer()) ::
          instance() | nil
  def lookup_object(server \\ __MODULE__, logical_scene_id, object_id) do
    GenServer.call(server, {:lookup_object, logical_scene_id, object_id})
  end

  @doc """
  Returns every object whose `covered_chunks` contains `chunk_coord`,
  sorted by `object_id` asc.
  """
  @spec list_objects_in_chunk(GenServer.server(), non_neg_integer(), chunk_coord()) :: [
          instance()
        ]
  def list_objects_in_chunk(server \\ __MODULE__, logical_scene_id, chunk_coord) do
    GenServer.call(server, {:list_objects_in_chunk, logical_scene_id, chunk_coord})
  end

  @doc """
  Inserts or updates an object instance.

  `instance.part_states` may be `[PartState.t() | map()]` — entries are
  normalized to `%PartState{}` structs in memory.
  """
  @spec upsert_object(GenServer.server(), map()) :: :ok | {:error, atom()}
  def upsert_object(server \\ __MODULE__, instance) when is_map(instance) do
    GenServer.call(server, {:upsert_object, instance})
  end

  @doc """
  Maintains `covered_chunks` after a partial coverage change.

  * `:add` — add `chunk_coord` if not present
  * `:remove` — remove `chunk_coord` if present;若收缩到空集 → 返回
    `{:error, :covered_chunks_would_be_empty}` 提示调用方走
    `destroy_object/3`(Phase 4 Step 4-6)。
  """
  @spec apply_chunk_cover_change(
          GenServer.server(),
          non_neg_integer(),
          non_neg_integer(),
          chunk_coord(),
          cover_kind()
        ) :: :ok | {:error, atom()}
  def apply_chunk_cover_change(
        server \\ __MODULE__,
        logical_scene_id,
        object_id,
        chunk_coord,
        kind
      )
      when kind in [:add, :remove] do
    GenServer.call(
      server,
      {:apply_chunk_cover_change, logical_scene_id, object_id, chunk_coord, kind}
    )
  end

  @doc "Idempotent:LOAD all objects in `scene_id` from store. First call lazy-loads."
  @spec load_scene(GenServer.server(), non_neg_integer()) :: :ok
  def load_scene(server \\ __MODULE__, logical_scene_id) do
    GenServer.call(server, {:load_scene, logical_scene_id})
  end

  @doc "Internal state snapshot. CLI / debug only."
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @doc "Test hatch:clears all in-memory state but does not touch Postgres."
  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  ## Callbacks

  @impl true
  def init(opts) do
    {:ok,
     %{
       scenes_loaded: MapSet.new(),
       objects: %{},
       store: Keyword.get(opts, :store, SceneObjectStore),
       store_opts: Keyword.get(opts, :store_opts, [])
     }}
  end

  @impl true
  def handle_call({:lookup_object, scene_id, object_id}, _from, state) do
    state = ensure_scene_loaded(state, scene_id)
    instance = get_in(state, [:objects, scene_id, object_id])
    {:reply, instance, state}
  end

  def handle_call({:list_objects_in_chunk, scene_id, chunk_coord}, _from, state) do
    state = ensure_scene_loaded(state, scene_id)
    chunk_coord = normalize_chunk_coord(chunk_coord)

    list =
      state.objects
      |> Map.get(scene_id, %{})
      |> Enum.filter(fn {_oid, instance} -> chunk_coord in instance.covered_chunks end)
      |> Enum.map(fn {_oid, instance} -> instance end)
      |> Enum.sort_by(& &1.object_id)

    {:reply, list, state}
  end

  def handle_call({:upsert_object, raw_instance}, _from, state) do
    case persist_and_cache(raw_instance, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:apply_chunk_cover_change, scene_id, object_id, chunk_coord, kind},
        _from,
        state
      ) do
    state = ensure_scene_loaded(state, scene_id)
    chunk_coord = normalize_chunk_coord(chunk_coord)

    case get_in(state, [:objects, scene_id, object_id]) do
      nil ->
        {:reply, {:error, :object_not_found}, state}

      instance ->
        new_covered =
          case kind do
            :add ->
              if chunk_coord in instance.covered_chunks do
                instance.covered_chunks
              else
                Enum.sort([chunk_coord | instance.covered_chunks])
              end

            :remove ->
              instance.covered_chunks -- [chunk_coord]
          end

        cond do
          new_covered == instance.covered_chunks ->
            # No-op (e.g. removing a chunk that wasn't there, or adding one already present)
            {:reply, :ok, state}

          new_covered == [] ->
            {:reply, {:error, :covered_chunks_would_be_empty}, state}

          true ->
            new_instance = %{
              instance
              | covered_chunks: new_covered,
                object_version: instance.object_version + 1
            }

            case persist_and_cache(new_instance, state) do
              {:ok, new_state} -> {:reply, :ok, new_state}
              {:error, reason} -> {:reply, {:error, reason}, state}
            end
        end
    end
  end

  def handle_call({:load_scene, scene_id}, _from, state) do
    state = ensure_scene_loaded(state, scene_id)
    {:reply, :ok, state}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | scenes_loaded: MapSet.new(), objects: %{}}}
  end

  ## Helpers

  defp ensure_scene_loaded(state, scene_id) do
    if MapSet.member?(state.scenes_loaded, scene_id) do
      state
    else
      objects_list = state.store.list_in_scene(scene_id, state.store_opts)

      scene_map =
        Enum.into(objects_list, %{}, fn map_obj ->
          instance = to_instance(map_obj)
          {instance.object_id, instance}
        end)

      %{
        state
        | scenes_loaded: MapSet.put(state.scenes_loaded, scene_id),
          objects: Map.put(state.objects, scene_id, scene_map)
      }
    end
  end

  defp persist_and_cache(raw_instance, state) do
    instance = to_instance(raw_instance)
    state = ensure_scene_loaded(state, instance.logical_scene_id)
    attrs = to_store_attrs(instance)

    case state.store.put_object(attrs, state.store_opts) do
      {:ok, :upserted} ->
        scene_map = Map.get(state.objects, instance.logical_scene_id, %{})
        new_scene_map = Map.put(scene_map, instance.object_id, instance)
        new_objects = Map.put(state.objects, instance.logical_scene_id, new_scene_map)
        {:ok, %{state | objects: new_objects}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp to_instance(map_obj) when is_map(map_obj) do
    part_states =
      map_obj
      |> Map.get(:part_states, [])
      |> Enum.map(&PartState.normalize!/1)

    Map.put(map_obj, :part_states, part_states)
  end

  defp to_store_attrs(instance) do
    part_states = Enum.map(instance.part_states, &PartState.to_map/1)
    Map.put(instance, :part_states, part_states)
  end

  defp normalize_chunk_coord({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z),
    do: {x, y, z}

  defp normalize_chunk_coord([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z),
    do: {x, y, z}

  defp normalize_chunk_coord(other),
    do: raise(ArgumentError, "expected {x, y, z} chunk_coord, got: #{inspect(other)}")
end
