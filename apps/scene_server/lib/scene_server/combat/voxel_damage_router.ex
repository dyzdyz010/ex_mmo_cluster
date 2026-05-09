defmodule SceneServer.Combat.VoxelDamageRouter do
  @moduledoc """
  Phase A1-5:玩家 skill cast 命中体素时的 voxel-damage 路由。

  从 wire 来的 `target_position` 是 world micro coord(整数,1 unit = 1 micro
  cell = 1/8 macro);Skill cast 同时可能命中 actor 跟 voxel。Combat.Executor
  原路径只 dispatch actor damage;本模块独立处理 voxel 路径,在 actor damage
  并行 dispatch ObjectRegistry.accumulate_damage。

  实现走 last persisted snapshot 反查(`DataService.Voxel.ChunkSnapshotStore`),
  不绕 ChunkProcess GenServer 直查 in-memory storage。snapshot 在 commit 时
  持久化,所以可能比 in-memory 落后一个 transaction commit 周期。对 demo /
  路演来说足够,Phase 5 切到 in-memory ChunkProcess.lookup_owner_at(read-only
  GenServer.call)是 follow-up 优化。

  Out of scope(本阶段):
    - 跨 chunk damage(本路径只命中目标 micro slot 所在的 chunk)
    - 物理 hit detection 精度修正(target_position 来自 client raycast,服务端
      不再二次校验)
    - Phase 5 attribute_patch / temperature 副作用(纯破坏 / part_health 链路)
  """

  alias DataService.Voxel.ChunkSnapshotStore
  alias SceneServer.Voxel.{Codec, ObjectRegistry, Storage, Types}

  @typedoc "World micro coord(integer x/y/z,1 unit = 1 micro cell)。"
  @type world_micro :: {integer(), integer(), integer()}

  @typedoc "Damage application outcome。"
  @type apply_outcome ::
          :no_voxel
          | {:applied, %{object_id: non_neg_integer(), part_id: non_neg_integer()}}
          | {:cascade, term()}
          | {:error, term()}

  @doc """
  Tries to apply `damage` at the world micro coord. Returns:

    * `:no_voxel` —— 该 slot 当前没有任何 owner(空 macro / 边界外 / 未持久化)
    * `{:applied, %{object_id, part_id}}` —— damage 落到具体 part
    * `{:cascade, ObjectRegistry result}` —— part / object destroyed,registry
      已自动 fan-out 0x6C ObjectStateDelta(Phase 4-bis 链路)
    * `{:error, reason}` —— ChunkSnapshotStore / decode / registry 任一层失败
  """
  @spec try_apply_damage(non_neg_integer(), world_micro(), non_neg_integer(), keyword()) ::
          apply_outcome()
  def try_apply_damage(scene_id, {wmx, wmy, wmz}, damage, opts \\ [])
      when is_integer(scene_id) and scene_id >= 0 and is_integer(damage) and damage > 0 do
    object_registry = Keyword.get(opts, :object_registry, ObjectRegistry)
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

    with {:ok, row} <- ChunkSnapshotStore.get_snapshot(scene_id, chunk_coord),
         {:ok, %{storage: storage}} <- Codec.decode_chunk_snapshot_payload(row.data),
         {object_id, part_id} <- Storage.lookup_owner_at(storage, local_macro, micro_slot) do
      apply_to_registry(object_registry, scene_id, object_id, part_id, damage)
    else
      {:error, :snapshot_not_found} -> :no_voxel
      {:error, :invalid_chunk_snapshot_payload} -> :no_voxel
      {:error, reason} -> {:error, reason}
      nil -> :no_voxel
    end
  end

  defp apply_to_registry(registry, scene_id, object_id, part_id, damage) do
    case ObjectRegistry.accumulate_damage(registry, scene_id, object_id, part_id, damage) do
      :ok ->
        {:applied, %{object_id: object_id, part_id: part_id}}

      {:part_destroyed, _payload} = cascade ->
        {:cascade, cascade}

      {:object_destroyed, _payload} = cascade ->
        {:cascade, cascade}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
