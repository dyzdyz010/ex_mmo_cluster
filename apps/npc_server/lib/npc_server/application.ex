defmodule NpcServer.Application do
  @moduledoc """
  服务器常驻自治行为子系统；权威身体与世界仍属于 Scene / VoxelRegion。

  交互召回和后台取材各有独立的 httpc profile（见 `NpcServer.Life.Hindsight` 及召回隔离决策稿 D-1b）。
  本应用在启动监督树前起两池，应用停止时关闭。起池失败会让应用启动失败。
  """

  use Application
  alias NpcServer.Life.Hindsight

  @impl true
  def start(_type, _args) do
    with {:ok, started_profiles} <- Hindsight.start_recall_profiles() do
      children = [
        {Registry, keys: :duplicate, name: NpcServer.Names},
        # 崩溃域：这里是**所有** NPC 的父监督者，缺省强度（3 次 / 5 秒）会让一次全节点级别的抖动
        # （World 或 Session 一起变慢，所有 NPC 同时超时）把整组 NPC 永久带走。所以显式放宽，并且
        # 单个 NPC 的失败先由它自己的会话不变量与重试吸收（见 `NpcServer.Body.claim/1`）。
        {DynamicSupervisor,
         name: NpcServer.BodySupervisor, strategy: :one_for_one, max_restarts: 60, max_seconds: 10},
        NpcServer.Bootstrap
      ]

      # 名字表失效需重建 Body；Body 监督器失效需重新读取持久化登记。
      case Supervisor.start_link(children, strategy: :rest_for_one, name: NpcServer.Supervisor) do
        {:ok, _} = started ->
          started

        error ->
          Hindsight.stop_recall_profiles(started_profiles)
          error
      end
    end
  end

  @impl true
  def stop(_state) do
    # 监督树已经退出，此后没有 Life 使用两池。
    Hindsight.stop_recall_profiles()
    :ok
  end
end
