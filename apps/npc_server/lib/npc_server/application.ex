defmodule NpcServer.Application do
  @moduledoc """
  服务器常驻自治行为子系统；权威身体与世界仍属于 Scene / VoxelRegion。

  监督树第一位是出站 HTTP（`NpcServer.Http`：交互、后台两条车道的 Finch 实例，见 Finch 决策稿），
  任何 NPC 起来之前它已经在；之后依次是名字表、Body 监督器、从持久化登记恢复 NPC 的 `Bootstrap`，最后是花费额度
  （`NpcServer.SpendBudget`：每天模型花费的 owner；`init` 校验运行配置，非法即应用起不来）。
  部署设了 Test-only 世界钟偏移（`VOXIM_TEST_WORLD_CLOCK_OFFSET_S`，见 `MmoContracts.WorldTime`）时，启动先打一行 warning。
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Test-only 世界钟偏移（`config/runtime.exs`）：非 0 时打一行，免得把开着偏移的部署当成正常部署。
    case Application.fetch_env!(:npc_server, :world_clock_test_offset_us) do
      0 ->
        :ok

      offset_us ->
        Logger.warning(
          "world_clock_test_offset Test-only offset_s=#{div(offset_us, 1_000_000)} " <>
            "（NPC 观察的游戏时间 = 墙钟 + 偏移，客户端昼夜不跟着偏移；生产不得设置 VOXIM_TEST_WORLD_CLOCK_OFFSET_S）"
        )
    end

    children = [
      NpcServer.Http,
      {Registry, keys: :duplicate, name: NpcServer.Names},
      # 崩溃域：这里是**所有** NPC 的父监督者，缺省强度（3 次 / 5 秒）会让一次全节点级别的抖动
      # （World 或 Session 一起变慢，所有 NPC 同时超时）把整组 NPC 永久带走。所以显式放宽，并且
      # 单个 NPC 的失败先由它自己的会话不变量与重试吸收（见 `NpcServer.Body.claim/1`）。
      {DynamicSupervisor,
       name: NpcServer.BodySupervisor, strategy: :one_for_one, max_restarts: 60, max_seconds: 10},
      NpcServer.Bootstrap,
      NpcServer.SpendBudget
    ]

    # 出站车道排第一只为保证启动顺序：任何 NPC 起来之前它已经在。副作用是它整体重启时其后的 NPC 也会重起。
    # 这只在 Finch 实例超出自己的监督强度时发生（单个池的崩溃在实例内部恢复，到不了这一层）；NPC 不持有 Finch 状态，
    # 这一重起不是必需的，按罕见情况接受，不为它另加一层监督者。名字表失效需重建 Body；Body 监督器失效需重新读取持久化登记。
    #
    # 花费额度排在最后（`:rest_for_one` 下没有排在它后面的子进程）：它崩溃重启只重启它自己，不带起任何 NPC。NPC 不需要它先在——
    # Life 只在后台触发处读 `SpendBudget.background/0`，owner 还没发布结论（启动期间、崩溃后正在重启）时那里给“无法计量”，
    # 后台先停着，等它发布后自然恢复。账本读写失败在它内部转成“无法计量”而不是崩溃（见 SpendBudget moduledoc“故障与监督”），
    # 所以它不会因为数据库抖动反复重启、耗尽本监督树的重启强度把整个 NPC 应用带走。
    Supervisor.start_link(children, strategy: :rest_for_one, name: NpcServer.Supervisor)
  end
end
