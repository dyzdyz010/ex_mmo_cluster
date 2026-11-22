defmodule VoxelRegion.World.Casting do
  @moduledoc """
  全局系统功能：施法（符号组合魔法 v2，切片 3）——报价、前摇、第 k 步检查与施放结算。

  由 `VoxelRegion.World` 拆出的状态函数：输入与返回都是 World 状态，真值归属与调用时机仍由 World 决定。
  决策稿：`docs/10-active/magic/2026-11-19-slice3-protocol.md`（§3 线上表示、§3.5 施法域、§8 可观测面、§14 v2.11 W1/W3/W7/W9）；
  设计：TheWorldBook `docs/2026-11-19-glyph-composition-game-design.md` v2.11 §4.2、§5.5、§11.4.6。

  ## 一次施放的流程

  1. **入口**（`prepare_spell/4`）：目录 digest → `Program.diagnose_ir/2`（字节层与签名层，唯一信任边界）→ 作用面
     （眼睛射线、形成位置、形成距离）→ 按当时的施放处读数 `Cost.quote_structure/3`。
     - action 0 报价：限频（`quotas.quotes_per_caster_per_s`），回 0x83 v2 全字段；数值检查违规只置 `rejects`。
     - action 1 施放：再校验间隔、脚下、作用对象与地块权限；数值检查违规即拒绝 `{:rejects, [检查名]}`，不进前摇。
  2. **前摇开始**（`begin_cast/7`）：广播 live = 1 的施放记录（每步带 `part_index`），按当时的 Ω_eff 与可用资金预判
     中断步 k，把 `{:cast_prepared, key, %{windup_s, checkpoint_s}}` 发给 Player。Player 是前摇计时器的唯一 owner
     （落地稿 D7）：有 k 时计时器设在 t_k = Σ_{i≤k}(T_adj + T_inj)，否则设在前摇终点。
  3. **第 k 步检查**（W1）：Player 到 t_k 发 `{:check_cast, key, actor, request}`；World 用当时的值重新报价，只判第 1..k 步
     （`settle_cast/3` 的 `through = k`）：仍中断就在首个失败步结算，全部通过回 `{:cast_checked, key, :continue}`，
     Player 为剩余前摇重设计时器。World 结束这次施放（结算、拒绝或已不存在）时回 `{:cast_checked, key, :ended}`。
  4. **出手**：Player 发 `{:authorize_cast, key, actor, request}`；World 按出手时的 site 重新报价、判全部步骤（W9）。
     只在出手时才出现的中断在这里结算并填 `fail_step`。

  ```mermaid
  sequenceDiagram
    participant P as Player（前摇计时 owner）
    participant W as World
    P->>W: prepare_cast（0x82 action 1）
    W-->>P: cast_prepared %{windup_s, checkpoint_s}
    alt 预判第 k 步中断
      P->>W: check_cast（到 t_k）
      alt 第 1..k 步仍失败
        W-->>P: cast_checked :ended（已在第 k 步结算，施放记录 outcome 1）
      else 条件已好转
        W-->>P: cast_checked :continue
        P->>W: authorize_cast（到前摇终点）
      end
    else 无预判中断
      P->>W: authorize_cast（到前摇终点）
    end
  ```

  ## 结算（`settle_cast/3`）

  - 扣费、`fail_step` 与数值检查都取结算时刻（t_k 或出手）的报价；前摇开始时广播的步时长只用于显示与定时（W9）。
  - 中断（outcome 1，`:interrupted_omega` / `:interrupted_energy`）：扣第 1..k 步累计支出（付到耗尽为止），全部支出落在
    形成位置（〈握〉〈取〉为手边点所在格，〈附〉为目标格），按 `release_heat_fraction` 一份作为有限热源、其余计入辐射账；
    该格不是未细分热节点或施法者不可写（他人保护区）时全部计入辐射账（W7）。
  - 〈取〉建成（outcome 0）：石储能减少、施法者得 η·ΔE、构型损耗作为有限热源留在脚下（`cast_waste_j`，W7 末句）。
  - 结构建成：切片 3 显式拒绝 `:structure_runtime_pending`（outcome 2，不扣能，决策稿 P2；切片 4 删除）。
  - 结算时拒绝（目标失效、数值检查违规等）：outcome 2，不扣能、不改世界。
  - 施放记录只带 outcome 与 `fail_step`；实际扣除量只经 0x83 `spent_j` 发给施法者本人（W3）。

  施法者账 `state.caster_energy` 为整数毫焦（守恒量按整数最小单位结算，见 `balance_mj/2`）；旧浮点 J 余额在读入时
  向零截断为 mJ 并在下次结算写回整数（退出条件：S1a A1 迁入 `Pages.character_row`）。`open_account/2` 在角色首次请求
  施法者状态（QUIC 接纳与显式状态请求）时提交一次性开户充能。
  """
  require Logger
  alias VoxelRegion.{Access, Damage}
  alias VoxelRegion.Magic.{Cost, Program, Structure}
  alias VoxelRegion.World.{Clock, Log, Observation, Thermal, Tools}
  import VoxelRegion.World.Canonical

  @hand_reach 0.5
  # 报价限频的滑动窗口（World 单调时钟，毫秒）。
  @quote_window_ms 1_000
  # 开户一次性充能（整数 mJ）：沿用 master 22d64628 的 497 084 850 mJ（497 084.85 J），随日志持久化，每角色至多一次。
  @initial_charge_mj 50 * 9_941_697
  # 0x83 报价扩展段（偏移 73 起 11 个字段）的零值：只有报价回复带扩展段（决策稿 §3.2）。
  @no_extension %{
    x0: 0.0,
    x_star: 0.0,
    e_min_j: 0.0,
    p_maint_w: 0.0,
    life_s: 0.0,
    detect_w: 0.0,
    fail_step: 0,
    rejects: [],
    entries_charge: 0,
    entries_spoof: 0,
    first_tick_min_j: 0.0
  }

  @doc "开户一次性充能（整数 mJ）。"
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
    next = %{
      state
      | seq: state.seq + 1,
        caster_energy: Map.put(state.caster_energy, cid, @initial_charge_mj),
        thermal: Thermal.ledger(state.thermal, :caster_granted_j, @initial_charge_mj / 1000)
    }

    txn = %{
      seq: next.seq,
      entries: [],
      coarse: [],
      caster_energy: %{cid => @initial_charge_mj},
      thermal: next.thermal
    }

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

  @doc "前摇到使用／取消之间仍会重新裁决的射程、脚下依赖；不以定时租约或观察窗口替代。"
  def residency_dependencies(%{pending_casts: casts}) when map_size(casts) == 0,
    do: {:ok, {[], [], []}}

  def residency_dependencies(%{magic: nil}), do: {:error, :pending_cast_without_magic_catalog}

  def residency_dependencies(state) do
    {keys, exact, ids} =
      Enum.reduce(state.pending_casts, {[], [], []}, fn {_cid, pending}, {keys, exact, ids} ->
        {more, precise, identities} =
          VoxelRegion.World.Closure.needs(state, {:spell_intent, pending.actor, pending.request})

        {fx, fy, fz} = pending.actor.feet
        foot = {floor(fx), floor(fy + 0.5) - 1, floor(fz)}
        foot_keys = VoxelRegion.World.Pages.with_ancestors([{0, region_of(foot)}])
        {keys ++ more ++ foot_keys, exact ++ precise, ids ++ identities}
      end)

    {:ok, {Enum.uniq(keys), Enum.uniq(exact), Enum.uniq(ids)}}
  end

  # ---------------------------------------------------------------------------
  # 0x83 施法者状态（决策稿 §3.2）
  # ---------------------------------------------------------------------------

  @doc "无请求的施法者状态（0x83，登录与身体推送）：Ω_eff 取 Scene 最近报来的身体系数（未报过按 1.0），其余报价字段为 0。"
  def caster_status(state, cid) do
    {_identity, factor} = Map.get(state.caster_coherence, cid, {nil, 1.0})
    caster_view(state, cid, resolution(state, factor), %{})
  end

  defp caster_view(state, cid, resolution_eff, fields) do
    %{
      seq: state.seq,
      energy_j: balance_mj(state, cid) / 1000,
      capacity_j: state.magic.caster.capacity_j * 1.0,
      resolution_eff: resolution_eff * 1.0,
      quote_j: 0.0,
      quote_s: 0.0,
      spent_j: 0.0,
      quote_windup_s: 0.0
    }
    |> Map.merge(@no_extension)
    |> Map.merge(fields)
  end

  # 报价回复（action 0）：前 73 B 加扩展段。施法者动作程序只有 fail_step 与 rejects（设计 v2.10 E4），结构类字段为 0。
  defp quote_view(state, actor, program, quote, failure) do
    fields = %{
      quote_j: quote.total_mj / 1000,
      quote_s: sp(quote) * 1.0,
      quote_windup_s: quote.windup_s,
      fail_step: fail_step(failure),
      rejects: reject_names(quote)
    }

    caster_view(
      state,
      actor.cid,
      resolution_eff(state, actor),
      Map.merge(fields, structure_extension(program, quote))
    )
  end

  defp structure_extension(%Program{kind: :structure}, quote),
    do: %{
      x0: quote.x0,
      x_star: quote.x_star,
      e_min_j: quote.e_min_mj / 1000,
      p_maint_w: quote.p_maint_w,
      life_s: quote.life_s,
      detect_w: quote.detect_w,
      entries_charge: quote.entries_charge,
      entries_spoof: quote.entries_spoof,
      first_tick_min_j: quote.first_tick_min_mj / 1000
    }

  defp structure_extension(%Program{kind: :caster_action}, _quote), do: %{}

  # 结算后的状态：报价总价与 S·P 照填，spent_j 是本次实际扣除（只发施法者本人，W3），扩展段为 0。
  defp settled_view(state, actor, quote, spent_j),
    do:
      caster_view(state, actor.cid, resolution_eff(state, actor), %{
        quote_j: quote.total_mj / 1000,
        quote_s: sp(quote) * 1.0,
        spent_j: spent_j
      })

  # Ω_eff = 目录 `caster.resolution_omega` × 身体系数（设计 §4.1）；报价、前摇开始、检查与出手各取当时 actor 的系数。
  defp resolution(state, factor), do: state.magic.caster.resolution_omega * factor
  defp resolution_eff(state, actor), do: resolution(state, actor.coherence_factor)

  @doc "全局系统功能：World 的无请求状态出口；登录及身体推送都保留接纳它的连接/会话身份。"
  def publish_caster_state({gate, identity}, request_id, caster) do
    {:ok, bytes} =
      MmoContracts.Voxel.Codec.encode(
        {:voxel_caster_state, Map.put(caster, :request_id, request_id)}
      )

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

  # ---------------------------------------------------------------------------
  # 入口：报价与前摇开始
  # ---------------------------------------------------------------------------

  @doc """
  施法意图（0x82）的 World 入口。action 0 报价：`{:reply, {:ok, %{seq, outcome: nil, caster}}, state}`，不改世界；
  action 1 施放：立即校验失败 `{:reply, {:error, reason}, state}`，通过则广播施放记录、通知 Player 并返回
  `{:noreply, state}`（结算后才回复 `from`）。拒绝原因见决策稿 §3.4：`:stale_magic_catalog`、`:invalid_program`、
  `{:rejects, [检查名]}`、`:no_target`、`:quote_rate`、`:cast_too_soon` 等。
  """
  def prepare_spell(state, from, actor, request) do
    with :ok <- current_catalog(state, request),
         {:ok, program} <- decode_program(state, actor, request) do
      case request.action do
        0 -> quote_spell(state, actor, request, program)
        _ -> cast_spell(state, from, actor, request, program)
      end
    else
      {:error, reason} -> reject(state, actor, request, :prepare, reason)
    end
  end

  defp current_catalog(%{magic: %{digest: digest}}, %{catalog_digest: digest}), do: :ok
  defp current_catalog(_state, _request), do: {:error, :stale_magic_catalog}

  # 字节层与签名层的唯一判定；拒绝原因带上下文只在这里写一次（决策稿 §8），线上只回 :invalid_program（W8）。
  defp decode_program(state, actor, request) do
    case Program.diagnose_ir(request.program, state.magic) do
      {:ok, program} ->
        {:ok, program}

      {:error, reason} ->
        Logger.warning(
          "voxel_magic_program_rejected cid=#{actor.cid} request_id=#{request.request_id} action=#{request.action} " <>
            "bytes=#{byte_size(request.program)} program_sha=#{sha(request.program)} reason=#{inspect(reason)}"
        )

        {:error, :invalid_program}
    end
  end

  defp quote_spell(state, actor, request, program) do
    case admit_quote(state, actor) do
      {:error, :quote_rate} ->
        reject(state, actor, request, :quote, :quote_rate)

      {:ok, admitted} ->
        case spell_effect(admitted, actor, request, program) do
          # 射线失败的报价同样计入窗口。
          {:error, reason, _state} ->
            reject(admitted, actor, request, :quote, reason)

          {:ok, effect, next} ->
            quote = spell_quote(next, actor, program, effect)
            funds = cast_funding(next, actor.cid, effect).available_mj
            failure = Cost.staged_failure(quote, funds, resolution_eff(next, actor))
            log_quote(next, actor, request, :quote, program, effect, quote, failure)

            {:reply,
             {:ok,
              %{
                seq: next.seq,
                outcome: nil,
                caster: quote_view(next, actor, program, quote, failure)
              }}, next}
        end
    end
  end

  # 报价限频（设计 §4.2 末段，决策稿 P7）：每施法者任一 1 s 滑动窗口内至多目录 `quotas.quotes_per_caster_per_s` 次，
  # 超出显式拒绝 :quote_rate；被拒的报价不计入窗口。时间取 World 自己的单调时钟：限频保护的是 World 的计算，
  # 与 Gate 入口时钟（跨节点不可比）无关。窗口每施法者至多 limit 个时刻，随角色数有界。
  defp admit_quote(state, actor) do
    now = Clock.monotonic(state)

    recent =
      state.quote_admissions
      |> Map.get(actor.cid, [])
      |> Enum.filter(&(&1 > now - @quote_window_ms))

    if length(recent) < state.magic.quotas.quotes_per_caster_per_s,
      do:
        {:ok,
         %{state | quote_admissions: Map.put(state.quote_admissions, actor.cid, [now | recent])}},
      else: {:error, :quote_rate}
  end

  defp cast_spell(state, from, actor, request, program) do
    with false <- Map.has_key?(state.pending_casts, actor.cid),
         {:ok, checked, next} <- check_cast(state, actor, request, program),
         quote = spell_quote(next, actor, program, checked.effect),
         :ok <- numeric_checks(quote) do
      begin_cast(next, from, actor, request, program, checked.effect, quote)
    else
      true -> reject(state, actor, request, :prepare, :cast_too_soon)
      {:error, reason} -> reject(state, actor, request, :prepare, reason)
    end
  end

  # 前摇开始：施放记录（t0 = 服务器时间线 MmoContracts.ServerTime，出发点 = 手边，每步带 part_index）随一笔只带记录的
  # 事务广播；按当时的 Ω_eff 与可用资金预判中断步 k，有 k 时 Player 的计时器设在 t_k（W1）。
  defp begin_cast(state, from, actor, request, program, effect, quote) do
    predicted =
      Cost.staged_failure(
        quote,
        cast_funding(state, actor.cid, effect).available_mj,
        resolution_eff(state, actor)
      )

    checkpoint = predicted && elem(predicted, 0)

    plan = %{
      windup_s: quote.windup_s,
      checkpoint_s: checkpoint && elapsed_through(quote, checkpoint)
    }

    record = %{
      live: 1,
      t0_us: MmoContracts.ServerTime.now_us(state.server_clock),
      program: request.program,
      steps: Enum.map(quote.steps, &Map.take(&1, [:part_index, :adjust_s, :inject_s])),
      origin: hand_point(actor, request)
    }

    case commit_casts(state, {:character, actor.cid}, %{actor.cid => record}) do
      {:ok, next} ->
        monitor = Process.monitor(actor.player)
        send(actor.player, {:cast_prepared, actor.action_key, plan})
        log_quote(next, actor, request, :prepare, program, effect, quote, predicted)

        Logger.info(
          "voxel_cast_begin seq=#{next.seq} cid=#{actor.cid} request_id=#{request.request_id} t0_us=#{record.t0_us} " <>
            "kind=#{program.kind} program_sha=#{sha(program.bytes)} sp=#{sp(quote)} total_mj=#{quote.total_mj} " <>
            "windup_s=#{quote.windup_s} checkpoint_step=#{checkpoint || 0} checkpoint_s=#{plan.checkpoint_s || 0.0} " <>
            "steps=#{inspect(Enum.map(record.steps, &{&1.part_index, &1.adjust_s, &1.inject_s}))}"
        )

        pending = %{
          record: record,
          from: from,
          actor: actor,
          request: request,
          program: program,
          monitor: monitor,
          checkpoint: checkpoint
        }

        {:noreply, %{next | pending_casts: Map.put(next.pending_casts, actor.cid, pending)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp elapsed_through(quote, k),
    do: quote.steps |> Enum.take(k) |> Enum.map(&(&1.adjust_s + &1.inject_s)) |> Enum.sum()

  @doc "授权所指的仍在前摇的待施放：同一动作、同一 Player；已取消 / 已结算的旧授权返回 nil（结算入口与读取闭包共用此判定）。"
  def authorized_pending(state, key, actor) do
    case state.pending_casts[actor.cid] do
      %{actor: %{action_key: ^key, player: player}} = pending when player == actor.player ->
        pending

      _ ->
        nil
    end
  end

  @doc "检查或出手时以 Player 送来的当前 actor 与方向更新待施放（射线、施法域与 Ω_eff 都按这一刻求）。"
  def refresh_pending(pending, actor, request),
    do: %{
      pending
      | actor: Map.merge(pending.actor, actor),
        request: %{pending.request | direction: request.direction}
    }

  @doc "取消待施放：提交一笔只带 live = 0 / outcome 2 记录的事务，不扣能，调用方收到 `{:error, reason}`。"
  def cancel_pending_cast(state, key, reason) do
    case Enum.find(state.pending_casts, fn {_, pending} -> pending.actor.action_key == key end) do
      nil ->
        state

      {cid, pending} ->
        Process.demonitor(pending.monitor, [:flush])
        {:ok, next} = commit_casts(state, :system, %{cid => %{live: 0, outcome: 2, fail_step: 0}})
        GenServer.reply(pending.from, {:error, reason})
        %{next | pending_casts: Map.delete(next.pending_casts, cid)}
    end
  end

  # ---------------------------------------------------------------------------
  # 结算（第 k 步检查与出手）
  # ---------------------------------------------------------------------------

  @doc """
  结算待施放（设计 v2.11 W1、W9）。`through` 为 nil 时是出手：按当时的 site 重新报价，判全部步骤；为 k 时是第 k 步
  时刻的检查：只判第 1..k 步，全部通过返回 `{:continue, state}`（不提交），否则在首个失败步结算。
  其余返回 `{reply, state}`，reply 由调用方转给施法请求的等待方。待施放的移除与监视由调用方负责。
  """
  def settle_cast(state, pending, through) do
    %{actor: actor, request: request, program: program} = pending
    phase = if through, do: :checkpoint, else: :release

    case check_cast(state, actor, request, program) do
      {:error, reason} ->
        settle_rejected(state, pending, phase, reason)

      {:ok, checked, next} ->
        quote = spell_quote(next, actor, program, checked.effect)
        funding = cast_funding(next, actor.cid, checked.effect)
        steps = if through, do: Enum.take(quote.steps, through), else: quote.steps

        failure =
          Cost.staged_failure(
            %{quote | steps: steps},
            funding.available_mj,
            resolution_eff(next, actor)
          )

        log_quote(next, actor, request, phase, program, checked.effect, quote, failure)

        cond do
          quote.rejects != [] ->
            settle_rejected(next, pending, phase, {:rejects, reject_names(quote)}, checked.effect)

          failure != nil ->
            settle_interrupted(next, pending, checked, quote, funding, failure)

          through != nil ->
            {:continue, next}

          program.kind == :caster_action ->
            settle_draw(next, pending, checked, quote, funding)

          program.kind == :structure ->
            settle_rejected(next, pending, phase, :structure_runtime_pending)
        end
    end
  end

  # 结算时拒绝：施放记录 outcome 2，不扣能、不改世界。
  defp settle_rejected(state, pending, phase, reason, effect \\ nil) do
    cid = pending.actor.cid

    case commit_casts(state, {:character, cid}, %{cid => %{live: 0, outcome: 2, fail_step: 0}}) do
      {:ok, next} ->
        log_rejected(next, pending.actor, pending.request, phase, reason, effect)
        {{:error, reason}, next}

      {:error, error} ->
        {{:error, error}, state}
    end
  end

  # 〈取〉建成：石减少 taken = 施法者取得 gained + 取能损耗（落在石格）；构型损耗作为有限热源留在脚下（cast_waste_j）。
  defp settle_draw(state, pending, checked, quote, funding) do
    %{draw: draw, balance_mj: balance_mj} = funding
    total_mj = quote.total_mj
    row = Map.put(draw.stone, :stored_j, Map.get(draw.stone, :stored_j, 0.0) - draw.taken_mj / 1000)

    thermal =
      %{state.thermal | active: true}
      |> Thermal.deposit_heat(checked.effect.target, draw.loss_mj / 1000)
      |> Thermal.ledger(:caster_drawn_j, draw.gained_mj / 1000)
      |> Thermal.ledger(:draw_loss_j, draw.loss_mj / 1000)
      |> cast_waste(checked.foot, total_mj / 1000)

    commit_settlement(state, pending, checked, quote, %{
      thermal: thermal,
      rows: [row],
      balance_mj: balance_mj,
      left_mj: balance_mj + draw.gained_mj - total_mj,
      spent_mj: total_mj,
      outcome: nil,
      record: %{live: 0, outcome: 0, fail_step: 0},
      log:
        "outcome=built taken_mj=#{draw.taken_mj} gained_mj=#{draw.gained_mj} " <>
          "draw_loss_mj=#{draw.loss_mj}"
    })
  end

  # 建构在第 k 步中断（设计 §5.5、v2.11 W7）：扣第 1..k 步累计支出，付到耗尽为止；〈取〉的取能不发生，扣费以余额为限
  # （`cast_funding/3`）。全部支出在形成位置按释放形态分成有限热源与辐射账；落不进该格时全部计入辐射账。
  defp settle_interrupted(state, pending, checked, quote, funding, {k, spent_mj, cause}) do
    charge_mj = min(spent_mj, funding.payable_mj)
    {heat_mj, radiation_mj} = Structure.release_split(charge_mj, state.magic)
    {node, state} = release_node(state, checked.effect.formation)

    thermal =
      case node do
        nil ->
          Thermal.ledger(state.thermal, :cast_interrupt_radiation_j, charge_mj / 1000)

        node ->
          %{state.thermal | active: true}
          |> Thermal.deposit_heat(node, heat_mj / 1000)
          |> Thermal.ledger(:cast_interrupt_heat_j, heat_mj / 1000)
          |> Thermal.ledger(:cast_interrupt_radiation_j, radiation_mj / 1000)
      end

    commit_settlement(state, pending, checked, quote, %{
      thermal: thermal,
      rows: [],
      balance_mj: funding.balance_mj,
      left_mj: funding.balance_mj - charge_mj,
      spent_mj: charge_mj,
      outcome: if(cause == :omega, do: :interrupted_omega, else: :interrupted_energy),
      record: %{live: 0, outcome: 1, fail_step: k},
      log:
        "outcome=interrupted fail_step=#{k} cause=#{cause} release_cell=#{inspect(checked.effect.formation)} " <>
          "heat_mj=#{if node, do: heat_mj, else: 0} radiation_mj=#{if node, do: radiation_mj, else: charge_mj}"
    })
  end

  # 中断支出的落点（设计 v2.11 W7、§5.5 释放形态）：形成位置所在宏格是未细分热节点才作为有限热源落入，否则（空气、
  # 细分构件）返回 nil，全部计入辐射账。地块持有者的执行时复核（设计 §14.0 Q7）已由同一回合的 `check_cast/4` 完成：
  # 〈握〉的手边格与〈附〉的目标格都在作用格里按施法者授权；〈取〉的手边点在眼睛射线上、位于命中之前，只可能是空气或
  # 目标石本身（也在作用格里）。他人保护区里的形成位置因此在结算前就以 :protected_region 拒绝，不会走到这里。
  defp release_node(state, {x, y, z}) do
    case target_at({x * 8, y * 8, z * 8}, state) do
      {%{granularity: 0} = target, state} -> {if(heat_node?(state, target), do: target), state}
      {_, state} -> {nil, state}
    end
  end

  # 已结算的施放（建成或中断）：施法者余额、石行、热账与施放记录在同一笔事务里原子提交（铁律 5：热经 thermal.sources 进世界）。
  defp commit_settlement(before, pending, checked, quote, settlement) do
    %{actor: actor, request: request, program: program} = pending
    cid = actor.cid
    seq = before.seq + 1
    rows = Enum.map(settlement.rows, &%{&1 | seq: seq, request_id: 0})

    next = %{
      before
      | seq: seq,
        thermal: settlement.thermal,
        caster_energy: Map.put(before.caster_energy, cid, settlement.left_mj),
        spell_sessions: Map.put(before.spell_sessions, actor.player, checked.session),
        damage: Enum.reduce(rows, before.damage, &Map.put(&2, Damage.key(&1), &1))
    }

    txn = %{
      seq: seq,
      entries: [],
      coarse: [],
      property_states: rows,
      thermal: settlement.thermal,
      caster_energy: %{cid => settlement.left_mj},
      casts: %{cid => settlement.record}
    }

    case Log.append_log(before, next, txn, {:character, cid}) do
      :ok ->
        unless checked.previous, do: Process.monitor(actor.player)
        next = Log.remember_entry(next, txn)
        Observation.fanout(next, txn)
        Observation.fanout_canonical(next, txn, [], [], before)

        Logger.info(
          "voxel_spell seq=#{seq} cid=#{cid} request_id=#{request.request_id} kind=#{program.kind} " <>
            "program_sha=#{sha(program.bytes)} #{settlement.log} spent_mj=#{settlement.spent_mj} " <>
            "balance_before_mj=#{settlement.balance_mj} energy_mj=#{settlement.left_mj} energy_j=#{settlement.left_mj / 1000} " <>
            "resolution_eff=#{resolution_eff(before, actor)} foot=#{inspect(Damage.macro(checked.foot))}"
        )

        {{:ok,
          %{
            seq: seq,
            outcome: settlement.outcome,
            caster: settled_view(next, actor, quote, settlement.spent_mj / 1000)
          }}, Thermal.wake(next)}

      {:error, reason} ->
        {{:error, reason}, before}
    end
  end

  # 只带施放记录的事务（同只带落体帧的事务）：日志里是空事务，保持 seq 连续；记录只随本次广播。
  defp commit_casts(state, principal, casts) do
    next = %{state | seq: state.seq + 1}
    txn = %{seq: next.seq, entries: [], coarse: [], casts: casts}

    with :ok <- Log.append_log(state, next, txn, principal) do
      next = Log.remember_entry(next, txn)
      Observation.fanout(next, txn)
      Observation.fanout_canonical(next, txn, [], [], state)
      {:ok, next}
    end
  end

  defp cast_waste(thermal, foot, energy),
    do: thermal |> Thermal.deposit_heat(foot, energy) |> Thermal.ledger(:cast_waste_j, energy)

  # ---------------------------------------------------------------------------
  # 校验、作用面与施放处读数
  # ---------------------------------------------------------------------------

  # 施放（前摇开始、第 k 步检查与出手共用）：间隔、作用面（射线）、脚下、作用对象与地块权限。数值检查在报价里。
  defp check_cast(state, actor, request, program) do
    previous = Map.get(state.spell_sessions, actor.player)

    with {:ok, session} <- admit_cast(previous, request, actor, state.magic),
         {:ok, effect, state} <- spell_effect(state, actor, request, program),
         {:ok, foot, state} <- foot_target(state, actor),
         :ok <- spell_subject(state, effect),
         # 作用格不全是本笔写集（〈附〉的结构到切片 4 才落地），提交入口查不到，所以在意图处按作用格判定。
         :ok <-
           Access.authorize_cells(
             {:character, actor.cid},
             state.protection,
             effect.cells ++ [Damage.macro(foot)],
             :character_intent
           ) do
      {:ok, %{session: session, previous: previous, effect: effect, foot: foot}, state}
    else
      {:error, reason} -> {:error, reason}
      {:error, reason, _} -> {:error, reason}
    end
  end

  # 施法间隔与工具同一 GCRA（Gate 入口时钟、一个权威 tick 的相位借用）；过快即 cast_too_soon。
  defp admit_cast(previous, request, actor, magic) do
    case Damage.admit_attack(
           previous,
           request.client_intent_seq,
           actor.received_us,
           magic.limits.cast_interval_us,
           actor.tick_us
         ) do
      {:error, :tool_cooldown} -> {:error, :cast_too_soon}
      result -> result
    end
  end

  # 作用面：`formation` 是形成位置所在宏格（中断支出的落点，W7），`formation_distance_m` 进 site 供 T6 判施法域，
  # `cells` 是需要地块权限的宏格。〈取〉：眼睛射线命中的能源目标，形成位置是手边点（W7）。结构按形成锚：
  # 〈握〉手边点（距离 0，设计 §3.3 T6）；〈附〉眼睛射线命中的目标格（设计 §11.4.6 第 8 项：格面由服务端射线推出）。
  defp spell_effect(state, actor, request, %Program{
         kind: :caster_action,
         action: %{id: "energy.draw", params: %{"energy_mj" => requested_mj}}
       }) do
    with {:ok, target, distance, state} <- spell_target(state, actor, request) do
      {:ok,
       %{
         kind: :caster_action,
         target: target,
         requested_mj: requested_mj,
         formation: hand_cell(actor, request),
         formation_distance_m: distance,
         cells: [Damage.macro(target)]
       }, state}
    end
  end

  defp spell_effect(state, actor, request, %Program{
         kind: :structure,
         groups: [%{form_anchor: %{id: "anchor.hand"}}]
       }) do
    cell = hand_cell(actor, request)

    {:ok,
     %{kind: :structure, target: nil, formation: cell, formation_distance_m: 0.0, cells: [cell]},
     state}
  end

  defp spell_effect(state, actor, request, %Program{
         kind: :structure,
         groups: [%{form_anchor: %{id: "anchor.surface"}}]
       }) do
    with {:ok, target, distance, state} <- spell_target(state, actor, request) do
      cell = Damage.macro(target)

      {:ok,
       %{
         kind: :structure,
         target: target,
         formation: cell,
         formation_distance_m: distance,
         cells: [cell]
       }, state}
    end
  end

  # 施法者眼睛射线（与工具同一权威射线，射程目录 `limits.range_m`）：射程内没命中为 :no_target（决策稿 P13），首个命中
  # 必须是请求的目标。返回目标与形成距离：眼点到目标宏格中心 (x + 0.5, y + 0.5, z + 0.5)（设计 v2.10 E4）。
  # 施法域只在报价的 T6 判一次（决策稿 §3.5），这里不判距离。
  defp spell_target(state, actor, request) do
    case Tools.tool_target(state, actor, request, %{
           "range_macro" => state.magic.limits.range_m,
           "action" => "magic"
         }) do
      {:ok, target, state} ->
        if Tools.same_tool_target?(target, request),
          do: {:ok, target, formation_distance(actor, target), state},
          else: {:error, :stale_target, state}

      {:error, _reason, _state} = error ->
        error
    end
  end

  defp formation_distance(%{eye: {ex, ey, ez}}, target) do
    {x, y, z} = Damage.macro(target)
    :math.sqrt((x + 0.5 - ex) ** 2 + (y + 0.5 - ey) ** 2 + (z + 0.5 - ez) ** 2)
  end

  defp hand_point(%{eye: {ex, ey, ez}}, %{direction: {dx, dy, dz}}),
    do: {ex + dx * @hand_reach, ey + dy * @hand_reach, ez + dz * @hand_reach}

  defp hand_cell(actor, request) do
    {x, y, z} = hand_point(actor, request)
    {floor(x), floor(y), floor(z)}
  end

  # 作用对象：〈取〉只作用于未细分的蓄能石宏格；结构的作用面已由形成锚确定。
  defp spell_subject(state, %{kind: :caster_action, target: target}),
    do: if(battery?(state, target), do: :ok, else: {:error, :invalid_target})

  defp spell_subject(_state, %{kind: :structure}), do: :ok

  defp battery?(state, target),
    do:
      target.granularity == 0 and
        VoxelRegion.Circuit.battery?(state.properties.materials[target.material])

  # 施放处读数（`Cost.site/0`）：环境温度取施法者所在格的空气温度（气候区，设计 §4.2：只按施法者所在格，不含邻近干扰），
  # 形成距离来自作用面，发射率与换热系数是 World 热环境参数（设计 v2.9 A2，不进目录）。
  defp spell_quote(state, actor, program, effect) do
    config = state.thermal.config
    {fx, fy, fz} = actor.feet

    site = %{
      ambient_k: ambient_at(state, {floor(fx), floor(fy), floor(fz)}) * 1.0,
      formation_distance_m: effect.formation_distance_m,
      emissivity: config["emissivity"],
      exchange_w_per_m2_k: config["environment_w_per_m2_k"]
    }

    program
    |> Cost.quote_structure(state.magic, site)
    |> basic_windup(state, program)
  end

  @doc """
  持物普攻法术的固定前摇（Voxim 交互设计"2026-11-20 修订"，用户 2026-11-20 定）：程序与已发布属性目录某持物的
  `basic_spell`（规范 IR v2 字节）相等，前摇即取该持物的作者值 `basic_windup_s`；其余程序照常用成本模型前摇。
  判定只看程序本身（服务端不知道玩家拿着什么），所以同一程序从技能栏施放也是这个前摇——这是程序的规则，不是装备规则。
  成本（总支出、各步累计支出、分阶段失败）不变。广播的各步 `{调整 s, 注能 s}` 按同一比例缩放，使
  Σ(调整 + 注能) + release_lead_s 等于该前摇。作者前摇须 ≥ 魔法目录 `construction.release_lead_s`。
  """
  def basic_windup(quote, state, program) do
    case match_basic_spell(state, program) do
      nil ->
        quote

      {_, windup_s} ->
        lead = state.magic.construction.release_lead_s
        true = windup_s >= lead
        step_sum = Enum.sum(for s <- quote.steps, do: s.adjust_s + s.inject_s)
        k = if step_sum > 0.0, do: (windup_s - lead) / step_sum, else: 0.0

        %{
          quote
          | windup_s: windup_s,
            steps:
              for(s <- quote.steps, do: %{s | adjust_s: s.adjust_s * k, inject_s: s.inject_s * k})
        }
    end
  end

  @doc """
  持物普攻法术查找：`basic_windup/3` 与切片 4 结构构造（无重力直线弹道 `no_gravity`）共用同一判定。
  `program` 已通过当前魔法目录的 `Program.diagnose_ir/2`（规范字节唯一），故与目录中已解码的 `basic_spell` 字节相等即等价。
  """
  def match_basic_spell(%{properties: nil}, _program), do: nil

  def match_basic_spell(state, %Program{bytes: bytes}) do
    Enum.find(state.properties.basic_windups, fn {spell_bytes, _} -> spell_bytes == bytes end)
  end

  # 施法的可用资金（整数 mJ）：
  # - `available_mj`：交 `Cost.staged_failure/3` 判定的资金；`payable_mj`：中断时实际可扣的上限。
  # - 结构程序：二者都是余额。
  # - 〈取〉（用户 2026-11-21 裁定，决策稿 §14）：构型损耗从取得的能量里付，判定用“余额 + η·ΔE”，
  #   否则余额为 0 的角色永远在第 1 步中断、取不到能；中断时取能不发生，所以扣费以余额为限。
  defp cast_funding(state, cid, effect) do
    balance_mj = balance_mj(state, cid)
    draw = energy_draw(state, effect, balance_mj)
    gained_mj = if draw, do: draw.gained_mj, else: 0

    %{
      balance_mj: balance_mj,
      draw: draw,
      available_mj: balance_mj + gained_mj,
      payable_mj: balance_mj
    }
  end

  # 〈取〉的取能分账（整数 mJ，附石行）；目标不是蓄能石（报价不判作用对象）或不是〈取〉时为 nil。
  defp energy_draw(
         state,
         %{kind: :caster_action, target: target, requested_mj: requested_mj},
         balance_mj
       ) do
    if battery?(state, target) do
      stone = property_state(state, target)

      requested_mj
      |> Cost.draw(trunc(Map.get(stone, :stored_j, 0.0) * 1000), balance_mj, state.magic)
      |> Map.put(:stone, stone)
    end
  end

  defp energy_draw(_state, _effect, _balance_mj), do: nil

  defp numeric_checks(quote) do
    case reject_names(quote) do
      [] -> :ok
      names -> {:error, {:rejects, names}}
    end
  end

  # ---------------------------------------------------------------------------
  # 可观测面（决策稿 §8）
  # ---------------------------------------------------------------------------

  defp reject(state, actor, request, phase, reason) do
    # 程序拒绝已由 voxel_magic_program_rejected 带原因记过一次。
    if reason != :invalid_program, do: log_rejected(state, actor, request, phase, reason, nil)
    {:reply, {:error, reason}, state}
  end

  # phase：quote（报价）| prepare（前摇开始）| checkpoint（第 k 步检查）| release（出手）。施法域违规另记形成距离与施法域，
  # 便于区分“前摇中移出域外”与其他拒绝。
  defp log_rejected(state, actor, request, phase, reason, effect) do
    detail =
      case {reason, effect} do
        {{:rejects, names}, %{formation_distance_m: distance}} ->
          "reason=rejects rejects=#{Enum.join(names, ",")} formation_distance_m=#{distance} " <>
            "local_domain_m=#{state.magic.limits.local_domain_m}"

        {{:rejects, names}, _} ->
          "reason=rejects rejects=#{Enum.join(names, ",")}"

        {:quote_rate, _} ->
          "reason=quote_rate limit_per_s=#{state.magic.quotas.quotes_per_caster_per_s}"

        {reason, _} when is_atom(reason) ->
          "reason=#{reason}"

        {reason, _} ->
          "reason=#{inspect(reason)}"
      end

    Logger.info(
      "voxel_cast_rejected seq=#{state.seq} cid=#{actor.cid} request_id=#{request.request_id} phase=#{phase} #{detail}"
    )
  end

  defp log_quote(state, actor, request, phase, program, effect, quote, failure) do
    Logger.info(
      "voxel_spell_quote seq=#{state.seq} cid=#{actor.cid} request_id=#{request.request_id} phase=#{phase} " <>
        "kind=#{program.kind} program_sha=#{sha(program.bytes)} formation_distance_m=#{effect.formation_distance_m} " <>
        "units=#{quote.units} precision=#{quote.precision} sp=#{sp(quote)} resolution_eff=#{resolution_eff(state, actor)} " <>
        "total_mj=#{quote.total_mj} windup_s=#{quote.windup_s} fail_step=#{fail_step(failure)} " <>
        "cause=#{if failure, do: elem(failure, 2), else: :none} rejects=#{Enum.join(reject_names(quote), ",")} " <>
        "x0=#{Map.get(quote, :x0, 0.0)} x_star=#{Map.get(quote, :x_star, 0.0)} life_s=#{Map.get(quote, :life_s, 0.0)}"
    )
  end

  # 程序模板身份（设计 §11.4.3 推论）：规范字节 sha256 的前 16 位十六进制；日志不记程序全文。
  defp sha(bytes),
    do: :crypto.hash(:sha256, bytes) |> binary_part(0, 8) |> Base.encode16(case: :lower)

  defp sp(quote), do: quote.units * quote.precision
  defp fail_step(nil), do: 0
  defp fail_step({k, _spent, _cause}), do: k
  defp reject_names(quote), do: quote.rejects |> Enum.map(& &1.check) |> Enum.uniq()
end
