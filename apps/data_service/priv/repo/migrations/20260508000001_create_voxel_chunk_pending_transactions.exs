defmodule DataService.Repo.Migrations.CreateVoxelChunkPendingTransactions do
  use Ecto.Migration

  @moduledoc """
  Canonical persistence for `DataService.Voxel.ChunkPendingTransactionStore`.

  Phase 3-bis (D1):每个被 prepare 的 voxel chunk fence 落一行,Scene 重启时
  ChunkProcess.init 从这张表 reload `pending_fence`,确保两阶段提交事务在
  Scene/coordinator 任意 crash 组合下都能推进到终态。

  复合主键 `(logical_scene_id, coord_x, coord_y, coord_z)` 与 `voxel_chunks`
  表对齐,沿用全系统 chunk 自然主键风格(wire 协议、ChunkDirectory 注册都
  用这个 4 元组,不引入 surrogate id)。一个 chunk 同时只能持一个 fence。

  `fence_payload` 是 `:erlang.term_to_binary/1` 编码的 normalized intent
  batch(`SceneServer.Voxel.ChunkProcess` 内部形态),只在 server 端用,不上
  wire,不跨语言。

  `owner_*` 四个字段记录 fence 创建时挂的 lease。Scene 重启后 lease 可能换
  epoch,load 时如果 owner_* 与当前 lease 不一致,该 fence 视为孤儿丢弃。

  所有 `bigint` 字段约束 `>= 0`,与 v1 协议 u63 限制一致。
  """

  def change do
    create table(:voxel_chunk_pending_transactions, primary_key: false) do
      add(:logical_scene_id, :bigint, null: false)
      add(:coord_x, :integer, null: false)
      add(:coord_y, :integer, null: false)
      add(:coord_z, :integer, null: false)
      add(:transaction_id, :binary, null: false)
      add(:decision_version, :integer, null: false)
      add(:owner_region_id, :bigint, null: false)
      add(:owner_lease_id, :bigint, null: false)
      add(:owner_scene_instance_ref, :bigint, null: false)
      add(:owner_epoch, :bigint, null: false)
      add(:fence_payload, :binary, null: false)
      add(:fenced_at_ms, :bigint, null: false)

      timestamps()
    end

    execute(
      """
      ALTER TABLE voxel_chunk_pending_transactions
        ADD CONSTRAINT voxel_chunk_pending_transactions_pkey
        PRIMARY KEY (logical_scene_id, coord_x, coord_y, coord_z)
      """,
      "ALTER TABLE voxel_chunk_pending_transactions DROP CONSTRAINT voxel_chunk_pending_transactions_pkey"
    )

    for {field, name} <- [
          {"logical_scene_id", "voxel_chunk_pending_transactions_logical_scene_id_nonneg"},
          {"decision_version", "voxel_chunk_pending_transactions_decision_version_nonneg"},
          {"owner_region_id", "voxel_chunk_pending_transactions_owner_region_id_nonneg"},
          {"owner_lease_id", "voxel_chunk_pending_transactions_owner_lease_id_nonneg"},
          {"owner_scene_instance_ref",
           "voxel_chunk_pending_transactions_owner_scene_instance_ref_nonneg"},
          {"owner_epoch", "voxel_chunk_pending_transactions_owner_epoch_nonneg"},
          {"fenced_at_ms", "voxel_chunk_pending_transactions_fenced_at_ms_nonneg"}
        ] do
      execute(
        "ALTER TABLE voxel_chunk_pending_transactions ADD CONSTRAINT #{name} CHECK (#{field} >= 0)",
        "ALTER TABLE voxel_chunk_pending_transactions DROP CONSTRAINT #{name}"
      )
    end
  end
end
