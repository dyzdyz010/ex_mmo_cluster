defmodule DataService.Repo.Migrations.CreateVoxelWriteTokens do
  use Ecto.Migration

  @moduledoc """
  Durable backing for `DataService.Voxel.WriteTokenStore`(梯队1 step1.2,CELL-19/21)。

  World 为每个 region 发布当前 lease 写令牌;DataService 在每次 voxel 写入前据此校验
  owner_epoch/lease,使旧 scene 实例在迁移/lease 翻转后无法落库。此前 token 仅在内存,
  节点重启即失效(fencing 失效窗口);本表令其可恢复,`token_version` 提供 CAS 单调。

  复合主键 `(logical_scene_id, region_id)`。bounds 以 6 个 integer 列存半开 AABB
  `min <= c < max`(含 Y,D-2)。
  """

  def change do
    create table(:voxel_write_tokens, primary_key: false) do
      add(:logical_scene_id, :bigint, null: false)
      add(:region_id, :bigint, null: false)
      add(:lease_id, :bigint, null: false)
      add(:owner_scene_instance_ref, :bigint, null: false)
      add(:owner_epoch, :bigint, null: false)
      add(:bounds_chunk_min_x, :integer, null: false)
      add(:bounds_chunk_min_y, :integer, null: false)
      add(:bounds_chunk_min_z, :integer, null: false)
      add(:bounds_chunk_max_x, :integer, null: false)
      add(:bounds_chunk_max_y, :integer, null: false)
      add(:bounds_chunk_max_z, :integer, null: false)
      add(:expires_at_ms, :bigint, null: false)
      add(:token_version, :bigint, null: false)

      timestamps()
    end

    execute(
      """
      ALTER TABLE voxel_write_tokens
        ADD CONSTRAINT voxel_write_tokens_pkey
        PRIMARY KEY (logical_scene_id, region_id)
      """,
      "ALTER TABLE voxel_write_tokens DROP CONSTRAINT voxel_write_tokens_pkey"
    )

    for {field, name} <- [
          {"logical_scene_id", "voxel_write_tokens_logical_scene_id_nonneg"},
          {"region_id", "voxel_write_tokens_region_id_nonneg"},
          {"lease_id", "voxel_write_tokens_lease_id_nonneg"},
          {"owner_scene_instance_ref", "voxel_write_tokens_owner_scene_instance_ref_nonneg"},
          {"owner_epoch", "voxel_write_tokens_owner_epoch_nonneg"},
          {"expires_at_ms", "voxel_write_tokens_expires_at_ms_nonneg"},
          {"token_version", "voxel_write_tokens_token_version_nonneg"}
        ] do
      execute(
        "ALTER TABLE voxel_write_tokens ADD CONSTRAINT #{name} CHECK (#{field} >= 0)",
        "ALTER TABLE voxel_write_tokens DROP CONSTRAINT #{name}"
      )
    end
  end
end
