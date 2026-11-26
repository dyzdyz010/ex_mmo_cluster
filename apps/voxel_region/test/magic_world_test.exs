defmodule VoxelRegion.MagicWorldTest do
  @moduledoc """
  只测试：魔法 v2 切片 3 在真实 World 里的报价、〈取〉、分阶段失败（第 k 步结算）、施法域与拒绝
  （决策稿 `docs/10-active/magic/2026-11-19-slice3-protocol.md` §3、§9 的 W-1/W-5/W-6/W-9/W-10 与 §14 v2.11 W1/W3/W7/W9）。

  目录：材料 `b1aca503…`（蓄能石 42 每宏格 10 MJ、叶 28 热容 1200 J/K），魔法 v5 发布物 `priv/magic/<sha256>.json`；
  热环境 `environment-radiation.json`（T_amb 293.15 K、ε 0.9、h 10 W/(m²·K)，与报价样本的 site 相同）。
  场景（Y-up，1 宏格 = 1 m）：地面石 11 铺 y = 0（x −8..12）；施法者脚 (0.5, 1.0, 0.5)、眼 (0.5, 2.5, 0.5)；
  蓄能石 A (2,1,0)（眼到格心 √5 ≈ 2.24 m）、蓄能石 B (9,1,0)（≈ 9.06 m，施法域 6 m 外、射程 30 m 内）、
  孤立叶 (0,2,3)（眼到格心 3.0 m，与报价样本 site 的形成距离相同）。蓄能石 A 的 10 MJ 储能经持久化边界安装一次
  （同 v1 用例：新蓄能石为空，单测无法经正常玩法充满），之后只经正式施法入口变化。

  程序字节取自 `ir-v2-samples.json`；取能量非样本值的〈取〉按 §11.4.1 布局现编（kind 0、下标 0、`dec` 槽），客户端
  编辑器同样能产生。期望值只取自报价样本 `quote-v2-samples.json`（总价、各步时长与累计支出）、目录常数（η 0.9、
  `release_heat_fraction` 0.5、施法域 6 m）与决策稿的结算口径，不调 `Magic.Cost`。

  驱动方式：`TestSupport.spell/3` 走 `World.spell_intent/3`，前摇出现后直接投递出手授权；需要观察 W1 检查的用例由测试
  进程充当 Player（收 `cast_prepared` / `cast_checked`，发 `check_cast` / `authorize_cast`），与真实 Player 同一消息。
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias VoxelRegion.{World, OverlayLog}
  alias VoxelRegion.TestSupport.{Actor, Log, Source}

  @properties "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  @fixtures Path.expand("fixtures", __DIR__)
  @catalog Path.expand("../priv/magic", __DIR__)
           |> Path.join("*.json")
           |> Path.wildcard()
           |> then(fn [path] -> path end)
  @ir Path.join(@fixtures, "magic/ir-v2-samples.json") |> File.read!() |> Jason.decode!()
  @quotes Path.join(@fixtures, "magic/quote-v2-samples.json") |> File.read!() |> Jason.decode!()
  @external_resource @catalog
  @external_resource Path.join(@fixtures, "magic/ir-v2-samples.json")
  @external_resource Path.join(@fixtures, "magic/quote-v2-samples.json")
  @stone 11
  @leaf 28
  @battery 42
  @box {{-2, -2, -2}, {2, 2, 2}}
  @simulation_box {{-8, 0, -2}, {12, 3, 5}}
  @cid 1001
  @stone_micro {20, 12, 4}
  @far_micro {76, 12, 4}
  @leaf_micro {4, 20, 28}

  setup do
    root = Path.join(System.tmp_dir!(), "magic_world_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.cp!(
      Path.join([@fixtures, "combustion", @properties <> ".json"]),
      Path.join(root, "properties.json")
    )

    File.cp!(
      Path.join([@fixtures, "combustion", "environment-radiation.json"]),
      Path.join(root, "environment.json")
    )

    File.cp!(@catalog, Path.join(root, "magic.json"))
    w = start(root)
    ground = for x <- -8..12, z <- -2..4, do: {{x, 0, z}, @stone}

    {:ok, _} =
      World.apply_edits(
        w,
        ground ++ [{{2, 1, 0}, @battery}, {{9, 1, 0}, @battery}, {{0, 2, 3}, @leaf}]
      )

    a = actor()

    # 作者初态：查询蓄能石 A 的正式属性行，再经持久化边界写入 10 MJ 储能（见 moduledoc）。
    {:ok, row} = World.tool_intent(w, a, query(a, @stone_micro))
    seq = World.seq(w)
    :ok = stop_supervised(:world)

    OverlayLog.File.append(Path.join(root, "overlay.log"), %{
      seq: seq + 1,
      entries: [],
      coarse: [],
      property_states: [Map.merge(row, %{stored_j: 1.0e7, seq: seq + 1, request_id: 0})]
    })

    w = start(root)
    assert battery(observe(w)).stored_j == 1.0e7
    :ok = VoxelRegion.TestSupport.activate_simulation(w, @simulation_box)
    %{w: w, root: root, a: a, digest: :crypto.hash(:sha256, File.read!(@catalog))}
  end

  defp start(root) do
    start_supervised!(
      {World,
       [
         source: Source,
         log: Log,
         root: root,
         observer: self(),
         name: nil,
         property_catalog_path: Path.join(root, "properties.json"),
         thermal_environment_path: Path.join(root, "environment.json"),
         magic_catalog_path: Path.join(root, "magic.json")
       ]},
      id: :world
    )
  end

  defp restart(c),
    do:
      (
        :ok = stop_supervised(:world)
        start(c.root)
      )

  defp actor(cid \\ @cid, eye \\ {0.5, 2.5, 0.5}, feet \\ {0.5, 1.0, 0.5}) do
    a = %{
      cid: cid,
      gate: self(),
      identity: make_ref(),
      refresh: &Actor.tool_context/2,
      eye: eye,
      feet: feet,
      tick_us: 16_667
    }

    Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
  end

  defp next, do: System.unique_integer([:positive, :monotonic])
  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [@cid], @box)

  defp cell(s, {x, y, z}),
    do:
      Enum.find(
        Map.values(s.damage),
        &(&1.granularity == 0 and &1.micro == {x * 8, y * 8, z * 8})
      )

  defp battery(s), do: cell(s, {2, 1, 0})
  defp energy(c), do: elem(World.caster_state(c.w, @cid), 1).energy_j
  defp ledger(s, key), do: Map.get(s.thermal, key, 0.0)

  defp program(id),
    do:
      Enum.find(@ir["samples"], &(&1["id"] == id))["program_hex"] |> Base.decode16!(case: :lower)

  defp sample(id), do: Enum.find(@quotes["presets"], &(&1["id"] == id))["quote"]

  # 〈取〉程序（设计 §11.4.1）：version 2、kind 0、n_act 1、下标 0、`energy_j` 槽 dec（m·10^e，e 尽量小）。
  defp draw(energy_j) do
    e = Enum.find(0..15, &(rem(energy_j, 10 ** &1) == 0 and div(energy_j, 10 ** &1) <= 4095))
    <<2, 0, 1, 0::16, e::4, div(energy_j, 10 ** e)::12>>
  end

  # 眼睛指向目标微格中心的单位方向（与客户端准星同一表示）。
  defp aim(a, {x, y, z}) do
    {ex, ey, ez} = a.eye
    {dx, dy, dz} = {(x + 0.5) / 8 - ex, (y + 0.5) / 8 - ey, (z + 0.5) / 8 - ez}
    n = :math.sqrt(dx * dx + dy * dy + dz * dz)
    {dx / n, dy / n, dz / n}
  end

  defp query(a, micro) do
    seq = next()

    %{
      request_id: seq,
      client_intent_seq: seq,
      logical_scene_id: 1,
      action: 0,
      tool_id: 1,
      direction: aim(a, micro),
      micro: micro,
      granularity: 0,
      incarnation: 0,
      owner: {0, 0},
      material: 0
    }
  end

  # 0x82 解码形：目标身份先经工具查询取得（与客户端命中同一射线；查询者须在工具射程内），方向由施法者瞄准。
  defp request(c, micro, bytes, opts) do
    scout = Keyword.get(opts, :scout, c.a)
    {:ok, target} = World.tool_intent(c.w, scout, query(scout, micro))
    seq = Keyword.get(opts, :seq, next())

    %{
      request_id: seq,
      client_intent_seq: seq,
      logical_scene_id: 1,
      action: Keyword.get(opts, :action, 1),
      catalog_digest: Keyword.get(opts, :digest, c.digest),
      direction: Keyword.get(opts, :direction, aim(c.a, micro)),
      program: bytes
    }
    |> Map.merge(Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
  end

  defp ingress(c, at), do: Map.merge(c.a, %{received_us: at, clock_node: node()})

  # 正式入口：报价直接返回；施放在前摇出现后投递出手授权（`TestSupport.spell/3`）。
  defp spell(c, micro, bytes, opts \\ []) do
    request = request(c, micro, bytes, opts)
    at = Keyword.get(opts, :at, request.client_intent_seq * 1_000_000)
    VoxelRegion.TestSupport.spell(c.w, ingress(c, at), request)
  end

  # 测试进程充当 Player：以当前角色快照发 prepare_cast，World 的前摇计划与检查结果回到本进程。
  defp prepare(c, micro, bytes, at, opts \\ []) do
    request = request(c, micro, bytes, opts)
    actor = snapshot(c, at)
    key = {actor.identity, request.client_intent_seq}
    ref = make_ref()
    send(c.w, {:prepare_cast, key, actor, request, {self(), ref}})
    assert_receive {:cast_prepared, ^key, plan}, 5_000
    %{key: key, ref: ref, request: request, plan: plan}
  end

  defp snapshot(c, at) do
    {:ok, current} = Actor.tool_context(c.a.player, c.a.identity)
    Map.merge(current, %{received_us: at, clock_node: node(), player: self()})
  end

  defp check(c, cast, at), do: send(c.w, {:check_cast, cast.key, snapshot(c, at), cast.request})

  defp authorize(c, cast, at, request \\ nil),
    do: send(c.w, {:authorize_cast, cast.key, snapshot(c, at), request || cast.request})

  defp reply(cast) do
    ref = cast.ref
    assert_receive {^ref, reply}, 5_000
    reply
  end

  # 施法的可观测事件是 info 级（决策稿 §8）；测试配置默认只留 warning，这里临时放开并捕获。
  defp info_log(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log([level: :info], fun)
    after
      Logger.configure(level: previous)
    end
  end

  defp subscribe(c) do
    ref = make_ref()
    :ok = World.canonical_snapshot_and_subscribe(c.w, @box, self(), ref)
    assert_receive {:canonical_snapshot, ^ref, _}, 5_000
  end

  # 订阅之后本施法者的第一条已结算施放记录（live 0）。热提交可能在其间推进 seq，所以按记录等，不按 seq。
  defp assert_settled(record) do
    assert_receive {:canonical_delta, %{transaction: %{casts: %{@cid => %{live: 0} = settled}}}},
                   5_000

    assert settled == record
  end

  # 余额 = 0.9·R − 560.75 J 的〈取〉（R 为请求取能量，目录 η 0.9，构型损耗取报价样本 draw_1mj 的 total）。
  defp fund(c, request_j, at) do
    assert {:ok, %{outcome: nil}} = spell(c, @stone_micro, draw(request_j), at: at)
    energy(c)
  end

  test "W-1 〈取〉1 MJ：施法者得 η·ΔE 并付构型损耗、石减 1 MJ、取能损耗落石格、构型损耗留脚下；账闭合", c do
    draw = sample("draw_1mj")
    loss_j = draw["total_mj"] / 1000
    before = observe(c.w)

    assert {:ok, %{outcome: nil, seq: seq, caster: caster}} =
             spell(c, @stone_micro, program("draw_1mj"))

    # 前摇开始事务 before.seq + 1（只带施放记录），结算事务 before.seq + 2。
    assert seq == before.seq + 2
    s = observe(c.w)

    # ΔE = min(1 MJ, 10 MJ, 5 MJ − 0) = 1 MJ；得 0.9 MJ；付报价 560.75 J（附录 A.12：260.75 + 出手前置 300）。
    assert_in_delta caster.energy_j, 900_000.0 - loss_j, 1.0e-6
    assert_in_delta caster.spent_j, loss_j, 1.0e-9
    assert_in_delta caster.quote_j, loss_j, 1.0e-9
    assert {caster.quote_s, caster.capacity_j, caster.resolution_eff} == {1.0, 5.0e6, 16.0}
    # 结算后的状态只带前 73 B（扩展段为 0）。
    assert {caster.quote_windup_s, caster.fail_step, caster.rejects} == {0.0, 0, []}
    assert battery(s).stored_j == 9.0e6
    assert_in_delta ledger(s, :caster_drawn_j), 900_000.0, 1.0e-6
    assert_in_delta ledger(s, :draw_loss_j), 100_000.0, 1.0e-6
    assert_in_delta ledger(s, :cast_waste_j), loss_j, 1.0e-9

    assert_in_delta ledger(s, :caster_drawn_j) + ledger(s, :draw_loss_j),
                    1.0e7 - battery(s).stored_j,
                    1.0e-6

    # 有限热源：石格 0.1 MJ、脚下 560.75 J。
    assert_in_delta s.thermal.sources[{2, 1, 0}].remaining_j, 100_000.0, 1.0e-6
    assert_in_delta s.thermal.sources[{0, 0, 0}].remaining_j, loss_j, 1.0e-9
  end

  test "报价（action 0）：0x83 v2 全字段，不改世界、不占施法间隔；〈取〉只填 fail_step 与 rejects，结构填扩展段", c do
    seq = World.seq(c.w)

    assert {:ok, %{outcome: nil, caster: q}} =
             spell(c, @stone_micro, program("draw_1mj"), action: 0)

    draw = sample("draw_1mj")
    assert_in_delta q.quote_j, draw["total_mj"] / 1000, 1.0e-9
    assert_in_delta q.quote_windup_s, draw["windup_s"], 1.0e-6

    # 余额 0，但〈取〉的构型损耗暂从取得的能量里付（决策稿 §14 末条待定，暂按 v1）：目标是满石，不预判中断。
    assert {q.quote_s, q.spent_j, q.fail_step, q.rejects, q.x0, q.life_s} ==
             {1.0, 0.0, 0, [], 0.0, 0.0}

    # 结构（灯，〈握〉）：扩展段来自同一报价；余额 0 < 第 1 步累计支出 → fail_step 1。
    assert {:ok, %{caster: lamp}} = spell(c, @leaf_micro, program("lamp"), action: 0)
    assert_in_delta lamp.quote_j, sample("lamp")["total_mj"] / 1000, 1.0e-9
    assert {lamp.quote_s, lamp.fail_step, lamp.rejects} == {2.0, 1, []}
    assert lamp.x0 > 0 and lamp.life_s > 0 and lamp.e_min_j > 0 and lamp.first_tick_min_j > 0
    assert World.seq(c.w) == seq
    assert observe(c.w).casts == %{}
  end

  # 若出手仍复用前摇开始时的报价（3.0 m 内、无违规），这次施放会错误地成功取能。
  test "W-9 出手按当时 site 重新报价：前摇中移出施法域、改向仍瞄准石 → rejects:domain、outcome 2，余额与石储能不变", c do
    subscribe(c)
    cast = prepare(c, @stone_micro, program("draw_1mj"), 1_000_000)
    assert cast.plan.checkpoint_s == nil

    # 正常移动：脚 (−4.5, 1, 0.5)、眼 (−4.5, 2.5, 0.5)，到石 A 格心 √50 ≈ 7.07 m > 6 m；客户端改向（action 3）后仍瞄准石 A。
    :ok = GenServer.call(c.a.player, {:pose, {-4.5, 2.5, 0.5}, {-4.5, 1.0, 0.5}})
    {:ok, moved} = Actor.tool_context(c.a.player, c.a.identity)

    log =
      info_log(fn ->
        authorize(c, cast, 1_000_000, %{cast.request | direction: aim(moved, @stone_micro)})
        assert reply(cast) == {:error, {:rejects, [:domain]}}
      end)

    assert log =~ "voxel_cast_rejected" and log =~ "phase=release" and log =~ "rejects=domain"
    assert log =~ "voxel_spell_quote" and log =~ "phase=release"
    assert_settled(%{live: 0, outcome: 2, fail_step: 0})
    assert energy(c) == 0.0
    assert battery(observe(c.w)).stored_j == 1.0e7
  end

  test "W-10 施法域只由 T6 判：9.06 m 的石报价回 rejects [:domain]、施放回 rejects:domain；瞄天空回 :no_target", c do
    scout = actor(2002, {6.5, 2.5, 0.5}, {6.5, 1.0, 0.5})
    seq = World.seq(c.w)

    assert {:ok, %{caster: q}} =
             spell(c, @far_micro, program("draw_1mj"), action: 0, scout: scout)

    assert q.rejects == [:domain]
    assert_in_delta q.quote_j, sample("draw_1mj")["total_mj"] / 1000, 1.0e-9

    assert {:error, {:rejects, [:domain]}} =
             spell(c, @far_micro, program("draw_1mj"), scout: scout, at: 1_000_000)

    for action <- [0, 1] do
      assert {:error, :no_target} =
               spell(c, @stone_micro, program("draw_1mj"),
                 action: action,
                 direction: {0.0, 1.0, 0.0},
                 at: 2_000_000
               )
    end

    assert World.seq(c.w) == seq
    assert energy(c) == 0.0
  end

  # W1 路径一：前摇开始时预判出第 k 步中断，到 t_k 时仍中断 → 在第 k 步结算。〈附〉的形成格是叶（未细分热节点），
  # 支出按 release_heat_fraction 0.5 一半作为有限热源落在叶格、一半计入辐射账（W7）。
  test "W1/W7 第 k 步时刻仍失败：灼点在第 2 步余额耗尽，t_2 检查即结算 interrupted_energy，扣光余额，一半热落叶格", c do
    # R = 1734 J → 余额 0.9·1734 − 560.75 ≈ 999.85 J：够付第 1 步〈附〉（337.711 J），不够第 2 步〈形〉（1203.902 J）。
    balance = fund(c, 1734, 1_000_000)
    [anchor, form | _] = sample("scorch")["steps"]
    assert balance * 1000 >= anchor["spent_mj"] and balance * 1000 < form["spent_mj"]
    subscribe(c)

    cast = prepare(c, @leaf_micro, program("scorch"), 2_000_000)
    assert_in_delta cast.plan.windup_s, sample("scorch")["windup_s"], 1.0e-6

    assert_in_delta cast.plan.checkpoint_s,
                    anchor["adjust_s"] + anchor["inject_s"] + form["adjust_s"] + form["inject_s"],
                    1.0e-6

    check(c, cast, 2_000_000)
    assert {:ok, %{outcome: :interrupted_energy, caster: caster}} = reply(cast)
    key = cast.key
    assert_receive {:cast_checked, ^key, :ended}
    assert_settled(%{live: 0, outcome: 1, fail_step: 2})
    # 余额耗尽：扣到 0（整数 mJ 向零取整，余额只剩不足 1 mJ 的零头）。
    assert_in_delta caster.spent_j, balance, 1.0e-3
    assert_in_delta energy(c), 0.0, 1.0e-3
    s = observe(c.w)
    assert_in_delta s.thermal.sources[{0, 2, 3}].remaining_j, caster.spent_j * 0.5, 1.0e-3

    assert_in_delta ledger(s, :cast_interrupt_heat_j) + ledger(s, :cast_interrupt_radiation_j),
                    caster.spent_j,
                    1.0e-9

    assert_in_delta ledger(s, :cast_interrupt_radiation_j), caster.spent_j * 0.5, 1.0e-3

    # 成功施法的构型损耗才留脚下：中断不进 cast_waste_j（只含前面那次取能）。
    assert_in_delta ledger(s, :cast_waste_j), sample("draw_1mj")["total_mj"] / 1000, 1.0e-9
  end

  # W1 路径二：预判中断（Ω_eff 0.8 < 第 1 步 S·P 1），到 t_1 时身体系数已恢复 → 继续，出手照常建成。
  test "W1 第 k 步时刻条件好转：〈取〉预判第 1 步分辨不足，t_1 检查回 continue，出手成功取能", c do
    :ok = GenServer.call(c.a.player, {:coherence, 0.05})
    cast = prepare(c, @stone_micro, program("draw_1mj"), 1_000_000)
    assert_in_delta cast.plan.checkpoint_s, hd(sample("draw_1mj")["steps"])["adjust_s"], 1.0e-6

    :ok = GenServer.call(c.a.player, {:coherence, 1.0})
    check(c, cast, 1_000_000)
    key = cast.key
    assert_receive {:cast_checked, ^key, :continue}
    refute_received {_, {:ok, _}}

    authorize(c, cast, 1_000_000)
    assert {:ok, %{outcome: nil}} = reply(cast)
    assert_in_delta energy(c), 900_000.0 - sample("draw_1mj")["total_mj"] / 1000, 1.0e-6
    assert battery(observe(c.w)).stored_j == 9.0e6
  end

  # W1 路径三：前摇开始时无预判，出手时 Ω_eff 已降到 0.8 → 在出手时结算第 1 步中断；〈取〉的取能不发生，扣费以余额为限，
  # 手边点是空气 → 全部计入辐射账（W7）。
  test "W1 只在出手时中断：〈取〉出手时分辨不足 → interrupted_omega、fail_step 1，扣第 1 步支出、石不变、全部辐射", c do
    balance = fund(c, 1_000_000, 1_000_000)
    subscribe(c)
    cast = prepare(c, @stone_micro, program("draw_1mj"), 2_000_000)
    assert cast.plan.checkpoint_s == nil

    :ok = GenServer.call(c.a.player, {:coherence, 0.05})
    authorize(c, cast, 2_000_000)
    assert {:ok, %{outcome: :interrupted_omega, caster: caster}} = reply(cast)
    assert_settled(%{live: 0, outcome: 1, fail_step: 1})
    loss_j = sample("draw_1mj")["total_mj"] / 1000
    assert_in_delta caster.spent_j, loss_j, 1.0e-9
    assert_in_delta caster.resolution_eff, 0.8, 1.0e-12
    assert_in_delta energy(c), balance - loss_j, 1.0e-6
    s = observe(c.w)
    assert battery(s).stored_j == 9.0e6
    assert_in_delta ledger(s, :cast_interrupt_radiation_j), loss_j, 1.0e-9
    assert ledger(s, :cast_interrupt_heat_j) == 0.0
  end

  test "P7 报价限频：同一施法者 1 s 内第 5 次报价回 :quote_rate，不改世界", c do
    replies = for _ <- 1..5, do: spell(c, @stone_micro, program("draw_1mj"), action: 0)
    assert [{:ok, _}, {:ok, _}, {:ok, _}, {:ok, _}, {:error, :quote_rate}] = replies
    assert observe(c.w).casts == %{}
  end

  test "拒绝不扣能量、不改世界：施法过快、目录过期、程序非法（带上下文日志）、目标不是蓄能石、他人地块", c do
    fund(c, 1_000_000, 1_000_000)
    seq = World.seq(c.w)
    energy = energy(c)
    unchanged = fn seq -> assert {World.seq(c.w), energy(c)} == {seq, energy} end

    # 施法过快：间隔 500 ms，上一笔在 1.0 s → 1.1 s 被拒。
    assert {:error, :cast_too_soon} = spell(c, @stone_micro, program("draw_1mj"), at: 1_100_000)

    assert {:error, :stale_magic_catalog} =
             spell(c, @stone_micro, program("draw_1mj"), at: 2_000_000, digest: <<0::256>>)

    v1 =
      ~s({"v":1,"target":{"kind":"aim"},"emit":"at_target","steps":[{"sym":"energy.draw","args":{"energy_j":1000000}}]})

    log =
      capture_log(fn ->
        assert {:error, :invalid_program} = spell(c, @stone_micro, v1, at: 3_000_000)
      end)

    assert log =~ "voxel_magic_program_rejected cid=#{@cid}" and log =~ "reason={:version, 123}"
    refute log =~ "voxel_cast_rejected"
    assert {:error, :invalid_target} = spell(c, @leaf_micro, program("draw_1mj"), at: 4_000_000)
    unchanged.(seq)

    # 他人（cid 2002）认领叶所在列：〈附〉的目标格在他人地块 → protected_region。
    {:ok, _} =
      World.author_regions(c.w, [%{holder: {:character, 2002}, min: {0, 3}, max: {0, 3}}])

    seq = World.seq(c.w)
    assert {:error, :protected_region} = spell(c, @leaf_micro, program("scorch"), at: 5_000_000)
    unchanged.(seq)
  end

  test "冷重启：施法者能量随日志重放与检查点保留；不自动回复", c do
    balance = fund(c, 1_000_000, 1_000_000)
    w = restart(c)
    c = %{c | w: w}
    assert energy(c) == balance
    assert battery(observe(w)).stored_j == 9.0e6
    assert :ok = World.compact(w)
    w = restart(c)
    c = %{c | w: w}
    assert energy(c) == balance
    assert {:ok, %{energy_j: +0.0}} = World.caster_state(w, 2002)
  end

  # ---------------------------------------------------------------------------
  # 切片 6：取消与打断结账、结算回复带 fail_step（决策稿 §6.1、§13 W6-5、W6-6、Q6-1、Q6-4；设计 §5.5、§14.0 Q6）
  # 测试进程充当 Player：k 由真实 Player 按已流逝时间求出（scene_server 用例覆盖），这里直接给 k。
  # ---------------------------------------------------------------------------

  test "W6-5 第一笔注能前取消（k = 0）免费：outcome 2、不扣能、等待方收到打断原因", c do
    balance = fund(c, 1_000_000, 1_000_000)
    subscribe(c)
    cast = prepare(c, @leaf_micro, program("lamp"), 2_000_000)
    # 前摇计划带已广播的各步时长（Player 求 k 用），与报价样本一致。
    assert length(cast.plan.steps) == length(sample("lamp")["steps"])

    send(c.w, {:cancel_cast, cast.key, :interrupted_moved, 0})
    assert {:error, :interrupted_moved} = reply(cast)
    assert_settled(%{live: 0, outcome: 2, fail_step: 0})
    assert energy(c) == balance
    assert observe(c.w).casts == %{}
  end

  test "W6-5/W6-6 前摇进行到第 2 步时取消（k = 2）：outcome 1、fail_step 2，扣第 1–2 步累计支出并落在形成处（W7）", c do
    balance = fund(c, 1_000_000, 1_000_000)
    subscribe(c)
    cast = prepare(c, @leaf_micro, program("lamp"), 2_000_000)
    request = cast.request
    before = observe(c.w)

    send(c.w, {:cancel_cast, cast.key, :interrupted_cancelled, 2})
    # 期望取报价样本：灯第 2 步〈形〉的累计支出 870 689 mJ（Q6-1：按进行中的步 k 扣第 1..k 步，与分阶段失败同一口径）。
    charge_j = Enum.at(sample("lamp")["steps"], 1)["spent_mj"] / 1000
    assert {:ok, %{outcome: :interrupted_cancelled, fail_step: 2, caster: caster} = settled} = reply(cast)
    assert_in_delta caster.spent_j, charge_j, 1.0e-9
    assert_settled(%{live: 0, outcome: 1, fail_step: 2})
    # 余额未被扣光：只付到第 2 步。
    assert_in_delta energy(c), balance - charge_j, 1.0e-6
    # 结算回复也经施法者的连接下发（0x83 带实际扣除、0x68 accepted 原因串即 outcome）。
    assert_receive {:mmo_spell_reply, _, ^request, ^settled}, 1_000
    # 〈握〉的形成位置是手边点所在格（空气）：全部支出计入辐射账（W7）。
    s = observe(c.w)
    assert_in_delta ledger(s, :cast_interrupt_radiation_j) - ledger(before, :cast_interrupt_radiation_j), charge_j, 1.0e-9
    assert observe(c.w).casts == %{}
  end

  test "验收 3/W6-6 分辨不足在第 k 步中断：报价的 fail_step 与结算一致，扣第 1..k 步、余额未被扣光；回复带 fail_step", c do
    balance = fund(c, 1_000_000, 1_000_000)
    subscribe(c)
    # Ω_eff = 16 × 0.1 = 1.6：灯各步累计 S·P 为 0、1、2、2（报价样本），第 3 步超过 → fail_step 3。
    :ok = GenServer.call(c.a.player, {:coherence, 0.1})
    assert {:ok, %{caster: quoted}} = spell(c, @leaf_micro, program("lamp"), action: 0, at: 2_000_000)
    assert quoted.fail_step == 3

    cast = prepare(c, @leaf_micro, program("lamp"), 3_000_000)
    check(c, cast, 3_000_000)
    assert {:ok, %{outcome: :interrupted_omega, fail_step: 3, caster: caster}} = reply(cast)
    assert_settled(%{live: 0, outcome: 1, fail_step: 3})
    charge_j = Enum.at(sample("lamp")["steps"], 2)["spent_mj"] / 1000
    assert_in_delta caster.spent_j, charge_j, 1.0e-9
    assert_in_delta energy(c), balance - charge_j, 1.0e-6
    assert energy(c) > 0
  end

  test "W6-6 建成的结算回复带 fail_step 0", c do
    fund(c, 1_000_000, 1_000_000)
    assert {:ok, %{outcome: nil, fail_step: 0}} = spell(c, @leaf_micro, program("lamp"), at: 2_000_000)
  end
end
