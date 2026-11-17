defmodule NpcServer.Application do
  @moduledoc """
  服务器常驻自治行为子系统；权威身体与世界仍属于 Scene / VoxelRegion。

  ## 召回专用的 httpc profile 在这里起停

  召回（选择在等它）与后台 Hindsight 请求（retain / 刷新 / 状态，没人在等）必须分到不同的连接队列，
  否则召回会排进正忙的会话（见 `NpcServer.Life.Hindsight` 的 moduledoc 与召回隔离决策稿 D-1）。
  这个 profile 属于本应用：在监督树之前起（任何 Life 起来之前它就在），应用停止时停。
  起不来就让应用启动失败——没有召回 profile 就不能保证召回不被后台请求挡住，静默降级会让
  选择在不告警的情况下变慢（铁律第 8 条）。
  """

  use Application

  @impl true
  def start(_type, _args) do
    with {:ok, _} <- NpcServer.Life.Hindsight.start_recall_profile() do
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
      Supervisor.start_link(children, strategy: :rest_for_one, name: NpcServer.Supervisor)
    end
  end

  @impl true
  def stop(_state) do
    # 监督树已经停完、没有 Life 在用之后才停 profile。
    NpcServer.Life.Hindsight.stop_recall_profile()
    :ok
  end
end
