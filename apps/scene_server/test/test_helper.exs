# Voxel chunk persistence (`DataService.Voxel.ChunkSnapshotStore`) writes to
# PostgreSQL via Ecto since Phase 1d. Boot data_service so its application owns
# Repo and token-store processes, then run migrations for scene tests that
# exercise persist paths against real `voxel_chunks` rows.
Application.ensure_all_started(:jason)
Application.ensure_all_started(:postgrex)
Application.ensure_all_started(:ecto_sql)

repo_config = DataService.Repo.config()

case Ecto.Adapters.Postgres.storage_up(repo_config) do
  :ok -> :ok
  {:error, :already_up} -> :ok
end

{:ok, _} = Application.ensure_all_started(:data_service)

migrations_path =
  Path.expand("../../data_service/priv/repo/migrations", __DIR__)

{:ok, _, _} =
  Ecto.Migrator.with_repo(DataService.Repo, fn repo ->
    Ecto.Migrator.run(repo, migrations_path, :up, all: true)
  end)

# 共享 mmo_dev 库可能残留上次运行的陈旧事务快照,导致 TransactionRecoveryWatcher 启动时
# 因 stale `:prepared` 快照崩溃(session-handoff 既有 backlog)。套件启动前清表以隔离。
for table <- ["voxel_transaction_coordinator_snapshots", "voxel_chunk_pending_transactions"] do
  Ecto.Adapters.SQL.query!(DataService.Repo, "TRUNCATE #{table}", [])
end

# Phase A4-bis: scene-side region routing tests (`RegionRouting`,
# `RegionRuntime` Phase A4-bis-3 e2e) call `BeaconServer.Client.register`
# / `lookup`, which require a Horde registry. Boot it once here so the
# CRDT keys ETS table has time to settle before any test touches it
# (per-test `start_link` from a `setup` block races with Horde init).
case Horde.Registry.start_link(
       name: BeaconServer.DistributedRegistry,
       keys: :unique,
       members: :auto
     ) do
  {:ok, _} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

defmodule SceneServer.TestVoxelRuntime do
  @moduledoc false

  def ensure_started! do
    # 梯队2 step2.6:SimRuntime 必须在 FieldTickSupervisor 之前起(worker subscribe 它)。
    ensure_started!(
      SceneServer.Voxel.Field.SimRuntime,
      {SceneServer.Voxel.Field.SimRuntime, name: SceneServer.Voxel.Field.SimRuntime}
    )

    ensure_started!(
      SceneServer.Voxel.Field.FieldTickSupervisor,
      {SceneServer.Voxel.Field.FieldTickSupervisor,
       name: SceneServer.Voxel.Field.FieldTickSupervisor}
    )

    ensure_started!(
      SceneServer.VoxelChunkSup,
      {SceneServer.VoxelChunkSup, name: SceneServer.VoxelChunkSup}
    )

    ensure_started!(
      SceneServer.Voxel.ChunkDirectory,
      {SceneServer.Voxel.ChunkDirectory, name: SceneServer.Voxel.ChunkDirectory}
    )
  end

  defp ensure_started!(name, child_spec) do
    case Process.whereis(name) do
      nil ->
        case ExUnit.Callbacks.start_supervised(child_spec) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end
end

# Phase 1d: voxel chunk persistence is real PostgreSQL via Ecto. Bump the
# default `assert_receive` window so tests waiting on apply→persist→delta
# round trips don't flake on a real DB INSERT.
ExUnit.start(exclude: [:smoke], assert_receive_timeout: 1_000)
