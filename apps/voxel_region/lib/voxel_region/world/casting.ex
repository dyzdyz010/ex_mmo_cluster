defmodule VoxelRegion.World.Casting do
  @moduledoc """
  全局系统功能：施法：报价、前摇、施放结算、拟态与法术效果。

  由 `VoxelRegion.World` 拆出的状态函数：输入与返回都是 World 状态，真值归属与调用时机仍由 World 决定。
  """
  require Logger
  alias VoxelRegion.Damage
  alias VoxelRegion.Access
  alias VoxelRegion.Magic
  alias VoxelRegion.World.Thermal
  import VoxelRegion.World.Canonical
  alias VoxelRegion.World.{Observation, Log, Tools}

  @hand_reach 0.5

  # 开户一次性充能（整数 mJ）= 50 发法杖光弹的整数扣款。光弹程序（客户端法杖左键发出的普通 v1 施法意图）：
  #   form.semblance{shape 0, radius_m 0.05, mass_kg 0.01, temperature_k 293.15, glow_w 100, lifetime_s 1}
  #   → act.throw{speed_mps 30} → act.break_on_hit{}
  # 目录 71ca543b、环境 293.15 K 下 `Magic.Cost.quote` 总支出 9941.697170433505 J → cost_mj = round(×1000) = 9_941_697；
  # 50 × 9_941_697 = 497_084_850。目录或光弹程序变化时按同一推导重算这里（测试 `MagicStaffBoltTest` 用真实报价复核）。
  @initial_charge_mj 50 * 9_941_697

  @doc "开户一次性充能（整数 mJ），推导见本模块属性注释。"
  def initial_charge_mj, do: @initial_charge_mj

  @doc """
  施法者能量余额（整数 mJ）：`state.caster_energy` 是施法者唯一能量账，值为整数毫焦（守恒量按整数最小单位结算）。
  没有键 = 0（尚未开户；开户见 `open_account/2`）。
  """
  def balance_mj(state, cid) do
    case Map.get(state.caster_energy, cid, 0) do
      mj when is_integer(mj) ->
        mj

      # 迁移兼容：来源 = 整数化之前已持久化的浮点 J 余额（如青岚生产日志与检查点）；原因 = 日志按键合并、不改写历史条目；
      # 规则 = 向零截断到 mJ（与魔法 v2 决策 P8 同一取整）；该键下一次结算即写回整数。
      # 退出条件：S1a A1 把施法者能量迁入 `Pages.character_row` 时一次性换算，届时删除本分支。
      j when is_float(j) ->
        trunc(j * 1000)
    end
  end

  # 报价的整数扣款：总支出（J）× 1000 后按 `round/1`（半数远离零）取整，这个整数就是从施法者账上扣的值。
  defp cost_mj(quote), do: round(quote.total_j * 1000)

  # 走火判定的整数账版本：相干度先判，沿用 `Magic.Cost.misfire/3` 的同一规则（把可用能量取为报价总支出，
  # 能量分支不会触发）；能量在整数 mJ 上比较，可用 < 扣款即 `:misfire_energy`。
  defp misfire(quote, cost_mj, available_mj, catalog) do
    cond do
      Magic.Cost.misfire(quote, quote.total_j, catalog) == :misfire_coherence -> :misfire_coherence
      available_mj < cost_mj -> :misfire_energy
      true -> nil
    end
  end

  @doc """
  开户：已加载魔法目录且施法者账上没有这个 cid 的键时，提交一笔一次性充能事务（余额 = `initial_charge_mj/0`），
  热账源项 `caster_granted_j` 记下这笔凭空注入的能量（与 `caster_drawn_j` 同为施法者能量的来源项）。
  键一经提交就随日志持久化，所以重连与冷重启都不会再充；已有键（含 0 与旧浮点余额）不动。
  只由 `send_caster_state`（玩家 QUIC 接纳与显式状态请求）调用；只读的 `caster_state` 与 NPC 不经过这里。
  提交失败显式返回 `{:error, reason}` 并记日志，状态不变。
  """
  def open_account(%{magic: nil} = state, _cid), do: {:ok, state}

  def open_account(state, cid) do
    if Map.has_key?(state.caster_energy, cid), do: {:ok, state}, else: grant(state, cid)
  end

  defp grant(state, cid) do
    next = %{state | seq: state.seq + 1,
      caster_energy: Map.put(state.caster_energy, cid, @initial_charge_mj),
      thermal: Thermal.ledger(state.thermal, :caster_granted_j, @initial_charge_mj / 1000)}
    txn = %{seq: next.seq, entries: [], coarse: [], caster_energy: %{cid => @initial_charge_mj}, thermal: next.thermal}

    case Log.append_log(state, next, txn, {:character, cid}) do
      :ok ->
        next = Log.remember_entry(next, txn)
        Observation.fanout(next, txn)
        Observation.fanout_canonical(next, txn, [], [], state)
        Logger.info("voxel_caster_grant seq=#{next.seq} cid=#{cid} granted_mj=#{@initial_charge_mj}")
        {:ok, next}

      {:error, reason} ->
        Logger.warning("voxel_caster_grant_failed cid=#{cid} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "前摇到使用／取消之间仍会重新裁决的射程、脚下与驱散释放依赖；不以定时租约或观察窗口替代。"
  def residency_dependencies(%{pending_casts: casts}) when map_size(casts) == 0,
    do: {:ok, {[], [], []}}
  def residency_dependencies(%{magic: nil}), do: {:error, :pending_cast_without_magic_catalog}
  def residency_dependencies(state) do
    {keys, exact, ids} = Enum.reduce(state.pending_casts, {[], [], []}, fn {_cid, pending}, {keys, exact, ids} ->
      {more, precise, identities} = VoxelRegion.World.Closure.needs(state, {:spell_intent, pending.actor, pending.request})
      {fx, fy, fz} = pending.actor.feet
      foot = {floor(fx), floor(fy + 0.5) - 1, floor(fz)}
      foot_keys = VoxelRegion.World.Pages.with_ancestors([{0, region_of(foot)}])
      {keys ++ more ++ foot_keys, exact ++ precise, ids ++ identities}
    end)
    {:ok, {Enum.uniq(keys), Enum.uniq(exact), Enum.uniq(ids)}}
  end

  # ---- 魔法增量 1：施放（Voxim Docs/Magic.md §4、§10）
  # 施法者能量与蓄能石 stored_j 在同一笔事务里原子改变；施法的热只经 thermal.sources 有限热源进世界，
  # 由热内核按守恒结算。校验失败（间隔、射线、施法域、目标、脚下、权限、目标已有热源）不扣能量、不改世界。

  # quote_windup_s（Hello 28）：只有报价回复带完整前摇（含目录出手前置段，与施放计时共用 `Cost.quote`），
  # 登录推送与施放结算后的状态为 0。
  # 账是整数 mJ；线上（0x83）仍是 f64 J，这里是唯一的 mJ → J 换算出口。`spent_mj` 为本次扣款（整数 mJ）。
  def caster_view(state, cid, quote, spent_mj, windup_s) do
    %{seq: state.seq, energy_j: balance_mj(state, cid) / 1000, capacity_j: state.magic.capacity_j,
      coherence: coherence(state, cid), quote_j: quote.total_j, quote_s: quote.structure, spent_j: spent_mj / 1000,
      quote_windup_s: windup_s}
  end

  # 身体闭环 H2（Magic.md §4.4）：施法者相干度 = 目录相干度 × 相干度系数（神经 × 疼痛 × 恍惚，Scene 身体推导、每秒报来）；
  # 报价回复与走火判定共用。
  def coherence(state, cid) do
    {_identity, factor} = Map.get(state.caster_coherence, cid, {nil, 1.0})
    state.magic.coherence * factor
  end

  @doc "全局系统功能：World 的无请求状态出口；登录及身体推送都保留接纳它的连接/会话身份。"
  def publish_caster_state({gate, identity}, request_id, caster) do
    {:ok, bytes} = MmoContracts.Voxel.Codec.encode({:voxel_caster_state, Map.put(caster, :request_id, request_id)})
    send(gate, {:mmo_voxel_bytes, identity, IO.iodata_to_binary(bytes)})
    :ok
  end

  @doc "全局系统功能：成功报价/施放按 World 顺序交给连接编码，施法状态先于对应成功回执；拒绝仍由调用方返回。"
  def publish_cast_reply(actor, request, {:ok, reply}) do
    {gate, ref} = actor.caster_recipient
    send(gate, {:mmo_spell_reply, ref, request, reply})
    :ok
  end
  def publish_cast_reply(_actor, _request, {:error, _}), do: :ok

  # 拟态只能比环境热（吸热 / 制冷待世界书提案）；低于环境温度的程序与其他非法程序同为 invalid_program。
  def warm_semblance(%{steps: [%{sym: "form.semblance", args: %{"temperature_k" => t}} | _]}, ambient) when t < ambient,
    do: {:error, :invalid_program}

  def warm_semblance(_program, _ambient), do: :ok

  # 施放前摇（§13.6）：立即校验（间隔、目标、施法域、脚下、权限）失败即刻拒绝；通过后不结算，记一条待施放并广播
  # 施放记录并通知 Player；Player 持有前摇 timer，到期携当前 actor_context 授权，World 再裁决与结算。前摇中再施放 = cast_too_soon。
  def prepare_spell(state, from, actor, request) do
    with true <- state.magic != nil and state.magic.digest == request.catalog_digest,
         {:ok, program} <- Magic.Program.parse(request.program, state.magic),
         :ok <- warm_semblance(program, state.thermal.config["ambient_kelvin"]) do
      quote = Magic.Cost.quote(program, state.magic, state.thermal.config["ambient_kelvin"]) |> basic_windup(state, program)

      if request.action == 0,
        do: {:reply, {:ok, %{seq: state.seq, outcome: nil, caster: caster_view(state, actor.cid, quote, 0, quote.windup_s)}}, state},
        else: cast_spell(state, from, actor, request, program, quote)
    else
      false -> {:reply, {:error, :stale_magic_catalog}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @doc """
  持物普攻法术的固定前摇（Voxim 交互设计"2026-11-20 修订"，用户 2026-11-20 定）：程序与已发布属性目录某持物的
  `basic_spell` 按魔法目录解析后相等，前摇即取该持物的作者值 `basic_windup_s`；其余程序照常用成本模型前摇。
  判定只看程序本身（服务端不知道玩家拿着什么），所以同一程序从技能栏施放也是这个前摇——这是程序的规则，不是装备规则。
  成本（总支出、扣款、走火）不变。广播的各步 `{调整 s, 注能 s}` 按同一比例缩放，使 Σ(调整 + 注能) + release_lead_s
  等于该前摇：客户端由施放记录推算施法进度与姿态，必须与服务端计时一致。作者前摇须 ≥ 魔法目录 release_lead_s。
  """
  def basic_windup(quote, %{properties: nil}, _program), do: quote

  def basic_windup(quote, state, program) do
    case Enum.find(state.properties.basic_windups, fn {spell, _} -> Magic.Program.validate(spell, state.magic) == {:ok, program} end) do
      nil ->
        quote

      {_, windup_s} ->
        k = (windup_s - state.magic.release_lead_s) / Enum.sum(for {a, i} <- quote.steps, do: a + i)
        %{quote | windup_s: windup_s, steps: for({a, i} <- quote.steps, do: {a * k, i * k})}
    end
  end

  def cast_spell(state, from, actor, request, program, quote) do
    with false <- Map.has_key?(state.pending_casts, actor.cid),
         {:ok, _checked, _state} <- check_cast(state, actor, request, program) do
      begin_cast(state, from, actor, request, program, quote)
    else
      true -> {:reply, {:error, :cast_too_soon}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def check_cast(state, actor, request, program) do
    previous = Map.get(state.spell_sessions, actor.player)

    with {:ok, session} <- admit_cast(previous, request, actor, state.magic),
         {:ok, effect, state} <- spell_effect(state, actor, request, program),
         {:ok, foot, state} <- foot_target(state, actor),
         :ok <- spell_subject(state, effect),
         # 施法的作用格不全是本笔写集（拟态之后才作为物理对象落地），提交入口查不到，所以在意图处按作用格判定。
         :ok <- Access.authorize_cells({:character, actor.cid}, state.protection, effect.cells ++ [Damage.macro(foot)], :character_intent) do
      {:ok, %{session: session, previous: previous, effect: effect, foot: foot}, state}
    else
      {:error, reason} -> {:error, reason}
      {:error, reason, _} -> {:error, reason}
    end
  end

  # 施放记录：t0 = World 墙钟（与拟态 t0_us 同源），出发点 = 手边（与投掷拟态同一来源），程序字节原样。
  def begin_cast(state, from, actor, request, program, quote) do
    {dx, dy, dz} = request.direction
    {ex, ey, ez} = actor.eye

    record = %{live: 1, t0_us: System.system_time(:microsecond), steps: quote.steps, program: request.program,
      origin: {ex + dx * @hand_reach, ey + dy * @hand_reach, ez + dz * @hand_reach}}

    case commit_casts(state, {:character, actor.cid}, %{actor.cid => record}) do
      {:ok, next} ->
        monitor = Process.monitor(actor.player)
        send(actor.player, {:cast_prepared, actor.action_key, quote.windup_s})

        Logger.info(
          "voxel_cast_begin seq=#{next.seq} cid=#{actor.cid} request_id=#{request.request_id} t0_us=#{record.t0_us} " <>
            "windup_s=#{quote.windup_s} physical_j=#{quote.physical_j} loss_j=#{quote.loss_j} steps=#{inspect(quote.steps)}"
        )

        pending = %{record: record, from: from, actor: actor, request: request, program: program, quote: quote, monitor: monitor}
        {:noreply, %{next | pending_casts: Map.put(next.pending_casts, actor.cid, pending)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @doc "授权所指的仍在前摇的待施放：同一动作、同一 Player；已取消 / 已结算的旧授权返回 nil（结算入口与读取闭包共用此判定）。"
  def authorized_pending(state, key, actor) do
    case state.pending_casts[actor.cid] do
      %{actor: %{action_key: ^key, player: player}} = pending when player == actor.player -> pending
      _ -> nil
    end
  end

  # 结算：成功与走火由 settle_spell 提交（事务带 live=0 记录）；此时校验失败（如目标已失效）照常拒绝、不扣能，
  # 另提交一笔只带 live=0 / outcome 2 的事务。
  def cancel_pending_cast(state, key, reason) do
    case Enum.find(state.pending_casts, fn {_, pending} -> pending.actor.action_key == key end) do
      nil -> state
      {cid, pending} ->
        Process.demonitor(pending.monitor, [:flush])
        {:ok, next} = commit_casts(state, :system, %{cid => %{live: 0, outcome: 2}})
        GenServer.reply(pending.from, {:error, reason})
        %{next | pending_casts: Map.delete(next.pending_casts, cid)}
    end
  end

  def settle_cast(state, pending) do
    case check_cast(state, pending.actor, pending.request, pending.program) do
      {:ok, checked, next} ->
        settle_spell(next, pending.actor, pending.request, checked, pending.quote)

      {:error, reason} ->
        case commit_casts(state, {:character, pending.actor.cid}, %{pending.actor.cid => %{live: 0, outcome: 2}}) do
          {:ok, next} ->
            Logger.info("voxel_cast_rejected seq=#{next.seq} cid=#{pending.actor.cid} request_id=#{pending.request.request_id} reason=#{reason}")
            {{:error, reason}, next}

          {:error, error} ->
            {{:error, error}, state}
        end
    end
  end

  # 只带待施放记录的事务（同只带落体帧的事务）：日志里是空事务，保持 seq 连续；记录只随本次广播。
  def commit_casts(state, principal, casts) do
    next = %{state | seq: state.seq + 1}
    txn = %{seq: next.seq, entries: [], coarse: [], casts: casts}

    with :ok <- Log.append_log(state, next, txn, principal) do
      next = Log.remember_entry(next, txn)
      Observation.fanout(next, txn)
      Observation.fanout_canonical(next, txn, [], [], state)
      {:ok, next}
    end
  end

  # 施法的作用对象与需要地块权限的宏格。加热 / 取能：眼睛射线目标。拟态：自手边成形（可抛出），落点格与接触格。
  # 驱散：线上给出的拟态 id，须存在且当前位置在本地施法域内。
  def spell_effect(state, actor, request, %{steps: [%{sym: sym, args: args}]}) when sym in ["act.heat", "energy.draw"] do
    with {:ok, target, state} <- spell_target(state, actor, request, state.magic),
         do: {:ok, %{sym: sym, args: args, target: target, cells: [Damage.macro(target)]}, state}
  end

  def spell_effect(state, actor, request, %{steps: [%{sym: "act.dispel"}]}) do
    id = Map.get(request, :semblance)

    case Thermal.semblances(state) do
      %{^id => %{impact_delivery: _}} ->
        {:error, :stale_target, state}

      %{^id => s} ->
        {px, py, pz} = position = Magic.Semblance.current(s)
        {ex, ey, ez} = actor.eye

        if (px - ex) ** 2 + (py - ey) ** 2 + (pz - ez) ** 2 > state.magic.local_domain_m ** 2 do
          {:error, :out_of_domain, state}
        else
          {cell, state} = Thermal.release_cell(state, s)
          {:ok, %{sym: "act.dispel", id: id, semblance: s, release: cell, cells: [Magic.Semblance.macro(position)]}, state}
        end

      _ ->
        {:error, :stale_target, state}
    end
  end

  def spell_effect(state, actor, request, %{steps: [%{sym: "form.semblance", args: form} | throw]}) do
    owned = Enum.count(Thermal.semblances(state), fn {_, s} -> s.caster == actor.cid end)
    {dx, dy, dz} = request.direction
    {ex, ey, ez} = actor.eye
    hand = {ex + dx * @hand_reach, ey + dy * @hand_reach, ez + dz * @hand_reach}

    velocity =
      case throw do
        [%{args: %{"speed_mps" => v}} | _] -> {dx * v, dy * v, dz * v}
        [] -> {0.0, 0.0, 0.0}
      end

    if owned >= state.magic.max_semblances do
      {:error, :semblance_limit, state}
    else
      case Magic.Semblance.trace(actor.eye, hand, velocity, form["radius_m"], state.magic.range_m, state, &semblance_cast/4) do
        {:miss, state} ->
          {:error, :out_of_domain, state}

        {{:free, point}, state} ->
          launch = %{origin: point, velocity: velocity, flight_s: 0.0, rest: point, contact: nil}
          {:ok, %{sym: "form.semblance", args: form, launch: launch, cells: [Magic.Semblance.macro(point)]}, state}

        {{:hit, t, rest, target}, state} ->
          node = if target.granularity == 2, do: %{target | granularity: 1}, else: target
          contact = %{target: target, key: VoxelRegion.ThermalGeometry.key(node), cell: Damage.macro(target)}
          launch = %{origin: hand, velocity: velocity, flight_s: t, rest: rest, contact: contact}
          launch = if Enum.any?(throw, &(&1.sym == "act.break_on_hit")), do: Map.put(launch, :break_on_hit, true), else: launch
          {:ok, %{sym: "form.semblance", args: form, launch: launch,
                  cells: Enum.uniq([Magic.Semblance.macro(rest), contact.cell])}, state}
      end
    end
  end

  # 拟态弹道的 canonical 求交：同一 Amanatides-Woo 射线，命中返回目标与进入的微格。
  def semblance_cast(origin, direction, length, state) do
    at = fn micro, s ->
      {target, s} = target_at(micro, s)
      {target && {target, micro}, s}
    end

    case Damage.raycast(origin, direction, length, state, at) do
      {:ok, hit, state} -> {hit, state}
      {:error, :no_target, state} -> {nil, state}
    end
  end

  # 施法间隔与工具同一 GCRA（Gate 入口时钟、一个权威 tick 的相位借用）；过快即 cast_too_soon。
  def admit_cast(previous, request, actor, magic) do
    case Damage.admit_attack(previous, request.client_intent_seq, actor.received_us, magic.cast_interval_us, actor.tick_us) do
      {:error, :tool_cooldown} -> {:error, :cast_too_soon}
      result -> result
    end
  end

  # 施法者眼睛射线（与工具同一权威射线，射程 range_m）：首个命中必须是请求的目标，且其宏格中心在本地施法域内。
  def spell_target(state, actor, request, magic) do
    case Tools.tool_target(state, actor, request, %{"range_macro" => magic.range_m, "action" => "magic"}) do
      {:error, :no_target, state} ->
        {:error, :out_of_domain, state}

      {:ok, target, state} ->
        {x, y, z} = Damage.macro(target)
        {ex, ey, ez} = actor.eye

        cond do
          not Tools.same_tool_target?(target, request) ->
            {:error, :stale_target, state}

          (x + 0.5 - ex) ** 2 + (y + 0.5 - ey) ** 2 + (z + 0.5 - ez) ** 2 > magic.local_domain_m ** 2 ->
            {:error, :out_of_domain, state}

          true ->
            {:ok, target, state}
        end
    end
  end

  # 动词的作用对象：加热 = 带热容的未细分宏格且尚无热源；取能 = 未细分的蓄能石宏格；拟态与驱散在 spell_effect 已定。
  def spell_subject(state, %{sym: "act.heat", target: target}) do
    cond do
      target.granularity != 0 or not heat_node?(state, target) -> {:error, :invalid_target}
      Map.has_key?(state.thermal.sources, Damage.macro(target)) -> {:error, :heat_source_busy}
      true -> :ok
    end
  end

  def spell_subject(state, %{sym: "energy.draw", target: target}) do
    if target.granularity == 0 and VoxelRegion.Circuit.battery?(state.properties.materials[target.material]),
      do: :ok,
      else: {:error, :invalid_target}
  end

  def spell_subject(_state, _effect), do: :ok

  # 施法者账是整数 mJ（`balance_mj/2`）：扣款 cost_mj = round(总支出 × 1000)，走火判定在整数上比较。
  # 取能的构型损耗从取得的能量里付（可支付 = 余额 + 取得 gained_mj），否则空施法者永远取不了能。
  # 走火：扣 min(cost_mj, 余额) 全部落脚下，不产生其他效果。账：石减少 = caster_drawn_j + draw_loss_j；
  # 施法支出 spent = spell_heat_j + semblance_created_j + cast_waste_j，其中废热 = cost_mj / 1000 − 物理能量，
  # 使每笔施法的施法者扣款与热账入账相等（物理部分仍是连续物理状态，用浮点 J）。
  # 拟态：新记录 id = {本事务 seq, 0}，物理能量记 semblance_created_j；驱散：剩余能量记 semblance_released_j
  # 并作为有限热源落入接触宏格（或散入空气），已发生的燃烧与热不撤销。
  def settle_spell(before, actor, request, %{session: session, previous: previous, effect: effect, foot: foot}, quote) do
    magic = before.magic
    cid = actor.cid
    seq = before.seq + 1
    balance = balance_mj(before, cid)
    cost = cost_mj(quote)
    stone = if effect.sym == "energy.draw", do: property_state(before, effect.target)

    draw =
      stone &&
        Magic.Cost.draw(round(effect.args["energy_j"] * 1000), trunc(Map.get(stone, :stored_j, 0.0) * 1000), balance, magic)

    available = if draw, do: balance + draw.gained_mj, else: balance
    outcome = misfire(quote, cost, available, %{magic | coherence: magic.coherence * actor.coherence_factor})
    waste = cost / 1000 - quote.physical_j
    thermal = %{before.thermal | active: true}

    {spent, left, rows, thermal} =
      case {outcome, effect} do
        {nil, %{sym: "act.heat", target: target, args: args}} ->
          source = %{target: target, power_w: args["power_w"], remaining_j: args["energy_j"]}
          thermal = %{thermal | sources: Map.put(thermal.sources, Damage.macro(target), source)}

          {cost, balance - cost, [],
           thermal |> Thermal.ledger(:spell_heat_j, args["energy_j"]) |> cast_waste(foot, waste)}

        {nil, %{sym: "energy.draw", target: target}} ->
          row = Map.put(stone, :stored_j, Map.get(stone, :stored_j, 0.0) - draw.taken_mj / 1000)

          thermal =
            thermal
            |> Thermal.deposit_heat(target, draw.loss_mj / 1000)
            |> Thermal.ledger(:caster_drawn_j, draw.gained_mj / 1000)
            |> Thermal.ledger(:draw_loss_j, draw.loss_mj / 1000)
            |> cast_waste(foot, waste)

          {cost, available - cost, [row], thermal}

        {nil, %{sym: "form.semblance", args: form, launch: launch}} ->
          launch =
            if Map.get(launch, :break_on_hit, false) and Map.has_key?(actor, :life_generation) and before.projectile_backend do
              origin = if launch.flight_s == 0.0, do: launch.rest, else: launch.origin
              %{launch | origin: origin, flight_s: form["lifetime_s"], contact: nil,
                rest: Magic.Semblance.position(origin, launch.velocity, form["lifetime_s"])}
              |> Map.put(:projectile_source, Map.take(actor, [:cid, :identity, :life_generation, :position]))
            else
              launch
            end
          s = Magic.Semblance.new(cid, form, magic, Map.put(launch, :t0_us, System.system_time(:microsecond)))

          thermal =
            thermal
            |> Map.update(:semblances, %{{seq, 0} => s}, &Map.put(&1, {seq, 0}, s))
            |> Thermal.ledger(:semblance_created_j, quote.physical_j)
            |> cast_waste(foot, waste)

          {cost, balance - cost, [], thermal}

        {nil, %{sym: "act.dispel", id: id, semblance: s, release: cell}} ->
          thermal =
            thermal
            |> Thermal.release(id, s, cell)
            |> cast_waste(foot, waste)

          {cost, balance - cost, [], thermal}

        _misfire ->
          spent = min(cost, balance)
          {spent, balance - spent, [], cast_waste(thermal, foot, spent / 1000)}
      end

    rows = Enum.map(rows, &%{&1 | seq: seq, request_id: 0})

    next = %{
      before
      | seq: seq,
        thermal: thermal,
        caster_energy: Map.put(before.caster_energy, cid, left),
        spell_sessions: Map.put(before.spell_sessions, actor.player, session),
        damage: Enum.reduce(rows, before.damage, &Map.put(&2, Damage.key(&1), &1))
    }

    txn =
      %{seq: seq, entries: [], coarse: [], property_states: rows, thermal: thermal, caster_energy: %{cid => left},
        casts: %{cid => %{live: 0, outcome: if(outcome, do: 1, else: 0)}}}
      |> Map.merge(Thermal.semblance_txn(Thermal.semblances(before), next))

    case Log.append_log(before, next, txn, {:character, cid}) do
      :ok ->
        unless previous, do: Process.monitor(actor.player)
        next = Log.remember_entry(next, txn)
        Observation.fanout(next, txn)
        Observation.fanout_canonical(next, txn, [], [], before)

        Logger.info(
          "voxel_spell seq=#{seq} cid=#{cid} request_id=#{request.request_id} sym=#{effect.sym} outcome=#{outcome || :cast} " <>
            "structure=#{quote.structure} quote_j=#{quote.total_j} loss_j=#{quote.loss_j} windup_s=#{quote.windup_s} " <>
            "spent_mj=#{spent} energy_mj=#{left} spent_j=#{spent / 1000} energy_j=#{left / 1000} " <>
            "cells=#{inspect(effect.cells)} foot=#{inspect(Damage.macro(foot))}"
        )

        {{:ok, %{seq: seq, outcome: outcome, caster: caster_view(next, cid, quote, spent, 0.0)}}, VoxelRegion.World.Projectiles.wake(next)}

      {:error, reason} ->
        {{:error, reason}, before}
    end
  end

  def cast_waste(thermal, foot, energy),
    do: thermal |> Thermal.deposit_heat(foot, energy) |> Thermal.ledger(:cast_waste_j, energy)
end
