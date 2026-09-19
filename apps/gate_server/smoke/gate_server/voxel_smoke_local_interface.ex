defmodule GateServer.VoxelSmokeLocalInterface do
  @moduledoc """
  只测试：旧 voxel smoke 的本机服务查询适配器。

  生产 `GateServer.Interface` 通过 Beacon 发现服务；此适配器只保留相同的查询契约，
  把 smoke 所需服务指向单个 BEAM 节点，不验证集群发现或跨节点路由。
  """

  use GenServer

  @doc "使用指定的 `:name` 启动本机服务查询进程。"
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
