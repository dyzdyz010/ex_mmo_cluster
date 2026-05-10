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
      {SceneServer.Voxel.RegionRuntime, name: SceneServer.Voxel.RegionRuntime},
      {SceneServer.VoxelChunkSup, name: SceneServer.VoxelChunkSup},
      {SceneServer.Voxel.ChunkDirectory, name: SceneServer.Voxel.ChunkDirectory},
      {SceneServer.Voxel.ObjectRegistry, name: SceneServer.Voxel.ObjectRegistry},
      {SceneServer.Voxel.ObjectOwnerLookup, name: SceneServer.Voxel.ObjectOwnerLookup}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
