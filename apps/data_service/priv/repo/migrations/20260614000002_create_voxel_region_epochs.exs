defmodule DataService.Repo.Migrations.CreateVoxelRegionEpochs do
  use Ecto.Migration

  @moduledoc """
  Linearizable owner_epoch allocator backing(梯队1 step1.3,CELL-18/23,消除 ANTI-32)。

  每个 region 一行,`owner_epoch` 为单调计数。`DataService.Voxel.RegionEpochStore.allocate_next/2`
  以单条原子 `INSERT ... ON CONFLICT DO UPDATE SET owner_epoch = owner_epoch + 1 RETURNING owner_epoch`
  分配下一个 epoch——Postgres 行级序列化保证即使并发/重启的多个 MapLedger 也无法分配冲突或回退的
  epoch(此前 epoch 仅靠内存单进程 + 整库 blob,正中 ANTI-32)。

  复合主键 `(logical_scene_id, region_id)`。
  """

  def change do
    create table(:voxel_region_epochs, primary_key: false) do
      add(:logical_scene_id, :bigint, null: false)
      add(:region_id, :bigint, null: false)
      add(:owner_epoch, :bigint, null: false)

      timestamps()
    end

    execute(
      """
      ALTER TABLE voxel_region_epochs
        ADD CONSTRAINT voxel_region_epochs_pkey
        PRIMARY KEY (logical_scene_id, region_id)
      """,
      "ALTER TABLE voxel_region_epochs DROP CONSTRAINT voxel_region_epochs_pkey"
    )

    execute(
      "ALTER TABLE voxel_region_epochs ADD CONSTRAINT voxel_region_epochs_owner_epoch_nonneg " <>
        "CHECK (owner_epoch >= 0)",
      "ALTER TABLE voxel_region_epochs DROP CONSTRAINT voxel_region_epochs_owner_epoch_nonneg"
    )
  end
end
