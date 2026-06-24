defmodule SceneServer.Voxel.ObjectRegistry do
  # PERS-5:durable_authoritative(object/part 健康与销毁,经 SceneObjectStore 落库)。见 MmoContracts.StateRegistry。
  use MmoContracts.StateClassed, class: :durable_authoritative

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
  alias SceneServer.CliObserve
  alias SceneServer.Voxel.ChunkDirectory
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.ObjectOwnerLookup
  alias SceneServer.Voxel.PartState

  import Bitwise

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

  @doc """
  Phase 4 (D7):accumulates `damage` (positive integer) on the named PartState.

  Subtracts from `health`,asserts the `damaged` bit, and if `health <= 0`
  triggers `destroy_part/4` synchronously inside the registry's GenServer
  call (which in turn may trigger `destroy_object/3` if all parts are now
  destroyed).

  Returns:
    * `:ok` — health > 0 after damage applied
    * `{:part_destroyed, ...}` — part transitioned to destroyed
    * `{:object_destroyed, ...}` — last surviving part transitioned, object destroyed
    * `{:error, :object_not_found | :part_not_found | :already_destroyed}`

  `opts[:chunk_directory]` overrides the default `ChunkDirectory` for the
  cascading destroy paths.
  """
  @spec accumulate_damage(
          GenServer.server(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          keyword()
        ) :: :ok | {:part_destroyed, map()} | {:object_destroyed, map()} | {:error, atom()}
  def accumulate_damage(
        server \\ __MODULE__,
        logical_scene_id,
        object_id,
        part_id,
        damage,
        opts \\ []
      )
      when is_integer(damage) and damage >= 0 do
    GenServer.call(
      server,
      {:accumulate_damage, logical_scene_id, object_id, part_id, damage, opts}
    )
  end

  @doc """
  Phase 4 (D8):forces a part to its destroyed terminal state.

  Iterates the object's `covered_chunks` and asks each chunk to wipe every
  `(owner_object_id, owner_part_id)` micro slot via
  `SceneServer.Voxel.ChunkProcess.destroy_part/2`,then marks the
  PartState destroyed and persists the row. If this transitions every
  PartState to destroyed,it cascades into `destroy_object/3` and returns
  `{:object_destroyed, ...}`.
  """
  @spec destroy_part(
          GenServer.server(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          keyword()
        ) :: {:part_destroyed, map()} | {:object_destroyed, map()} | {:error, atom()}
  def destroy_part(server \\ __MODULE__, logical_scene_id, object_id, part_id, opts \\ []) do
    GenServer.call(server, {:destroy_part, logical_scene_id, object_id, part_id, opts})
  end

  @doc """
  Phase 4 (D9):final cleanup for an object. Deletes the
  `voxel_scene_objects` row and removes the in-memory entry. Each
  `covered_chunks` entry is asked to drop any stale ChunkObjectRef[]
  pointing at the dead object — defensive belt-and-suspenders;
  `Storage.refresh_chunk_object_refs/1` after `destroy_part` already
  removes the entry naturally.

  Emits `voxel_object_destroyed` observe so Phase 5+ downstream hooks
  (掉落物 / 任务系统 / 资源回收) can chain off it.
  """
  @spec destroy_object(GenServer.server(), non_neg_integer(), non_neg_integer(), keyword()) ::
          {:object_destroyed, map()} | {:error, atom()}
  def destroy_object(server \\ __MODULE__, logical_scene_id, object_id, opts \\ []) do
    GenServer.call(server, {:destroy_object, logical_scene_id, object_id, opts})
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
       store_opts: Keyword.get(opts, :store_opts, []),
       chunk_directory: Keyword.get(opts, :chunk_directory, ChunkDirectory),
       # Phase A4-4 (D7):owner-driven 0x6C fan-out lookup. Default talks to
       # the runtime-shared `ObjectOwnerLookup`;tests can inject a stub
       # module/server pair.
       owner_lookup: Keyword.get(opts, :owner_lookup, ObjectOwnerLookup),
       owner_lookup_server: Keyword.get(opts, :owner_lookup_server, ObjectOwnerLookup),
       # Phase A4-4 (D7):per-region chunk_directory resolver for cross-region
       # fan-out. Function `(participant_key -> chunk_directory_target)`
       # resolves a `{region_id, lease_id}` key to the ChunkDirectory module
       # / `{module, node}` pair the broadcast should target. `nil` means
       # "always use the registry's own `:chunk_directory`" (single-region
       # production default; legacy A1/A2 path)。
       region_routing_fn: Keyword.get(opts, :region_routing_fn)
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

  def handle_call(
        {:accumulate_damage, scene_id, object_id, part_id, damage, opts},
        _from,
        state
      ) do
    state = ensure_scene_loaded(state, scene_id)

    case get_in(state, [:objects, scene_id, object_id]) do
      nil ->
        {:reply, {:error, :object_not_found}, state}

      instance ->
        case find_part_index(instance.part_states, part_id) do
          nil ->
            {:reply, {:error, :part_not_found}, state}

          {idx, part_state} ->
            cond do
              PartState.destroyed?(part_state) ->
                {:reply, {:error, :already_destroyed}, state}

              true ->
                damaged_part_state =
                  part_state
                  |> PartState.apply_damage(damage)
                  |> PartState.mark_damaged()

                new_part_states =
                  List.replace_at(instance.part_states, idx, damaged_part_state)

                new_instance =
                  %{
                    instance
                    | part_states: new_part_states,
                      state_flags: bor(instance.state_flags, PartState.flag_damaged()),
                      object_version: instance.object_version + 1
                  }

                # If health <= 0, cascade into destroy_part synchronously.
                if damaged_part_state.health <= 0 do
                  case persist_and_cache(new_instance, state) do
                    {:ok, staged_state} ->
                      {reply, final_state} =
                        run_destroy_part(staged_state, scene_id, object_id, part_id, opts)

                      {:reply, reply, final_state}

                    {:error, reason} ->
                      {:reply, {:error, reason}, state}
                  end
                else
                  case persist_and_cache(new_instance, state) do
                    {:ok, new_state} ->
                      emit_damage(scene_id, object_id, part_id, damaged_part_state, damage)

                      dispatch_object_state_delta(
                        new_state,
                        new_instance,
                        PartState.flag_damaged()
                      )

                      {:reply, :ok, new_state}

                    {:error, reason} ->
                      {:reply, {:error, reason}, state}
                  end
                end
            end
        end
    end
  end

  def handle_call({:destroy_part, scene_id, object_id, part_id, opts}, _from, state) do
    state = ensure_scene_loaded(state, scene_id)

    case get_in(state, [:objects, scene_id, object_id]) do
      nil ->
        {:reply, {:error, :object_not_found}, state}

      _instance ->
        {reply, new_state} = run_destroy_part(state, scene_id, object_id, part_id, opts)
        {:reply, reply, new_state}
    end
  end

  def handle_call({:destroy_object, scene_id, object_id, opts}, _from, state) do
    state = ensure_scene_loaded(state, scene_id)

    case get_in(state, [:objects, scene_id, object_id]) do
      nil ->
        {:reply, {:error, :object_not_found}, state}

      instance ->
        new_state = run_destroy_object(state, scene_id, instance, opts)
        {:reply, {:object_destroyed, %{object_id: object_id, scene_id: scene_id}}, new_state}
    end
  end

  ## Damage / destroy helpers

  defp find_part_index(part_states, part_id) do
    case Enum.find_index(part_states, fn ps -> ps.part_id == part_id end) do
      nil -> nil
      idx -> {idx, Enum.at(part_states, idx)}
    end
  end

  # Returns `{reply, new_state}`.
  defp run_destroy_part(state, scene_id, object_id, part_id, opts) do
    instance = get_in(state, [:objects, scene_id, object_id])

    cond do
      instance == nil ->
        {{:error, :object_not_found}, state}

      true ->
        case find_part_index(instance.part_states, part_id) do
          nil ->
            {{:error, :part_not_found}, state}

          {idx, part_state} ->
            if PartState.destroyed?(part_state) do
              {{:error, :already_destroyed}, state}
            else
              do_destroy_part(state, scene_id, instance, idx, part_state, opts)
            end
        end
    end
  end

  defp do_destroy_part(state, scene_id, instance, idx, part_state, opts) do
    chunk_directory = Keyword.get(opts, :chunk_directory, state.chunk_directory)
    object_id = instance.object_id
    part_id = part_state.part_id

    # Step 1:wipe the part's micros from every covered chunk.
    Enum.each(instance.covered_chunks, fn chunk_coord ->
      ChunkDirectory.destroy_part(chunk_directory, %{
        logical_scene_id: scene_id,
        chunk_coord: chunk_coord,
        object_id: object_id,
        part_id: part_id
      })
    end)

    # Step 2:mark the PartState destroyed.
    new_part_states =
      List.replace_at(instance.part_states, idx, PartState.mark_destroyed(part_state))

    new_instance =
      %{
        instance
        | part_states: new_part_states,
          state_flags: bor(instance.state_flags, PartState.flag_damaged()),
          object_version: instance.object_version + 1
      }

    # Step 3:if every part is destroyed, cascade into destroy_object.
    if Enum.all?(new_part_states, &PartState.destroyed?/1) do
      new_instance =
        %{new_instance | state_flags: bor(new_instance.state_flags, PartState.flag_destroyed())}

      case persist_and_cache(new_instance, state) do
        {:ok, staged_state} ->
          emit_part_destroyed(scene_id, object_id, part_id)

          dispatch_object_state_delta(
            staged_state,
            new_instance,
            PartState.flag_part_destroyed()
          )

          final_state = run_destroy_object(staged_state, scene_id, new_instance, opts)

          {{:object_destroyed,
            %{object_id: object_id, scene_id: scene_id, last_part_id: part_id}}, final_state}

        {:error, reason} ->
          {{:error, reason}, state}
      end
    else
      case persist_and_cache(new_instance, state) do
        {:ok, new_state} ->
          emit_part_destroyed(scene_id, object_id, part_id)

          dispatch_object_state_delta(
            new_state,
            new_instance,
            PartState.flag_part_destroyed()
          )

          {{:part_destroyed,
            %{
              object_id: object_id,
              scene_id: scene_id,
              part_id: part_id,
              remaining_parts: Enum.count(new_part_states, &(not PartState.destroyed?(&1)))
            }}, new_state}

        {:error, reason} ->
          {{:error, reason}, state}
      end
    end
  end

  defp run_destroy_object(state, scene_id, instance, opts) do
    chunk_directory = Keyword.get(opts, :chunk_directory, state.chunk_directory)

    # Defensive belt-and-suspenders:ask every covered chunk to drop any
    # stale ChunkObjectRef[] pointing at the dead object_id. After
    # destroy_part across all parts, refresh has already cleared them.
    Enum.each(instance.covered_chunks, fn chunk_coord ->
      ChunkDirectory.cleanup_object_refs(chunk_directory, %{
        logical_scene_id: scene_id,
        chunk_coord: chunk_coord,
        object_id: instance.object_id
      })
    end)

    # Delete the row + drop from in-memory.
    state.store.delete_object(instance.object_id, state.store_opts)

    # Phase A4-4 (D7):evict the owner cache so cross-region damage / 0x6C
    # broadcasts don't keep targeting a destroyed object.
    safe_evict_owner_lookup(state, scene_id, instance.object_id)

    new_objects =
      case Map.get(state.objects, scene_id) do
        nil ->
          state.objects

        scene_map ->
          Map.put(state.objects, scene_id, Map.delete(scene_map, instance.object_id))
      end

    new_state = %{state | objects: new_objects}

    # Phase 4-bis (D5):每条 0x6C 消息表达"这次事件";cascade 路径已经
    # 在 do_destroy_part 那一层 dispatch 过 part_destroyed flag,这里
    # 只 dispatch destroyed flag。bump object_version 以保证客户端
    # version 单调去重(D3)能区分两条独立消息。
    bumped_instance = %{instance | object_version: instance.object_version + 1}

    emit_object_destroyed(scene_id, bumped_instance.object_id)

    dispatch_object_state_delta(new_state, bumped_instance, PartState.flag_destroyed())

    new_state
  end

  defp emit_damage(scene_id, object_id, part_id, part_state, damage) do
    CliObserve.emit("voxel_part_damaged", fn ->
      %{
        logical_scene_id: scene_id,
        object_id: object_id,
        part_id: part_id,
        damage: damage,
        health: part_state.health
      }
    end)
  end

  defp emit_part_destroyed(scene_id, object_id, part_id) do
    CliObserve.emit("voxel_part_destroyed", fn ->
      %{
        logical_scene_id: scene_id,
        object_id: object_id,
        part_id: part_id
      }
    end)
  end

  defp emit_object_destroyed(scene_id, object_id) do
    CliObserve.emit("voxel_object_destroyed", fn ->
      %{
        logical_scene_id: scene_id,
        object_id: object_id
      }
    end)
  end

  defp safe_evict_owner_lookup(state, scene_id, object_id) do
    state.owner_lookup.evict(state.owner_lookup_server, scene_id, object_id)
  catch
    :exit, _reason -> :ok
  end

  ## ObjectStateDelta dispatch (Phase 4-bis D1 / D2 / D4 / D5 / D7;
  ## Phase A4-4 D7 owner-driven cross-region fan-out)

  # Encode the 0x6C payload once via the canonical scene codec (D2). Phase
  # A4-4 routes the fan-out by `covered_chunks_by_region` (looked up via
  # `ObjectOwnerLookup`):each per-region bucket targets its own
  # `chunk_directory` (resolved by `region_routing_fn`), which in
  # single-region production collapses to the registry's local
  # `state.chunk_directory`. Failures(chunk not started, cast :exit)are
  # silently swallowed but observed (D4)。`single_flag` carries the
  # **this-event** flag bit (D5)。
  defp dispatch_object_state_delta(state, instance, single_flag) do
    payload =
      Codec.encode_voxel_object_state_delta_payload(%{
        logical_scene_id: instance.logical_scene_id,
        object_id: instance.object_id,
        object_version: instance.object_version,
        state_flags: single_flag,
        affected_chunks: instance.covered_chunks
      })

    covered_by_region = covered_chunks_by_region_for(state, instance)

    CliObserve.emit("voxel_object_state_delta_dispatch", fn ->
      %{
        logical_scene_id: instance.logical_scene_id,
        object_id: instance.object_id,
        object_version: instance.object_version,
        state_flags: single_flag,
        affected_chunk_count: length(instance.covered_chunks),
        region_bucket_count: map_size(covered_by_region)
      }
    end)

    Enum.each(covered_by_region, fn {participant_key, chunk_coords} ->
      chunk_dir_target = resolve_chunk_directory(state, participant_key)

      Enum.each(chunk_coords, fn chunk_coord ->
        safe_dispatch_to_chunk(state, instance, chunk_coord, payload, chunk_dir_target)
      end)
    end)

    :ok
  end

  # Look up `(scene_id, object_id)` in `ObjectOwnerLookup` to get the
  # owner-driven per-region split. Cache miss / unregistered objects fall
  # back to "all chunks under the local chunk_directory" — preserves
  # single-region A1/A2 behaviour for objects not yet routed through the
  # transaction's `register_scene_objects` path. Errors (lookup module
  # crashed / not started) follow the same fallback so a misconfigured
  # registry never brings down the broadcast path.
  defp covered_chunks_by_region_for(state, instance) do
    case safe_fetch_owner(state, instance) do
      {:ok, %{covered_chunks_by_region: covered}} when map_size(covered) > 0 ->
        covered

      _ ->
        %{:__local__ => instance.covered_chunks}
    end
  end

  defp safe_fetch_owner(state, instance) do
    state.owner_lookup.fetch_owner(
      state.owner_lookup_server,
      instance.logical_scene_id,
      instance.object_id
    )
  rescue
    _error -> {:error, :not_found}
  catch
    :exit, _reason -> {:error, :not_found}
  end

  defp resolve_chunk_directory(state, :__local__), do: state.chunk_directory

  defp resolve_chunk_directory(state, participant_key) do
    case state.region_routing_fn do
      nil -> state.chunk_directory
      fun when is_function(fun, 1) -> fun.(participant_key)
    end
  end

  defp safe_dispatch_to_chunk(state, instance, chunk_coord, payload, chunk_directory_target) do
    case safe_lookup_chunk_pid(chunk_directory_target, instance.logical_scene_id, chunk_coord) do
      {:ok, pid} ->
        try do
          ChunkProcess.push_object_state_delta_payload(pid, payload)
        catch
          :exit, reason ->
            emit_dispatch_failed(
              instance,
              chunk_coord,
              chunk_directory_target,
              {:exit, reason}
            )
        end

      :not_started ->
        emit_dispatch_failed(
          instance,
          chunk_coord,
          chunk_directory_target,
          :chunk_not_started
        )

      {:error, reason} ->
        emit_dispatch_failed(
          instance,
          chunk_coord,
          chunk_directory_target,
          {:lookup_error, reason}
        )
    end

    _ = state
    :ok
  end

  # `ChunkDirectory.lookup_chunk_pid/3` raises on a remote `{Mod, node}`
  # target that is unreachable / not started — guard the cross-region
  # path with a try/catch so a network blip does not crash the registry.
  defp safe_lookup_chunk_pid(chunk_directory_target, logical_scene_id, chunk_coord) do
    ChunkDirectory.lookup_chunk_pid(chunk_directory_target, logical_scene_id, chunk_coord)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp emit_dispatch_failed(instance, chunk_coord, chunk_directory_target, reason) do
    CliObserve.emit("voxel_object_state_delta_dispatch_failed", fn ->
      %{
        logical_scene_id: instance.logical_scene_id,
        object_id: instance.object_id,
        chunk_coord: chunk_coord,
        chunk_directory_target: inspect(chunk_directory_target),
        reason: inspect(reason)
      }
    end)
  end

  ## Helpers

  defp ensure_scene_loaded(state, scene_id) do
    if MapSet.member?(state.scenes_loaded, scene_id) do
      state
    else
      objects_list = state.store.list_in_scene(scene_id, state.store_opts)

      # #1/#4 反序列化加固:LOAD 路径逐行容错。单条损坏的持久化对象行(part_states
      # 非 map / 数值越界 / 缺 object_id)此前会让 to_instance/PartState.normalize! raise,
      # 整个 scene LOAD 崩 → 触发它的 GenServer call 崩。改为坏行 drop + emit observe,
      # 其余正常载入。写路径(persist_and_cache)仍用严格 to_instance:写入新实例时坏
      # 数据应当报错而非静默丢。
      scene_map =
        Enum.reduce(objects_list, %{}, fn map_obj, acc ->
          case safe_to_instance(map_obj) do
            {:ok, object_id, instance} ->
              Map.put(acc, object_id, instance)

            {:error, reason} ->
              CliObserve.emit("voxel_object_load_skipped_corrupt", fn ->
                %{
                  logical_scene_id: scene_id,
                  object_id: corrupt_object_id_hint(map_obj),
                  reason: inspect(reason)
                }
              end)

              acc
          end
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

  # LOAD 路径专用:把 to_instance 的 raise(坏 part_states / 越界数值 / 缺 object_id /
  # map_obj 非 map)收敛成 {:error, exception},供 ensure_scene_loaded drop 坏行。
  defp safe_to_instance(map_obj) do
    instance = to_instance(map_obj)
    object_id = Map.fetch!(instance, :object_id)
    {:ok, object_id, instance}
  rescue
    exception -> {:error, exception}
  end

  defp corrupt_object_id_hint(map_obj) when is_map(map_obj) do
    Map.get(map_obj, :object_id) || Map.get(map_obj, "object_id")
  end

  defp corrupt_object_id_hint(_map_obj), do: nil

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
