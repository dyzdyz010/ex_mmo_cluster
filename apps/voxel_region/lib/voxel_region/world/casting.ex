defmodule VoxelRegion.World.Casting do
  @moduledoc """
  全局系统功能：施法：报价、前摇、施放结算、拟态与法术效果。

  由 `VoxelRegion.World` 拆出的状态函数：输入与返回都是 World 状态，真值归属与调用时机仍由 World 决定。
  """
  require Logger
  alias VoxelRegion.Damage
  alias VoxelRegion.Protection
  alias VoxelRegion.Magic
  alias VoxelRegion.World.Thermal
  import VoxelRegion.World.Canonical
  alias VoxelRegion.World.{Observation, Log, Tools}

  @hand_reach 0.5

  # ---- 魔法增量 1：施放（Voxim Docs/Magic.md §4、§10）
  # 施法者能量与蓄能石 stored_j 在同一笔事务里原子改变；施法的热只经 thermal.sources 有限热源进世界，
  # 由热内核按守恒结算。校验失败（间隔、射线、施法域、目标、脚下、权限、目标已有热源）不扣能量、不改世界。

  # quote_windup_s（Hello 28）：只有报价回复带完整前摇（含目录出手前置段，与施放计时共用 `Cost.quote`），
  # 登录推送与施放结算后的状态为 0。
  def caster_view(state, cid, quote, spent, windup_s) do
    %{seq: state.seq, energy_j: Map.get(state.caster_energy, cid, 0.0), capacity_j: state.magic.capacity_j,
      coherence: coherence(state, cid), quote_j: quote.total_j, quote_s: quote.structure, spent_j: spent,
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
  # 施放记录，前摇到期（`{:settle_cast, …}`）再以开始时捕获的施法者与意图重做同一校验并结算。前摇中再施放 = cast_too_soon。
  def prepare_spell(state, from, actor, request) do
    with true <- state.magic != nil and state.magic.digest == request.catalog_digest,
         {:ok, program} <- Magic.Program.parse(request.program, state.magic),
         :ok <- warm_semblance(program, state.thermal.config["ambient_kelvin"]) do
      quote = Magic.Cost.quote(program, state.magic, state.thermal.config["ambient_kelvin"])

      if request.action == 0,
        do: {:reply, {:ok, %{seq: state.seq, outcome: nil, caster: caster_view(state, actor.cid, quote, 0.0, quote.windup_s)}}, state},
        else: cast_spell(state, from, actor, request, program, quote)
    else
      false -> {:reply, {:error, :stale_magic_catalog}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
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
         true <- Protection.permitted?(state.protection, {:character, actor.cid}, effect.cells ++ [Damage.macro(foot)]) do
      {:ok, %{session: session, previous: previous, effect: effect, foot: foot}, state}
    else
      false -> {:error, :protected_region}
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

    case commit_casts(state, %{actor.cid => record}) do
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

  # 结算：成功与走火由 settle_spell 提交（事务带 live=0 记录）；此时校验失败（如目标已失效）照常拒绝、不扣能，
  # 另提交一笔只带 live=0 / outcome 2 的事务。
  def cancel_pending_cast(state, key, reason) do
    case Enum.find(state.pending_casts, fn {_, pending} -> pending.actor.action_key == key end) do
      nil -> state
      {cid, pending} ->
        Process.demonitor(pending.monitor, [:flush])
        {:ok, next} = commit_casts(state, %{cid => %{live: 0, outcome: 2}})
        GenServer.reply(pending.from, {:error, reason})
        %{next | pending_casts: Map.delete(next.pending_casts, cid)}
    end
  end

  def settle_cast(state, pending) do
    case check_cast(state, pending.actor, pending.request, pending.program) do
      {:ok, checked, next} ->
        settle_spell(next, pending.actor, pending.request, checked, pending.quote)

      {:error, reason} ->
        case commit_casts(state, %{pending.actor.cid => %{live: 0, outcome: 2}}) do
          {:ok, next} ->
            Logger.info("voxel_cast_rejected seq=#{next.seq} cid=#{pending.actor.cid} request_id=#{pending.request.request_id} reason=#{reason}")
            {{:error, reason}, next}

          {:error, error} ->
            {{:error, error}, state}
        end
    end
  end

  # 只带待施放记录的事务（同只带落体帧的事务）：日志里是空事务，保持 seq 连续；记录只随本次广播。
  def commit_casts(state, casts) do
    next = %{state | seq: state.seq + 1}
    txn = %{seq: next.seq, entries: [], coarse: [], casts: casts}

    with :ok <- Log.append_log(next, txn) do
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

  # 取能的构型损耗从取得的能量里付（可支付 = 余额 + η·ΔE），否则空施法者永远取不了能。
  # 走火：扣 min(总支出, 余额) 全部落脚下，不产生其他效果。账：石减少 = caster_drawn_j + draw_loss_j；
  # 施法支出 spent = spell_heat_j + semblance_created_j + cast_waste_j。
  # 拟态：新记录 id = {本事务 seq, 0}，物理能量记 semblance_created_j；驱散：剩余能量记 semblance_released_j
  # 并作为有限热源落入接触宏格（或散入空气），已发生的燃烧与热不撤销。
  def settle_spell(before, actor, request, %{session: session, previous: previous, effect: effect, foot: foot}, quote) do
    magic = before.magic
    cid = actor.cid
    seq = before.seq + 1
    balance = Map.get(before.caster_energy, cid, 0.0)
    stone = if effect.sym == "energy.draw", do: property_state(before, effect.target)
    draw = stone && Magic.Cost.draw(effect.args["energy_j"], Map.get(stone, :stored_j, 0.0), balance, magic)
    available = if draw, do: balance + draw.gained_j, else: balance
    outcome = Magic.Cost.misfire(quote, available, %{magic | coherence: magic.coherence * actor.coherence_factor})
    thermal = %{before.thermal | active: true}

    {spent, left, rows, thermal} =
      case {outcome, effect} do
        {nil, %{sym: "act.heat", target: target, args: args}} ->
          source = %{target: target, power_w: args["power_w"], remaining_j: args["energy_j"]}
          thermal = %{thermal | sources: Map.put(thermal.sources, Damage.macro(target), source)}

          {quote.total_j, balance - quote.total_j, [],
           thermal |> Thermal.ledger(:spell_heat_j, args["energy_j"]) |> cast_waste(foot, quote.loss_j)}

        {nil, %{sym: "energy.draw", target: target}} ->
          row = Map.put(stone, :stored_j, Map.get(stone, :stored_j, 0.0) - draw.taken_j)

          thermal =
            thermal
            |> Thermal.deposit_heat(target, draw.loss_j)
            |> Thermal.ledger(:caster_drawn_j, draw.gained_j)
            |> Thermal.ledger(:draw_loss_j, draw.loss_j)
            |> cast_waste(foot, quote.loss_j)

          {quote.loss_j, available - quote.total_j, [row], thermal}

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
            |> cast_waste(foot, quote.loss_j)

          {quote.total_j, balance - quote.total_j, [], thermal}

        {nil, %{sym: "act.dispel", id: id, semblance: s, release: cell}} ->
          thermal =
            thermal
            |> Thermal.release(id, s, cell)
            |> cast_waste(foot, quote.loss_j)

          {quote.total_j, balance - quote.total_j, [], thermal}

        _misfire ->
          spent = min(quote.total_j, balance)
          {spent, balance - spent, [], cast_waste(thermal, foot, spent)}
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

    case Log.append_log(next, txn) do
      :ok ->
        unless previous, do: Process.monitor(actor.player)
        next = Log.remember_entry(next, txn)
        Observation.fanout(next, txn)
        Observation.fanout_canonical(next, txn, [], [], before)

        Logger.info(
          "voxel_spell seq=#{seq} cid=#{cid} request_id=#{request.request_id} sym=#{effect.sym} outcome=#{outcome || :cast} " <>
            "structure=#{quote.structure} quote_j=#{quote.total_j} loss_j=#{quote.loss_j} windup_s=#{quote.windup_s} " <>
            "spent_j=#{spent} energy_j=#{left} " <>
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
