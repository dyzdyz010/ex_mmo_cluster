defmodule NpcServer.Application do
  @moduledoc """
  服务器常驻自治行为子系统；权威身体与世界仍属于 Scene / VoxelRegion。

  监督树第一位是出站 HTTP（`NpcServer.Http`：交互、后台两条车道的 Finch 实例，见 Finch 决策稿），
  任何 NPC 起来之前它已经在；之后依次是名字表、Body 监督器、花费额度（`NpcServer.SpendBudget`：每天模型花费的 owner，
  NPC 起来之前“后台开还是停”的结论已发布；`init` 校验运行配置，非法即应用起不来）与从持久化登记恢复 NPC 的 `Bootstrap`。
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      NpcServer.Http,
      {Registry, keys: :duplicate, name: NpcServer.Names},
      # 崩溃域：这里是**所有** NPC 的父监督者，缺省强度（3 次 / 5 秒）会让一次全节点级别的抖动
      # （World 或 Session 一起变慢，所有 NPC 同时超时）把整组 NPC 永久带走。所以显式放宽，并且
      # 单个 NPC 的失败先由它自己的会话不变量与重试吸收（见 `NpcServer.Body.claim/1`）。
      {DynamicSupervisor,
       name: NpcServer.BodySupervisor, strategy: :one_for_one, max_restarts: 60, max_seconds: 10},
      NpcServer.SpendBudget,
      NpcServer.Bootstrap
    ]

    # 出站车道排第一只为保证启动顺序：任何 NPC 起来之前它已经在。副作用是它整体重启时其后的 NPC 也会重起。
    # 这只在 Finch 实例超出自己的监督强度时发生（单个池的崩溃在实例内部恢复，到不了这一层）；NPC 不持有 Finch 状态，
    # 这一重起不是必需的，按罕见情况接受，不为它另加一层监督者。名字表失效需重建 Body；Body 监督器失效需重新读取持久化登记。
    # 花费额度排在 Bootstrap 之前同理只为启动顺序。它崩溃重启时 Bootstrap 随之重启、`Registry.start_all/0` 把全部 enabled 的
    # NPC 停掉再起（结果与重启前相同，但每个 Body 都会重起一次，不是无操作）；额度的状态在账本里，重启后从账本恢复。
    Supervisor.start_link(children, strategy: :rest_for_one, name: NpcServer.Supervisor)
  end
end
