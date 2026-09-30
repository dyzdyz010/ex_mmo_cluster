defmodule SceneServer.Application do
  @moduledoc """
  Boots the scene-side authority runtime: the M3 public timeline
  (`SceneServer.Movement.Scene`) with its Player DynamicSupervisor and Replication owner.

  Voxim 是唯一客户端：只有配置了 M1 Scene（`VOXIM_M1_CONFIG`）时才启动；未配置时（测试构建）由用例自己启动。
  See `apps/scene_server/lib/scene_server/README.md`.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      case Application.get_env(:scene_server, SceneServer.Movement.Scene) do
        nil -> []
        config -> [{SceneServer.Movement.Scene, config}]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: SceneServer.Supervisor)
  end
end
