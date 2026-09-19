ExUnit.start(exclude: [:smoke], assert_receive_timeout: 1_000)
Code.require_file("../../data_service/test/support/database.exs", __DIR__)
defmodule SceneServer.TestVoxelRuntime do
  @moduledoc false

  def start_registry! do
    # DataService 的应用依赖也可能已启动 Beacon；否则由当前测试模块持有监督树。
    unless Process.whereis(BeaconServer.DistributedRegistry) do
      ExUnit.Callbacks.start_supervised!({Horde.Registry,
        name: BeaconServer.DistributedRegistry, keys: :unique, members: :auto})
    end
    :ok
  end

  def ensure_started! do
    MmoTest.Database.start!()
    # 梯队2 step2.6:SimRuntime 必须在 FieldTickSupervisor 之前起(worker subscribe 它)。
    ensure_started!(
      SceneServer.Voxel.Field.SimRuntime,
      {SceneServer.Voxel.Field.SimRuntime, name: SceneServer.Voxel.Field.SimRuntime}
    )

    # 梯队3 step3.8:SystemActor 在 FieldTickSupervisor 之前起(field effect 提交它)。
    ensure_started!(
      SceneServer.Voxel.Field.SystemActor,
      {SceneServer.Voxel.Field.SystemActor, name: SceneServer.Voxel.Field.SystemActor}
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
