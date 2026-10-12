defmodule NpcServer.Application do
  @moduledoc "服务器常驻自治行为子系统；权威身体与世界仍属于 Scene / VoxelRegion。"
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :duplicate, name: NpcServer.Names},
      {DynamicSupervisor, name: NpcServer.BodySupervisor, strategy: :one_for_one},
      NpcServer.Bootstrap
    ]

    # 名字表失效需重建 Body；Body 监督器失效需重新读取持久化登记。
    Supervisor.start_link(children, strategy: :rest_for_one, name: NpcServer.Supervisor)
  end
end
