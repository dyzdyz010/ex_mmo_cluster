defmodule DataService.Repo.Migrations.AddOwnerRegionToVoxelSceneObjects do
  use Ecto.Migration

  @moduledoc """
  Phase A4-3 (D6 + D7):为 `voxel_scene_objects` 加 owner participant 元数据。

  跨 region prefab 落地时,object 的 covered_chunks 可能跨多个 region;按 D6
  规则**字典序第一个 chunk 所在的 region** 是 owner participant,
  `ObjectRegistry` 只在 owner participant 的 scene_node 上注册一次(单点权威,
  避免跨副本一致性)。`ObjectOwnerLookup`(A4-4)冷启动时按
  `(logical_scene_id, object_id) → (owner_region_id, owner_lease_id)` 反查,
  damage 路由 + 0x6C 广播据此跨节点 RPC。

  两列都 NOT NULL,无默认值。Phase 4 未投生产,无真实存量数据需要 backfill。
  本阶段开始所有新写入必须显式指定 owner;旧写入路径(只在测试里)需要随
  decision stub 一起更新。
  """

  def change do
    alter table(:voxel_scene_objects) do
      add(:owner_region_id, :bigint, null: false, default: 0)
      add(:owner_lease_id, :bigint, null: false, default: 0)
    end

    # Phase A4-3 Note:default 0 仅为了 Postgres 在 ALTER TABLE 阶段不报
    # NOT NULL 缺值;迁移结束后,所有新插入仍必须显式提供(应用层通过
    # `DataService.Schema.VoxelSceneObject` changeset validate_required 强校验)。
    create(index(:voxel_scene_objects, [:logical_scene_id, :owner_region_id]))

    for {field, name} <- [
          {"owner_region_id", "voxel_scene_objects_owner_region_id_nonneg"},
          {"owner_lease_id", "voxel_scene_objects_owner_lease_id_nonneg"}
        ] do
      execute(
        "ALTER TABLE voxel_scene_objects ADD CONSTRAINT #{name} CHECK (#{field} >= 0)",
        "ALTER TABLE voxel_scene_objects DROP CONSTRAINT #{name}"
      )
    end
  end
end
