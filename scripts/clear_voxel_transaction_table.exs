{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = DataService.Repo.start_link()

# 阶段4 / world-2pc-4:协调者持久化已从单行全量 snapshot 改为
# voxel_transaction_coordinator_rows 行级增量表。
count = DataService.Repo.aggregate(DataService.Schema.VoxelTransactionCoordinatorRow, :count)
IO.puts("rows before: #{count}")

DataService.Repo.delete_all(DataService.Schema.VoxelTransactionCoordinatorRow)

count = DataService.Repo.aggregate(DataService.Schema.VoxelTransactionCoordinatorRow, :count)
IO.puts("rows after: #{count}")
