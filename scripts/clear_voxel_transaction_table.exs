{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = DataService.Repo.start_link()

count = DataService.Repo.aggregate(DataService.Schema.VoxelTransactionCoordinatorSnapshot, :count, :id)
IO.puts("rows before: #{count}")

DataService.Repo.delete_all(DataService.Schema.VoxelTransactionCoordinatorSnapshot)

count = DataService.Repo.aggregate(DataService.Schema.VoxelTransactionCoordinatorSnapshot, :count, :id)
IO.puts("rows after: #{count}")
