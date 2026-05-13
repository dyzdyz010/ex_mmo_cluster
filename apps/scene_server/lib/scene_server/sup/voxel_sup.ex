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
