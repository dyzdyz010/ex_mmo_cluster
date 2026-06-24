Application.ensure_all_started(:postgrex)
Application.ensure_all_started(:ecto_sql)
{:ok, _} = DataService.Repo.start_link()

tables = [
  "voxel_transaction_coordinator_snapshots",
  "voxel_chunk_pending_transactions",
  "voxel_chunks",
  "voxel_scene_objects",
  "voxel_write_tokens",
  "voxel_region_epochs"
]

Enum.each(tables, fn t ->
  case Ecto.Adapters.SQL.query(DataService.Repo, "TRUNCATE TABLE #{t} RESTART IDENTITY CASCADE") do
    {:ok, _} -> IO.puts("truncated #{t}")
    {:error, %{postgres: %{message: msg}}} -> IO.puts("skip #{t}: #{msg}")
    other -> IO.inspect(other)
  end
end)
