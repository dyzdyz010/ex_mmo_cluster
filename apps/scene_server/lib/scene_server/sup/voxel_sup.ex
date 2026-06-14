defmodule SceneServer.VoxelSup do
  @moduledoc """
  Supervisor for scene-side voxel runtime processes.

  The voxel subtree owns hot lease state, boundary-event validation, and the
  directory/dynamic supervisor used for per-chunk hot truth processes.
  """

  use Supervisor

  @doc "Starts the scene voxel supervisor."
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    children = [
      # Phase 5.C: typed attribute / tag catalogs must come up before
      # ChunkProcess / any future worker that resolves catalog ids by name.
      {SceneServer.Voxel.AttributeCatalog, name: SceneServer.Voxel.AttributeCatalog},
      {SceneServer.Voxel.TagCatalog, name: SceneServer.Voxel.TagCatalog},
      {SceneServer.Voxel.RegionRuntime, name: SceneServer.Voxel.RegionRuntime},
      # 梯队2 step2.6(NIF-1/5):节点级场仿真调度器,统一 clock + CPU 预算驱动所有 FieldTickWorker。
      # 必须在 FieldTickSupervisor 之前起(worker init 后 subscribe 它,缺失即显式 crash)。
      {SceneServer.Voxel.Field.SimRuntime, name: SceneServer.Voxel.Field.SimRuntime},
      # 梯队3 step3.8(RULE-11/AUTH-11):派生→权威唯一提交桥(candidate_effect 阈值锁存 + 幂等)。
      # 必须在 FieldTickSupervisor 之前起(FieldTickWorker 的 field effect 提交它)。
      {SceneServer.Voxel.Field.SystemActor, name: SceneServer.Voxel.Field.SystemActor},
      # Phase 6: per-region field worker DynamicSupervisor must come up
      # before ChunkDirectory / ChunkProcess can spawn field workers.
      {SceneServer.Voxel.Field.FieldTickSupervisor,
       name: SceneServer.Voxel.Field.FieldTickSupervisor},
      {SceneServer.VoxelChunkSup, name: SceneServer.VoxelChunkSup},
      {SceneServer.Voxel.ChunkDirectory, name: SceneServer.Voxel.ChunkDirectory},
      {SceneServer.Voxel.ObjectRegistry, name: SceneServer.Voxel.ObjectRegistry},
      {SceneServer.Voxel.ObjectOwnerLookup, name: SceneServer.Voxel.ObjectOwnerLookup}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
