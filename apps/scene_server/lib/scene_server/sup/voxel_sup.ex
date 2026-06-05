defmodule SceneServer.VoxelSup do
  @moduledoc """
  Supervisor for scene-side voxel runtime processes.

  The voxel subtree owns hot lease state, boundary-event validation, and the
  directory/dynamic supervisor used for per-chunk hot truth processes.

  ## 进程身份注册化（阶段3.1）

  每个 `SceneServer.Voxel.ChunkProcess` 的进程身份（"谁是 `{logical_scene_id,
  chunk_coord}` 的权威"）由 `SceneServer.Voxel.ChunkRegistry`（`Registry`
  `:unique`）裁决。这是同节点单主的唯一真相源：

  * `ChunkProcess` 用 via-tuple 注册进 child_spec 的 `start` 参数，监督树重启
    天然去重（同 key 不会起第二个权威进程）。
  * `ChunkDirectory` 退化为**无状态 facade**：不再持有进程表，所有
    lookup/路由都经 `ChunkRegistry` 解析。
  * 跨节点单主由 World lease/epoch 栅栏裁决；注册表只负责同节点去重。

  子进程顺序要求：`ChunkRegistry` 必须早于 `VoxelChunkSup` /
  `ChunkDirectory` 启动，否则 chunk 的 via-tuple 注册会落空。
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
      # Phase 6: per-region field worker DynamicSupervisor must come up
      # before ChunkDirectory / ChunkProcess can spawn field workers.
      {SceneServer.Voxel.Field.FieldTickSupervisor,
       name: SceneServer.Voxel.Field.FieldTickSupervisor},
      # 阶段3.1：chunk 进程身份注册表。必须早于 VoxelChunkSup / ChunkDirectory，
      # 以便 ChunkProcess 在 start_link 时即可经 via-tuple 注册去重。
      {Registry, keys: :unique, name: SceneServer.Voxel.ChunkRegistry},
      {SceneServer.VoxelChunkSup, name: SceneServer.VoxelChunkSup},
      {SceneServer.Voxel.ChunkDirectory, name: SceneServer.Voxel.ChunkDirectory},
      {SceneServer.Voxel.ObjectRegistry, name: SceneServer.Voxel.ObjectRegistry},
      {SceneServer.Voxel.ObjectOwnerLookup, name: SceneServer.Voxel.ObjectOwnerLookup}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
