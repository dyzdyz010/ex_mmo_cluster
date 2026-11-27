defmodule VoxelRegion.World.MagicAdmission do
  @moduledoc """
  全局系统功能（魔法 v2 切片 7）：分区魔法容量的唯一 owner——施放准入（每施法者上限、分区预算、NPC 配额、飞行名额）、
  施法者在场集合、每拍触发预算与热节点休眠规则。`World.Structures` 只取读数并执行本模块的结论。

  决策稿 `docs/10-active/magic/2026-11-26-p1-closure-slices4-8.md` §7、§10（75% 准入、分池对照）、§11.1 Q7-1/Q7-2；
  落地稿 `2026-11-19-glyph-v2-server-landing.md` D8；设计 TheWorldBook `docs/2026-11-19-glyph-composition-game-design.md`
  §5.6（公平上限与结算预算）、§5.7（施法者离线）、§12.1 D12（单 World 阶段：每分区即每 World）。

  ## 用量从真值推导，不另存计数（AGENTS §2.2-3）

  每次判定都从 `thermal.structures`（运行中结构，含冻结期与冻结交付中的，设计 §5.6、§5.8）现算用量，World 里没有第二份
  计数。结构权重（目录 `quotas`）：

      w = structure_weight_base + structure_weight_awake_thermal_node·[醒着的热节点]
          + structure_weight_per_rule·规则数 + structure_weight_per_sensing_coupling·感知耦合数

  - **感知耦合数在 P1 恒为 0**（Q7-6；已定：实现决策，见决策稿 §11.3 #21）：〈遇〉〈时〉〈满〉只按规则计入。
  - “醒着的热节点”：带〈热〉（C_th 非空）且不在休眠的结构。飞行中的热结构也算醒着：它落地即成为热内核节点，飞行中
    不参与休眠判定（设计 §5.3 C1-15 跳过第 11 步），按将要占用的算力计。休眠由 `World.Structures` 每拍判定
    （设计 §5.3 第 11 步，切片 7-3）；本模块只读结果。
  - 待施放的候选按程序计：带〈热〉即按醒着计（新结构出生即醒），带〈投〉即为飞行。

  ## 准入规则（每次前摇开始、第 k 步检查与出手各判一次，`World.Casting.check_cast/4` 调用）

  按下列顺序取第一个不成立的，拒绝原因走 0x68 字符串（Gate 原样 `inspect`）：

  | 维度 | 规则 | 拒绝 |
  |---|---|---|
  | 每施法者结构 | 玩家 < `structures_per_caster`（6）；NPC < `structures_per_npc`（4） | `:structure_quota` |
  | 每施法者飞行 | 飞行中 < `flights_per_caster`（3，Q7-5） | `:flight_quota` |
  | 醒着的热节点 | 带〈热〉的候选：醒着的热节点 < `awake_thermal_nodes_per_region`（16）（Q7-3） | `:region_budget` |
  | 分区飞行名额 | 共 `region_flight_slots_base` + 在场人数 × `region_flight_slots_per_present`；在场者飞行数低于保底时用自己的保底名额，否则用共享部分（= base，先到先得，Q7-4），NPC 只用共享部分 | `:region_budget` |
  | 分区预算 | 见下 | `:region_budget` |

  分区预算（B = `region_budget_units`，R = `region_reserve_units`，U 为当前用量、w 为候选权重）：

  1. U + w > B + R：一律拒绝（硬上限）。
  2. NPC（设计 §5.6 C1-16、D8）：NPC 合计用量 + w ≤ `npc_budget_ratio`·B 且 U + w ≤ B；不看在场、不享有保底与预留。
  3. 玩家，U < `fair_share_ratio`·B：U + w ≤ B 即准入。
  4. 玩家，在场且名下结构数 < `present_floor_structures`（1）：保底准入，可用到预留（U + w ≤ B + R）。
  5. 玩家，U ≥ 75%·B：在场且本人用量 < 0.75·B / 在场人数，并且 U + w ≤ B。
  6. 其余拒绝。不在场的玩家在拥挤时没有准入资格（第 5 条要求在场），他的结构照常运行并计入用量（设计 §5.6、§5.7）。

  依据（决策稿 §10）：单一资源下 DRF 退化为 max-min 公平；“空闲时弹性超用、竞争时每用户保底份额”对照 YARN Capacity
  Scheduler 的 `minimum-user-limit-percent`。阈值 75% 与 32 单位预留是原创决策。

  ## 施法者身份（Q7-1、Q7-2）

  - `controller`（`:player | :npc`）随施法快照进来：Player 按 Scene 入场时由入口声明的角色 kind（Gate 传鉴权角色行、
    NPC Body 传 "npc"，`Scene.join` 一处映射）给出，客户端不能自报。结构建成时存进物理体，NPC 合计按它数。
  - 在场集合 `state.magic_presence`（cid => %{pid, monitor}）只由 Scene 推送（`World.caster_presence/3`：Player 会话就绪
    `:present`、会话解除 `:absent`），World 不向 Scene 拉取（设计 §5.6）。只有玩家 Player 推送，NPC 不计入在场。
  - 自维护（AGENTS §2.1-2）：World 监视推送在场的 Player 进程，进程退出即移出；`:absent` 与进程退出只移除同一 pid
    登记的条目，所以跨 Scene 移交时新旧 Player 的推送先后不影响结果。在场集合是派生状态，不持久化：World 重启后由
    仍在会话中的 Player 在下次会话就绪时重新推送；在此之前拥挤准入按不在场处理（偏保守的显式失败，不放宽）。

  ## 触发预算（设计 §5.4）

  每分区每拍 `triggers_per_region_tick`（64）、每施法者每拍 `triggers_per_caster_tick`（8）个触发响应。超出的推迟：推迟项
  `%{since, rule, outcome, contact}` 存在结构条目的 `deferred` 里（随 `thermal.structures` 持久化，同一规则至多一项），拍首
  按（首次推迟拍号, id）预占预算，再按 id 升序步进时执行。本拍新触发按结构 id 升序、结构内按优先级取预算（与设计“同拍按
  （优先级, id）”的差别见决策稿 §14 切片 7）。投射物提交点上〈遇〉触发的〈散〉是事件驱动的，不计入每拍预算。

  ## 热节点休眠（设计 §5.3 第 11 步、§5.3.2）

  已落地的热结构每拍末判“平静”（`calm?/4`）；连续 `sleep_after/0`（2）拍平静即休眠（Q7-W2 1 拍滞回），休眠中不作为热内核
  外部节点（不参与换热，误差上界见设计 §5.3.2），也不计入醒着的热节点（准入权重少 2、不占 16 个上限）。每次组装内核节点时
  按当前温度复核（`wakes?/3`），任一接触节点温差 ≥ 5 K 即在本次调用重新加入；拍末不平静即连续计数归零。

  ## 可观测面

  - 每次判定一行 `voxel_magic_admission cid controller decision reason usage_units budget reserve present own_units
    own_structures npc_units flights own_flights flight_slots awake_nodes candidate_units`（决策稿 §7.2）。
  - 在场变化一行 `voxel_magic_presence cid pid status present`。
  - 每拍有触发或推迟时一行 `voxel_structure_triggers tick fired deferred oldest_deferred_tick region_left`；有休眠变化或休眠中的
    结构时一行 `voxel_structure_sleep tick asleep woke slept`（`World.Structures`）。
  - `World.stats/1` 的 `magic_admission`（`observe/1`）：当前用量、预算、在场集合、NPC 合计、飞行与醒着的热节点数。
  """
  require Logger
  alias VoxelRegion.Magic.{Catalog, Program}
  alias VoxelRegion.Magic.Program.Group

  @controllers [:player, :npc]
  # 热节点休眠的滞回（Q7-W2；已定：实现决策，见决策稿 §11.3 #22）：连续 2 拍满足平静条件才休眠，即比设计 §5.3.2 多等 1 拍。
  # 对照 Box2D `b2_timeToSleep`、PhysX 唤醒计数器（决策稿 §10）：都要求持续低于阈值一段时间，避免边界附近逐拍来回切换。
  @sleep_after 2

  @doc "施法快照的 `controller` 取值。"
  def controllers, do: @controllers

  # ---------------------------------------------------------------------------
  # 在场集合（Scene 推送，World 不拉取）
  # ---------------------------------------------------------------------------

  @doc """
  Player 推送的在场变化（`World.caster_presence/3` 投递）。`:present` 登记 `pid` 并监视它（同一 cid 换了 pid 时取代旧登记）；
  `:absent` 只移除该 pid 自己的登记。
  """
  def presence(state, cid, pid, :present) do
    presence = state.magic_presence

    presence =
      case Map.get(presence, cid) do
        %{pid: ^pid} ->
          presence

        previous ->
          if previous, do: Process.demonitor(previous.monitor, [:flush])
          Map.put(presence, cid, %{pid: pid, monitor: Process.monitor(pid)})
      end

    log_presence(%{state | magic_presence: presence}, cid, pid, :present)
  end

  def presence(state, cid, pid, :absent) do
    case Map.get(state.magic_presence, cid) do
      %{pid: ^pid, monitor: monitor} ->
        Process.demonitor(monitor, [:flush])
        log_presence(%{state | magic_presence: Map.delete(state.magic_presence, cid)}, cid, pid, :absent)

      _ ->
        state
    end
  end

  @doc "被监视的 Player 进程退出：移除它登记的在场（World 的通用 `:DOWN` 分支调用）。"
  def down(state, pid) do
    state.magic_presence
    |> Enum.filter(fn {_, p} -> p.pid == pid end)
    |> Enum.reduce(state, fn {cid, _}, state ->
      log_presence(%{state | magic_presence: Map.delete(state.magic_presence, cid)}, cid, pid, :down)
    end)
  end

  defp log_presence(state, cid, pid, status) do
    Logger.info("voxel_magic_presence cid=#{cid} pid=#{inspect(pid)} status=#{status} present=#{map_size(state.magic_presence)}")
    state
  end

  @doc "在场的玩家施法者 cid（升序）。"
  def present(state), do: state.magic_presence |> Map.keys() |> Enum.sort()

  # ---------------------------------------------------------------------------
  # 用量（从 thermal.structures 现算）
  # ---------------------------------------------------------------------------

  @doc """
  当前分区用量：`units` 全部结构权重和、`npc_units` NPC 名下权重和、`flights` 飞行中结构数、`awake_nodes` 醒着的热节点数，
  `casters` 为 cid => %{units, structures, flights}。
  """
  def usage(state) do
    quotas = state.magic.quotas
    zero = %{units: 0.0, npc_units: 0.0, flights: 0, awake_nodes: 0, casters: %{}}

    Enum.reduce(VoxelRegion.World.Structures.all(state), zero, fn {_, entry}, u ->
      body = entry.body
      awake = awake_thermal?(entry)
      units = weight(quotas, awake, length(entry.structure.rules))
      flight = if body.flight != nil, do: 1, else: 0
      mine = Map.get(u.casters, body.caster, %{units: 0.0, structures: 0, flights: 0})

      %{
        u
        | units: u.units + units,
          npc_units: u.npc_units + if(body.controller == :npc, do: units, else: 0.0),
          flights: u.flights + flight,
          awake_nodes: u.awake_nodes + if(awake, do: 1, else: 0),
          casters:
            Map.put(u.casters, body.caster, %{
              units: mine.units + units,
              structures: mine.structures + 1,
              flights: mine.flights + flight
            })
      }
    end)
  end

  @doc "醒着的热节点（见 moduledoc）：带〈热〉、不在休眠。"
  def awake_thermal?(%{structure: s} = entry), do: s.c_th_j_per_k != nil and not asleep?(entry)

  @doc "结构此刻是否休眠：连续平静拍数（条目 `calm`，`World.Structures` 每拍写入）达到 `sleep_after/0`。"
  def asleep?(entry), do: Map.get(entry, :calm, 0) >= @sleep_after

  defp weight(quotas, awake, rules),
    do:
      quotas.structure_weight_base + quotas.structure_weight_awake_thermal_node * if(awake, do: 1, else: 0) +
        quotas.structure_weight_per_rule * rules

  # 候选（待施放程序）的权重与类别：P1 一次施放一个组（决策稿 §3.1 `id_n` 恒为 0）。
  defp candidate(%Group{} = group, quotas) do
    thermal = Enum.any?(group.quality, &(&1.id == "cpl.thermal"))
    flight = Enum.any?(group.motion, &(&1.id == "act.throw"))
    %{units: weight(quotas, thermal, length(group.rules)), thermal: thermal, flight: flight}
  end

  # ---------------------------------------------------------------------------
  # 准入
  # ---------------------------------------------------------------------------

  @doc """
  施放准入：`:ok` 或 `{:error, :structure_quota | :flight_quota | :region_budget}`（规则见 moduledoc）。
  施法者动作（〈取〉）不建结构，直接 `:ok`。`actor.controller` 必须是 `:player` 或 `:npc`。
  """
  def admit(_state, _actor, %Program{kind: :caster_action}), do: :ok

  def admit(%{magic: %Catalog{quotas: quotas}} = state, %{cid: cid, controller: controller}, %Program{
        kind: :structure,
        groups: [group]
      })
      when controller in @controllers do
    usage = usage(state)
    candidate = candidate(group, quotas)
    present = present(state)
    mine = Map.get(usage.casters, cid, %{units: 0.0, structures: 0, flights: 0})
    facts = %{cid: cid, controller: controller, present: present, mine: mine, usage: usage, candidate: candidate}

    decision =
      with :ok <- structures(facts, quotas),
           :ok <- flights(facts, quotas),
           :ok <- awake_nodes(facts, quotas),
           :ok <- flight_slots(facts, quotas) do
        region(facts, quotas)
      end

    log(facts, quotas, decision)
    decision
  end

  defp structures(%{controller: :player, mine: mine}, q), do: below(mine.structures, q.structures_per_caster, :structure_quota)
  defp structures(%{controller: :npc, mine: mine}, q), do: below(mine.structures, q.structures_per_npc, :structure_quota)

  defp flights(%{candidate: %{flight: false}}, _q), do: :ok
  defp flights(%{mine: mine}, q), do: below(mine.flights, q.flights_per_caster, :flight_quota)

  # Q7-3（手感项，8b 实跑请用户确认，见决策稿 §11.3 #31）：醒着的热节点已达上限时拒绝新的热结构，不强制最早的休眠。
  defp awake_nodes(%{candidate: %{thermal: false}}, _q), do: :ok
  defp awake_nodes(%{usage: usage}, q), do: below(usage.awake_nodes, q.awake_thermal_nodes_per_region, :region_budget)

  # 分区飞行名额（设计 §5.6）：共 base + 在场人数 × per_present。在场玩家各有 per_present 个保底名额；其余（= base）是
  # 共享部分。Q7-4（手感项，8b 实跑请用户确认，见决策稿 §11.3 #32）：设计写的“按施法者轮转分配、不按先到先得”在即时准入下没有可轮转的
  # 队列，取“保底以外先到先得”；NPC 与不在场者只用共享部分。
  defp flight_slots(%{candidate: %{flight: false}}, _q), do: :ok

  defp flight_slots(%{cid: cid, controller: controller, present: present, mine: mine, usage: usage}, q) do
    guaranteed = q.region_flight_slots_per_present

    if controller == :player and cid in present and mine.flights < guaranteed do
      :ok
    else
      below(shared_flights(usage, present, guaranteed), q.region_flight_slots_base, :region_budget)
    end
  end

  # 共享名额的占用：在场者超出保底的飞行 + 不在场者（含 NPC）的全部飞行。
  defp shared_flights(usage, present, guaranteed) do
    Enum.sum(
      for {cid, %{flights: f}} <- usage.casters,
          do: if(cid in present, do: max(0, f - guaranteed), else: f)
    )
  end

  defp region(%{controller: controller, cid: cid, present: present, mine: mine, usage: usage, candidate: c}, q) do
    budget = q.region_budget_units
    total = usage.units + c.units

    cond do
      total > budget + q.region_reserve_units ->
        {:error, :region_budget}

      controller == :npc ->
        if usage.npc_units + c.units <= q.npc_budget_ratio * budget and total <= budget,
          do: :ok,
          else: {:error, :region_budget}

      usage.units < q.fair_share_ratio * budget and total <= budget ->
        :ok

      cid in present and mine.structures < q.present_floor_structures ->
        :ok

      cid in present and mine.units < q.fair_share_ratio * budget / length(present) and total <= budget ->
        :ok

      true ->
        {:error, :region_budget}
    end
  end

  defp below(value, limit, reason), do: if(value < limit, do: :ok, else: {:error, reason})

  defp log(facts, q, decision) do
    %{cid: cid, controller: controller, present: present, mine: mine, usage: usage, candidate: c} = facts

    {verdict, reason} =
      case decision do
        :ok -> {:admit, :none}
        {:error, reason} -> {:reject, reason}
      end

    Logger.info(
      "voxel_magic_admission cid=#{cid} controller=#{controller} decision=#{verdict} reason=#{reason} " <>
        "usage_units=#{usage.units} budget=#{q.region_budget_units} reserve=#{q.region_reserve_units} present=#{length(present)} " <>
        "own_units=#{mine.units} own_structures=#{mine.structures} npc_units=#{usage.npc_units} flights=#{usage.flights} " <>
        "own_flights=#{mine.flights} flight_slots=#{q.region_flight_slots_base + q.region_flight_slots_per_present * length(present)} " <>
        "awake_nodes=#{usage.awake_nodes} candidate_units=#{c.units} candidate_thermal=#{c.thermal} candidate_flight=#{c.flight}"
    )
  end

  # ---------------------------------------------------------------------------
  # 触发预算（设计 §5.4、§5.6；决策稿 §7.1、§10 对照 Deficit Round Robin）
  # ---------------------------------------------------------------------------

  @doc """
  一拍的触发预算：分区 `triggers_per_region_tick`（64）、每施法者 `triggers_per_caster_tick`（8）。每执行一个触发的响应
  消耗一份；超出的推迟到之后的拍、不丢弃。数值为原创、待实测（设计 C2-1）。
  """
  def trigger_budget(%Catalog{quotas: q}),
    do: %{region: q.triggers_per_region_tick, per_caster: q.triggers_per_caster_tick, used: %{}}

  @doc "为施法者 `caster` 取一份预算：`{:ok, 新预算}` 或 `:exhausted`（分区或本人已用完）。"
  def take_trigger(%{region: region, per_caster: per, used: used} = budget, caster) do
    mine = Map.get(used, caster, 0)
    if region > 0 and mine < per, do: {:ok, %{budget | region: region - 1, used: Map.put(used, caster, mine + 1)}}, else: :exhausted
  end

  @doc "退回一份未执行的预算（预占的推迟项所属结构在本拍先行终止时）。"
  def return_trigger(%{region: region, used: used} = budget, caster),
    do: %{budget | region: region + 1, used: Map.update!(used, caster, &(&1 - 1))}

  @doc """
  拍首为推迟队列预占预算：全部推迟项按（首次推迟拍号, 结构 id）排序（设计 §5.4、§5.8：较早被推迟的先执行，相当于调度里的
  aging，避免低 id 的老结构长期占满名额），依次取预算。`deferred` 为 `[{id, 施法者, 推迟项}]`。返回
  `{id => 已预占的推迟项（按首次推迟拍号）, 预算}`；没取到的推迟项留在队列里。
  """
  def claim_deferred(deferred, budget) do
    deferred
    |> Enum.sort_by(fn {id, _caster, item} -> {item.since, id} end)
    |> Enum.reduce({%{}, budget}, fn {id, caster, item}, {claimed, budget} ->
      case take_trigger(budget, caster) do
        {:ok, budget} -> {Map.update(claimed, id, [item], &(&1 ++ [item])), budget}
        :exhausted -> {claimed, budget}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # 热节点休眠（设计 §5.3 第 11 步、§5.3.2；Q7-W2）
  # ---------------------------------------------------------------------------

  @doc """
  本拍是否平静（设计 §5.3.2）：端口温度与所有接触节点的温差都 < `thermal_sleep_delta_k`（5 K），且本拍净热流的绝对值
  < `thermal_sleep_power_w`（100 W）。没有接触节点时只看净热流。
  """
  def calm?(port_k, contact_k, net_heat_w, %Catalog{runtime: rt}),
    do: abs(net_heat_w) < rt.thermal_sleep_power_w and not wakes?(port_k, contact_k, rt)

  @doc "休眠中的结构是否被唤醒：任一接触节点与端口温差 ≥ 5 K（设计 §5.3.2 “每拍按当前温度复核，越过阈值即唤醒”）。"
  def wakes?(port_k, contact_k, %Catalog{runtime: rt}), do: wakes?(port_k, contact_k, rt)
  def wakes?(port_k, contact_k, rt), do: Enum.any?(contact_k, &(abs(&1 - port_k) >= rt.thermal_sleep_delta_k))

  @doc "下一拍的连续平静拍数：平静则 +1（封顶 `sleep_after/0`），否则归零。"
  def next_calm(previous, true), do: min(previous + 1, @sleep_after)
  def next_calm(_previous, false), do: 0

  @doc "休眠所需的连续平静拍数（Q7-W2：设计的 1 拍加 1 拍滞回）。"
  def sleep_after, do: @sleep_after

  @doc "观察快照（`World.stats/1` 的 `magic_admission`）：用量、上限与在场集合；未加载魔法目录时为 nil。"
  def observe(%{magic: nil}), do: nil

  def observe(%{magic: %Catalog{quotas: q}} = state) do
    usage = usage(state)
    present = present(state)

    %{
      usage_units: usage.units,
      budget_units: q.region_budget_units,
      reserve_units: q.region_reserve_units,
      present: present,
      npc_units: usage.npc_units,
      npc_budget_units: q.npc_budget_ratio * q.region_budget_units,
      flights: usage.flights,
      flight_slots: q.region_flight_slots_base + q.region_flight_slots_per_present * length(present),
      awake_nodes: usage.awake_nodes,
      casters: usage.casters
    }
  end
end
