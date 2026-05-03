defmodule SceneServer.VoxelChunkSup do
  @moduledoc """
  Dynamic supervisor for hot voxel chunk processes.
  """

  use DynamicSupervisor

  @doc "Starts the dynamic chunk supervisor."
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, [], opts)
  end

  @doc "Starts one `SceneServer.Voxel.ChunkProcess` child."
  def start_chunk(supervisor \\ __MODULE__, opts) do
    DynamicSupervisor.start_child(supervisor, {SceneServer.Voxel.ChunkProcess, opts})
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
