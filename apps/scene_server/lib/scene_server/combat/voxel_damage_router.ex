defmodule SceneServer.Combat.VoxelDamageRouter do
  @moduledoc """
  Phase A1-5:玩家 skill cast 命中体素时的 voxel-damage 路由。
  Phase A4-4 (D7):跨 region prefab 的 owner 路由 + RPC fallback。

  从 wire 来的 `target_position` 是 world micro coord(整数,1 unit = 1 micro
  cell = 1/8 macro);Skill cast 同时可能命中 actor 跟 voxel。Combat.Executor
  原路径只 dispatch actor damage;本模块独立处理 voxel 路径,在 actor damage
  并行 dispatch ObjectRegistry.accumulate_damage。

  实现走 last persisted snapshot 反查(`DataService.Voxel.ChunkSnapshotStore`),
  不绕 ChunkProcess GenServer 直查 in-memory storage。snapshot 在 commit 时
  持久化,所以可能比 in-memory 落后一个 transaction commit 周期。对 demo /
  路演来说足够,Phase 5 切到 in-memory ChunkProcess.lookup_owner_at(read-only
  GenServer.call)是 follow-up 优化。

  ## Phase A4-4 cross-region routing (D7)

  跨 region prefab 落地后,owner 在 `voxel_scene_objects.owner_region_id`
  里;跨 region 时玩家攻击的 chunk 可能不在 owner region。新增的
  `SceneServer.Voxel.ObjectOwnerLookup` 把 owner 元数据 cache 在 scene 端,
  router 在拿到 `(object_id, part_id)` 后:

    1. 调 `ObjectOwnerLookup.fetch_owner` 拿 owner_region_id / owner_lease_id
    2. 通过 `:scene_node_resolver_fn` opt 把 `(region_id, lease_id)` 映射到
       owner scene_node(默认 `node()`,即生产单 scene_node 路径退化为本地)
    3. owner 在本地 → 走原 `ObjectRegistry.accumulate_damage(__MODULE__, ...)`
       路径
    4. owner 在远端 → `ObjectRegistry.accumulate_damage({Mod, scene_node}, ...)`
       透明跨节点 GenServer.call,带 `:call_timeout`(默认 200ms)。失败 emit
       `voxel_damage_cross_region_failed` observe + drop(不重试,不破坏 damage
       主路径,Phase 6 HA 范围)。

  Out of scope(本阶段):

    - 跨 chunk damage(本路径只命中目标 micro slot 所在的 chunk)
    - 物理 hit detection 精度修正(target_position 来自 client raycast,服务端
      不再二次校验)
    - Phase 5 attribute_patch / temperature 副作用(纯破坏 / part_health 链路)
    - 跨节点 damage RPC 的重试 / 死信队列(Phase 6 HA)
  """

  alias DataService.Voxel.ChunkSnapshotStore
  alias SceneServer.CliObserve
  alias SceneServer.Voxel.{Codec, ObjectOwnerLookup, ObjectRegistry, Storage, Types}

  @typedoc "World micro coord(integer x/y/z,1 unit = 1 micro cell)。"
  @type world_micro :: {integer(), integer(), integer()}

  @typedoc "Damage application outcome。"
  @type apply_outcome ::
          :no_voxel
          | {:applied, %{object_id: non_neg_integer(), part_id: non_neg_integer()}}
          | {:cascade, term()}
          | {:error, term()}

  # Phase A4-4 D7:跨节点 GenServer.call 默认 200ms 超时。同步阻塞 combat
  # tick 的窗口必须短;失败统一 emit observe + drop。
  @default_cross_region_call_timeout_ms 200

  @doc """
  Tries to apply `damage` at the world micro coord. Returns:

    * `:no_voxel` —— 该 slot 当前没有任何 owner(空 macro / 边界外 / 未持久化)
    * `{:applied, %{object_id, part_id}}` —— damage 落到具体 part
    * `{:cascade, ObjectRegistry result}` —— part / object destroyed,registry
      已自动 fan-out 0x6C ObjectStateDelta(Phase 4-bis 链路)
    * `{:error, reason}` —— ChunkSnapshotStore / decode / registry 任一层失败

  Optional `opts`:

    * `:object_registry` — registry module (test override, default
      `SceneServer.Voxel.ObjectRegistry`)
    * `:owner_lookup` / `:owner_lookup_server` — `ObjectOwnerLookup` module +
      named server pair (Phase A4-4 routing). Default `ObjectOwnerLookup`.
    * `:scene_node_resolver_fn` — `(region_id, lease_id -> node())`. Returns
      the scene_node currently hosting that region's `ObjectRegistry`.
      Defaults to `fn _, _ -> node() end` (生产单 scene_node)。
    * `:cross_region_call_timeout_ms` — `GenServer.call` timeout for the
      cross-node hop. Defaults to `200`.
    * `:chunk_snapshot_store` — module exposing `get_snapshot/2` (test
      override, default `DataService.Voxel.ChunkSnapshotStore`)
  """
  @spec try_apply_damage(non_neg_integer(), world_micro(), non_neg_integer(), keyword()) ::
          apply_outcome()
  def try_apply_damage(scene_id, {wmx, wmy, wmz}, damage, opts \\ [])
      when is_integer(scene_id) and scene_id >= 0 and is_integer(damage) and damage > 0 do
    snapshot_store = Keyword.get(opts, :chunk_snapshot_store, ChunkSnapshotStore)
    micro = Types.micro_resolution()

    world_macro_x = Types.floor_div(wmx, micro)
    world_macro_y = Types.floor_div(wmy, micro)
    world_macro_z = Types.floor_div(wmz, micro)

    local_micro_x = Types.floor_mod(wmx, micro)
    local_micro_y = Types.floor_mod(wmy, micro)
    local_micro_z = Types.floor_mod(wmz, micro)

    micro_slot = local_micro_x + local_micro_y * micro + local_micro_z * micro * micro

    {chunk_coord, local_macro} =
      Types.chunk_and_local_macro!({world_macro_x, world_macro_y, world_macro_z})

    with {:ok, row} <- snapshot_store.get_snapshot(scene_id, chunk_coord),
         {:ok, %{storage: storage}} <- Codec.decode_chunk_snapshot_payload(row.data),
         {object_id, part_id} <- Storage.lookup_owner_at(storage, local_macro, micro_slot) do
      route_and_apply(scene_id, object_id, part_id, damage, opts)
    else
      {:error, :snapshot_not_found} -> :no_voxel
      {:error, :invalid_chunk_snapshot_payload} -> :no_voxel
      {:error, reason} -> {:error, reason}
      nil -> :no_voxel
    end
  end

  # Phase A4-4 D7:locate the owner via `ObjectOwnerLookup` and route the
  # `accumulate_damage` call to the owning scene_node. Single-region
  # production (`scene_node_resolver_fn` defaults to `node()`) keeps the
  # original local path intact.
  defp route_and_apply(scene_id, object_id, part_id, damage, opts) do
    object_registry = Keyword.get(opts, :object_registry, ObjectRegistry)
    owner_lookup = Keyword.get(opts, :owner_lookup, ObjectOwnerLookup)
    owner_lookup_server = Keyword.get(opts, :owner_lookup_server, ObjectOwnerLookup)

    scene_node_resolver =
      Keyword.get(opts, :scene_node_resolver_fn, fn _region_id, _lease_id -> node() end)

    cross_region_timeout =
      Keyword.get(opts, :cross_region_call_timeout_ms, @default_cross_region_call_timeout_ms)

    case fetch_owner(owner_lookup, owner_lookup_server, scene_id, object_id) do
      {:ok, %{owner_region_id: region_id, owner_lease_id: lease_id}} ->
        scene_node = scene_node_resolver.(region_id, lease_id)
        cross_region? = scene_node != node()
        target = registry_target(object_registry, scene_node, cross_region?)

        if cross_region? do
          emit_cross_region_routed(scene_id, object_id, part_id, region_id, lease_id, scene_node)
        end

        apply_to_registry(target, scene_id, object_id, part_id, damage, %{
          cross_region?: cross_region?,
          owner_region_id: region_id,
          owner_lease_id: lease_id,
          owner_scene_node: scene_node,
          call_timeout: cross_region_timeout
        })

      {:error, :not_found} ->
        # 兼容 A1/A2 单 region 路径:owner 元数据未 register 时回退本地直调
        # (legacy:Phase A1-5 启用前 prefab 不分配 scene_object,本地 ObjectRegistry
        # 也没有该实例,这条路径自然返回 :object_not_found)。
        apply_to_registry(object_registry, scene_id, object_id, part_id, damage, %{
          cross_region?: false
        })
    end
  end

  defp fetch_owner(owner_lookup, owner_lookup_server, scene_id, object_id) do
    owner_lookup.fetch_owner(owner_lookup_server, scene_id, object_id)
  rescue
    ArgumentError -> {:error, :not_found}
  catch
    :exit, _reason -> {:error, :not_found}
  end

  defp registry_target(object_registry, _scene_node, false), do: object_registry

  defp registry_target(object_registry, scene_node, true) when is_atom(object_registry),
    do: {object_registry, scene_node}

  defp registry_target(object_registry, _scene_node, true) do
    # Non-atom server (PID / `{Mod, node}`) cannot be re-targeted to another
    # node from here;the caller has overridden `:object_registry` explicitly,
    # honour it as-is and skip the cross-region hop.
    object_registry
  end

  defp apply_to_registry(target, scene_id, object_id, part_id, damage, ctx) do
    timeout = Map.get(ctx, :call_timeout, 5_000)

    GenServer.call(
      target,
      {:accumulate_damage, scene_id, object_id, part_id, damage, []},
      timeout
    )
    |> normalize_registry_outcome(scene_id, object_id, part_id)
  catch
    :exit, reason ->
      if Map.get(ctx, :cross_region?, false) do
        emit_cross_region_failed(
          scene_id,
          object_id,
          part_id,
          ctx.owner_region_id,
          ctx.owner_lease_id,
          ctx.owner_scene_node,
          reason
        )
      end

      {:error, {:registry_unavailable, reason}}
  end

  defp normalize_registry_outcome(:ok, _scene_id, object_id, part_id) do
    {:applied, %{object_id: object_id, part_id: part_id}}
  end

  defp normalize_registry_outcome({:part_destroyed, _payload} = cascade, _, _, _),
    do: {:cascade, cascade}

  defp normalize_registry_outcome({:object_destroyed, _payload} = cascade, _, _, _),
    do: {:cascade, cascade}

  defp normalize_registry_outcome({:error, reason}, _, _, _), do: {:error, reason}

  defp emit_cross_region_routed(scene_id, object_id, part_id, region_id, lease_id, scene_node) do
    CliObserve.emit("voxel_damage_routed_cross_region", fn ->
      %{
        logical_scene_id: scene_id,
        object_id: object_id,
        part_id: part_id,
        owner_region_id: region_id,
        owner_lease_id: lease_id,
        owner_scene_node: scene_node
      }
    end)
  end

  defp emit_cross_region_failed(
         scene_id,
         object_id,
         part_id,
         region_id,
         lease_id,
         scene_node,
         reason
       ) do
    CliObserve.emit("voxel_damage_cross_region_failed", fn ->
      %{
        logical_scene_id: scene_id,
        object_id: object_id,
        part_id: part_id,
        owner_region_id: region_id,
        owner_lease_id: lease_id,
        owner_scene_node: scene_node,
        reason: inspect(reason)
      }
    end)
  end
end
