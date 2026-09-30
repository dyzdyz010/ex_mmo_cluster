defmodule WorldServer.Application do
  @moduledoc false

  use Application

  # 路由与跨 Scene 编排是纯函数（`WorldServer.Movement`）；配置了拓扑文件时由 `WorldServer.Topology` 启动全部 Scene。
  @impl true
  def start(_type, _args) do
    children =
      case Application.get_env(:world_server, :topology) do
        nil -> []
        path -> [{WorldServer.Topology, path}]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: WorldServer.Supervisor)
  end
end
