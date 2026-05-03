defmodule GateServer.VoxelSmokeLocalInterface do
  @moduledoc """
  Local service lookup shim used only by the non-GUI voxel smoke runner.

  The production `GateServer.Interface` owns service discovery through Beacon.
  The smoke runner deliberately avoids cluster discovery so it can drive the
  real Gate protocol path inside one BEAM node and still keep the same lookup
  contract that connection workers use in production.
  """

  use GenServer

  @doc "Starts the local lookup process under the provided `:name`."
  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       auth_server: Keyword.get(opts, :auth_server),
       scene_server: Keyword.get(opts, :scene_server, node()),
       world_server: Keyword.get(opts, :world_server, node()),
       server_state: :ready,
       smoke?: true
     }}
  end

  @impl true
  def handle_call(:auth_server, _from, state), do: {:reply, state.auth_server, state}

  def handle_call(:scene_server, _from, state), do: {:reply, state.scene_server, state}

  def handle_call(:world_server, _from, state), do: {:reply, state.world_server, state}
end
