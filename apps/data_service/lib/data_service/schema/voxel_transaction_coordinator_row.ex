defmodule DataService.Schema.VoxelTransactionCoordinatorRow do
  @moduledoc """
  Per-transaction Ecto row for `WorldServer.Voxel.TransactionCoordinator`.

  阶段4 / world-2pc-4 行级增量持久化:每笔事务一行,主键
  `transaction_id`(`:erlang.term_to_binary/1` 编码的事务 id 字节串)。`payload`
  是该事务的可恢复全量(完整 struct + fingerprint + 最新决策归档记录)的
  `:erlang.term_to_binary/1` blob。

  See `DataService.Voxel.TransactionCoordinatorStore` for the read/write helpers
  world_server uses; tests should not insert through this schema directly.

  取代旧的单行 `voxel_transaction_coordinator_snapshots`
  (`DataService.Schema.VoxelTransactionCoordinatorSnapshot`)——后者每次变更都
  `term_to_binary` 全量历史,写代价随历史线性恶化。无迁移债:不保留双写兼容层,
  旧表由 drop 迁移直接退役。
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:transaction_id, :binary, autogenerate: false}

  schema "voxel_transaction_coordinator_rows" do
    field(:payload, :binary)

    timestamps()
  end

  @doc false
  def changeset(row, attrs) do
    row
    |> cast(attrs, [:transaction_id, :payload])
    |> validate_required([:transaction_id, :payload])
  end
end
