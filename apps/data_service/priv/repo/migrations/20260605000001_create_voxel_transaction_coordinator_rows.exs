defmodule DataService.Repo.Migrations.CreateVoxelTransactionCoordinatorRows do
  use Ecto.Migration

  @moduledoc """
  阶段4 / world-2pc-4:行级增量持久化后端,取代单行全量 snapshot。

  每笔事务一行,主键 `transaction_id`(`:erlang.term_to_binary/1` 编码的事务 id
  字节串,既能容纳 binary id 也能容纳 `{:voxel_transaction, integer}` tuple id)。
  `payload` 是该事务的可恢复全量(完整 `%BuildTransaction{}` + begin fingerprint +
  最新决策归档记录)的 `:erlang.term_to_binary/1` blob,只在 server 端用、不上
  wire、不跨语言。

  协调者每次 state 突变只 upsert 变更过的事务行(`insert_all` + on_conflict
  replace),写代价随单回合变更量而非历史总量;终态事务裁出活跃集后行收敛成
  只带决策归档的轻量历史行。

  无迁移债:旧的单行 `voxel_transaction_coordinator_snapshots` 表在 `up` 直接
  drop(那张表只是 Phase 3-1 的全量 blob 后端,没有需要保留的独立真相);`down`
  重建空壳以便回滚。
  """

  def up do
    create table(:voxel_transaction_coordinator_rows, primary_key: false) do
      add(:transaction_id, :binary, primary_key: true)
      add(:payload, :binary, null: false)

      timestamps()
    end

    # 旧单行全量 snapshot 表退役(无迁移债,不保留双写兼容)。
    drop_if_exists(table(:voxel_transaction_coordinator_snapshots))
  end

  def down do
    drop_if_exists(table(:voxel_transaction_coordinator_rows))

    create_if_not_exists table(:voxel_transaction_coordinator_snapshots, primary_key: false) do
      add(:id, :integer, primary_key: true)
      add(:payload, :binary, null: false)

      timestamps()
    end
  end
end
