defmodule DataService.Repo.Migrations.CreateVoxelRegionDirectory do
  use Ecto.Migration

  @moduledoc """
  Durable per-region ownership directory for `WorldServer.Voxel.MapLedger`
  (阶段2,CELL-23 region 所有权/lease 目录)。

  **scale-first**:每个 region **一行**(主键 `region_id`,全局唯一且编码了
  `logical_scene_id`),物化/续约/迁移只写/改**一行** —— O(1) per change,而非把整个
  ledger 快照 term_to_binary 进单行 blob(旧 `voxel_map_ledger_snapshots` 的 O(N) 反模式)。
  `logical_scene_id` 建索引以支持**按 logical_scene 分片**载入(resolver:`region_id →
  owning ledger shard` 将来按段分片是部署配置而非重构)。

  一行承载重建 `RegionAssignment` + `SceneLease` 所需的全部字段:bounds 半开 AABB(含 Y,
  6 整型列)、owner 身份(`owner_scene_instance_ref`/`owner_epoch`)、`lease_id`、
  `assigned_scene_node`(承载热执行的 BEAM 节点)、`region_state`、`region_version`、
  `expires_at_ms`(lease 到期)。
  """

  def change do
    create table(:voxel_region_directory, primary_key: false) do
      add(:region_id, :bigint, primary_key: true)
      add(:logical_scene_id, :bigint, null: false)
      add(:bounds_chunk_min_x, :integer, null: false)
      add(:bounds_chunk_min_y, :integer, null: false)
      add(:bounds_chunk_min_z, :integer, null: false)
      add(:bounds_chunk_max_x, :integer, null: false)
      add(:bounds_chunk_max_y, :integer, null: false)
      add(:bounds_chunk_max_z, :integer, null: false)
      add(:owner_scene_instance_ref, :bigint, null: false)
      add(:owner_epoch, :bigint, null: false)
      # nil before a lease has been issued (a put_region with no lease yet).
      add(:lease_id, :bigint, null: true)
      add(:assigned_scene_node, :text, null: true)
      add(:region_state, :text, null: false, default: "active")
      add(:region_version, :bigint, null: false, default: 0)
      add(:expires_at_ms, :bigint, null: true)

      timestamps()
    end

    # Shard-load query path: load all regions for one logical scene.
    create(index(:voxel_region_directory, [:logical_scene_id]))

    for {field, name} <- [
          {"region_id", "voxel_region_directory_region_id_nonneg"},
          {"logical_scene_id", "voxel_region_directory_logical_scene_id_nonneg"},
          {"owner_scene_instance_ref", "voxel_region_directory_owner_scene_instance_ref_nonneg"},
          {"owner_epoch", "voxel_region_directory_owner_epoch_nonneg"},
          {"region_version", "voxel_region_directory_region_version_nonneg"}
        ] do
      execute(
        "ALTER TABLE voxel_region_directory ADD CONSTRAINT #{name} CHECK (#{field} >= 0)",
        "ALTER TABLE voxel_region_directory DROP CONSTRAINT #{name}"
      )
    end
  end
end
