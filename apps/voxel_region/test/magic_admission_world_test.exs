defmodule VoxelRegion.MagicAdmissionWorldTest do
  @moduledoc """
  只测试：魔法 v2 切片 7 的分区准入在真实 World 里的判定（决策稿 `docs/10-active/magic/2026-11-26-p1-closure-slices4-8.md`
  §7、§13 W7-1–W7-3、W7-5；落地稿 D8；设计 TheWorldBook `docs/2026-11-19-glyph-composition-game-design.md` §5.6、§5.7）。

  - 契约：`World.MagicAdmission` 是准入的唯一 owner，用量从运行中结构现算；拒绝为 `:structure_quota`、`:flight_quota`、
    `:region_budget`，不扣能、不改世界。在场只经公共 API `World.caster_presence/3` 推送，推送进程退出即移出。
  - 场景同 `magic_structure_world_test.exs`（Y-up，1 宏格 = 1 m）：地面石铺 y = 0，蓄能石 (2,1,0) 经持久化边界装 10 MJ，
    每个施法者站在同一处 (0.5, 1.0, 0.5)，经正式〈取〉入口各取 1 MJ。结构全部经 `World.spell_intent/3` 施放：灯（权重 1）、
    法杖光弹（无质量〈投〉，飞行中）。
  - 数据：W7-1 用发布目录原值（每人 6 个结构、3 个飞行，Q7-5）。W7-2、W7-3、W7-5 与分区飞行名额用 **probe 目录**：从发布
    目录只改 `quotas` 的几个数（`@tag quotas:`），把分区预算缩小到十几个灯就能达到 75% 线；规则、代码路径与权重同生产。
    在 256 单位的发布值下要几十个施法者，与本测试要证伪的分支无关（AGENTS §3-14）。
  - 驱动：手动时钟（不自动热提交、不自动飞行）；飞行与热拍只在用例显式推进时发生。
  - 期望：都是 §5.6 规则推出的准入结论与用量，不复制 `MagicAdmission` 的算式。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.{OverlayLog, World}
  alias VoxelRegion.TestSupport.{Actor, Log, Source}

  @properties "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  @fixtures Path.expand("fixtures", __DIR__)
  @catalog Path.expand("../priv/magic", __DIR__) |> Path.join("*.json") |> Path.wildcard() |> then(fn [path] -> path end)
  @ir Path.join(@fixtures, "magic/ir-v2-samples.json") |> File.read!() |> Jason.decode!()
  @external_resource @catalog
  @stone 11
  @leaf 28
  @battery 42
  @box {{-2, -2, -2}, {2, 2, 2}}
  @simulation_box {{-8, 0, -2}, {12, 3, 5}}
  @stone_micro {20, 12, 4}
  @leaf_micro {4, 20, 28}

  defmodule FlightClock do
    @moduledoc "只测试：服务器时间线的注入单调时钟（µs），由测试推进。"
    def now(agent), do: Agent.get(agent, & &1)
  end

  defmodule ManualClock do
    @moduledoc "只测试：不推进的时钟，热提交与投射物拍只由测试显式投递。"
    @behaviour VoxelRegion.World.Clock
    @impl true
    def now(_), do: 0
    @impl true
    def schedule(_, _, _, _), do: make_ref()
    @impl true
    def cancel(_, _), do: false
  end

  setup context do
    root = Path.join(System.tmp_dir!(), "admission_world_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.cp!(Path.join([@fixtures, "combustion", @properties <> ".json"]), Path.join(root, "properties.json"))
    File.cp!(Path.join([@fixtures, "combustion", "environment-radiation.json"]), Path.join(root, "environment.json"))
    write_catalog(root, Map.get(context, :quotas, %{}))
    w = start(root)
    ground = for x <- -8..12, z <- -2..4, do: {{x, 0, z}, @stone}
    {:ok, _} = World.apply_edits(w, ground ++ [{{2, 1, 0}, @battery}, {{0, 2, 3}, @leaf}])
    scout = caster(%{cid: 9, controller: :player, root: root})
    {:ok, row} = World.tool_intent(w, scout, query(scout, @stone_micro))
    seq = World.seq(w)
    :ok = stop_supervised(:world)

    OverlayLog.File.append(Path.join(root, "overlay.log"), %{
      seq: seq + 1,
      entries: [],
      coarse: [],
      property_states: [Map.merge(row, %{stored_j: 1.0e7, seq: seq + 1, request_id: 0})]
    })

    clock = start_supervised!({Agent, fn -> 1_000_000_000 end}, id: :flight_clock)
    w = start(root, clock)
    :ok = VoxelRegion.TestSupport.activate_simulation(w, @simulation_box)
    %{w: w, root: root, clock: clock, digest: :crypto.hash(:sha256, File.read!(Path.join(root, "magic.json")))}
  end

  # probe 目录：发布目录只改 `quotas` 的给定字段（其余字节语义不变；digest 随之不同，请求按它填）。
  defp write_catalog(root, quotas) when quotas == %{}, do: File.cp!(@catalog, Path.join(root, "magic.json"))

  defp write_catalog(root, quotas) do
    catalog = @catalog |> File.read!() |> Jason.decode!()
    File.write!(Path.join(root, "magic.json"), Jason.encode!(update_in(catalog["quotas"], &Map.merge(&1, quotas))))
  end

  defp start(root, clock \\ nil) do
    opts =
      [
        source: Source,
        log: Log,
        root: root,
        observer: self(),
        name: nil,
        clock: {ManualClock, nil},
        property_catalog_path: Path.join(root, "properties.json"),
        thermal_environment_path: Path.join(root, "environment.json"),
        magic_catalog_path: Path.join(root, "magic.json")
      ] ++ if(clock, do: [server_clock: {FlightClock, clock}], else: [])

    start_supervised!({World, opts}, id: :world)
  end

  # 施法者：同一站位，`controller` 为 :player 或 :npc；进程是会话 owner 替身（`TestSupport.Actor`）。
  defp caster(%{cid: cid, controller: controller}) do
    a = %{cid: cid, controller: controller, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2,
      eye: {0.5, 2.5, 0.5}, feet: {0.5, 1.0, 0.5}, tick_us: 16_667}

    Map.put(a, :player, start_supervised!({Actor, a}, id: {:actor, cid}))
  end

  defp present(c, a, status \\ :present), do: :ok = GenServer.call(a.player, {:presence, c.w, status})

  defp aim(a, {x, y, z}) do
    {ex, ey, ez} = a.eye
    {dx, dy, dz} = {(x + 0.5) / 8 - ex, (y + 0.5) / 8 - ey, (z + 0.5) / 8 - ez}
    n = :math.sqrt(dx * dx + dy * dy + dz * dz)
    {dx / n, dy / n, dz / n}
  end

  defp next, do: System.unique_integer([:positive, :monotonic])

  defp query(a, micro) do
    seq = next()

    %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 0, tool_id: 1, direction: aim(a, micro),
      micro: micro, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
  end

  # 施放一次：`at` 是 Gate 入口时刻（µs，同一施法者的施法间隔 GCRA 按它判），`direction` 缺省瞄向 `micro`。
  defp spell(c, a, micro, bytes, at, direction \\ nil) do
    {:ok, target} = World.tool_intent(c.w, a, query(a, micro))
    seq = next()

    request =
      %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 1, catalog_digest: c.digest,
        direction: direction || aim(a, micro), program: bytes}
      |> Map.merge(Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))

    VoxelRegion.TestSupport.spell(c.w, Map.merge(a, %{received_us: at, clock_node: node()}), request)
  end

  defp program(id), do: Enum.find(@ir["samples"], &(&1["id"] == id))["program_hex"] |> Base.decode16!(case: :lower)

  # 〈取〉1 MJ（设计 §11.4.1：kind 0、下标 0、`energy_j` 槽 dec，1000 × 10³）。
  defp fund(c, a, at), do: assert({:ok, %{outcome: nil}} = spell(c, a, @stone_micro, <<2, 0, 1, 0::16, 3::4, 1000::12>>, at))

  defp lamp(c, a, at), do: spell(c, a, @leaf_micro, program("lamp"), at)
  defp bolt(c, a, at), do: spell(c, a, @leaf_micro, program("staff_bolt_massless"), at, {1.0, 0.0, 0.0})

  # n 个灯，施法间隔 1 s（入口时刻从 `from` 起）；每个都必须建成。
  defp lamps(c, a, n, from) do
    for k <- 1..n//1, do: assert({:ok, %{outcome: nil}} = lamp(c, a, from + k * 1_000_000))
  end

  defp admission(c), do: World.stats(c.w).magic_admission
  defp energy(c, cid), do: elem(World.caster_state(c.w, cid), 1).energy_j
  defp structures(c), do: VoxelRegion.TestSupport.observe(c.w, [], @box).structures

  # 拒绝不扣能、不改世界：seq 与余额都不变。
  defp assert_rejected(c, a, reason, fun) do
    before = {World.seq(c.w), energy(c, a.cid)}
    assert {:error, ^reason} = fun.()
    assert {World.seq(c.w), energy(c, a.cid)} == before
  end

  defp fly(c, seconds) do
    Agent.update(c.clock, &(&1 + round(seconds * 1_000_000)))
    send(c.w, :projectile_tick)
    await(fn -> VoxelRegion.TestSupport.projectiles_settled?(c.w) end)
  end

  defp commit(c) do
    before = Map.get(VoxelRegion.TestSupport.observe(c.w, [], @box).thermal, :commit_tick, 0)
    send(c.w, :thermal_commit)
    await(fn -> Map.get(VoxelRegion.TestSupport.observe(c.w, [], @box).thermal, :commit_tick, 0) > before end)
  end

  defp await(fun) do
    Enum.reduce_while(1..500, nil, fn _, _ ->
      if fun.(), do: {:halt, :ok}, else: (Process.sleep(10); {:cont, nil})
    end)
    |> then(&assert(&1 == :ok, "5 s 内未达成等待条件"))
  end

  defp flying(c), do: Enum.count(structures(c), fn {_, r} -> :flying in r.status end)

  test "W7-1 / Q7-5 法杖按住连发：间隔 0.5 s，3 发同时在飞都准入；同一刻再按第 4 发 :flight_quota，不扣能", c do
    a = caster(%{cid: 1001, controller: :player})
    present(c, a)
    fund(c, a, 1_000_000)

    # 发射间隔 0.5 s（目录 `cast_interval_ms`），每次之间飞 0.5 s、走一个热拍：第 3 发出手时前两发仍在飞（单发飞行
    # (1.0, 1.5] s，第 3 拍才衰竭，决策稿 §14 切片 5b）。
    for k <- 0..2 do
      if k > 0 do
        fly(c, 0.5)
        commit(c)
      end

      assert {:ok, %{outcome: nil}} = bolt(c, a, 2_000_000 + k * 500_000)
      assert flying(c) == k + 1
    end

    assert admission(c).casters[1001].flights == 3
    assert_rejected(c, a, :flight_quota, fn -> bolt(c, a, 3_500_000) end)
    # 飞行名额只数飞行中的：同一施法者此刻仍能放不飞的灯（6 个结构上限未到）。
    assert {:ok, %{outcome: nil}} = lamp(c, a, 4_000_000)
  end

  @tag quotas: %{"region_budget_units" => 8, "region_reserve_units" => 2}
  test "W7-2 分区预算（probe B = 8、R = 2）：75% 线以下照常；以上按在场人数分份额；在场者保底 1 个用预留；超过 B + R 一律拒", c do
    [a, b, d, e, f] = for cid <- [1001, 1002, 1004, 1005, 1006], do: caster(%{cid: cid, controller: :player})
    absent = caster(%{cid: 1003, controller: :player})
    for x <- [a, b, d, e, f], do: present(c, x)
    for {x, k} <- Enum.with_index([a, b, absent, d, e, f]), do: fund(c, x, 1_000_000 + k)

    # 用量 < 75%·B = 6：A 放 5 个灯（按每人 6 个上限之内）、B 放 1 个，照常准入。
    lamps(c, a, 5, 10_000_000)
    lamps(c, b, 1, 10_000_000)
    assert %{usage_units: 6.0, present: [1001, 1002, 1004, 1005, 1006]} = admission(c)

    # 用量 ≥ 6：份额 = 0.75·8 / 5 人 = 1.2。A 已有 5 > 1.2 → 拒；B 已有 1 < 1.2 且 6 + 1 ≤ 8 → 准入。
    assert_rejected(c, a, :region_budget, fn -> lamp(c, a, 20_000_000) end)
    assert {:ok, %{outcome: nil}} = lamp(c, b, 20_000_000)
    # B 已有 2 ≥ 1.2：拒（没有保底：保底只给名下还没有结构的在场者）。
    assert_rejected(c, b, :region_budget, fn -> lamp(c, b, 21_000_000) end)

    # 不在场者没有准入资格（即使名下没有结构）。
    assert_rejected(c, absent, :region_budget, fn -> lamp(c, absent, 20_000_000) end)

    # 在场者保底 1 个：D、E 名下没有结构，用 B 之上的预留准入（7 → 8 → 9 → 10 = B + R）。
    assert {:ok, %{outcome: nil}} = lamp(c, d, 20_000_000)
    assert {:ok, %{outcome: nil}} = lamp(c, e, 20_000_000)
    assert admission(c).usage_units == 9.0
    assert {:ok, %{outcome: nil}} = lamp(c, f, 20_000_000)
    assert admission(c).usage_units == 10.0

    # 硬上限 B + R：再来一个名下没有结构的在场者也拒。
    g = caster(%{cid: 1007, controller: :player})
    present(c, g)
    fund(c, g, 1_000_001)
    assert_rejected(c, g, :region_budget, fn -> lamp(c, g, 20_000_000) end)
  end

  @tag quotas: %{"region_budget_units" => 24, "region_reserve_units" => 4}
  test "W7-3 NPC 配额（probe B = 24）：每个 NPC 至多 4 个；全体 NPC 合计 ≤ 25%·B = 6 单位", c do
    [n1, n2] = for cid <- [2001, 2002], do: caster(%{cid: cid, controller: :npc})
    for {x, k} <- Enum.with_index([n1, n2]), do: fund(c, x, 1_000_000 + k)

    # NPC 不需要在场即可准入（不看在场），每个 NPC 4 个，不是玩家的 6 个。
    lamps(c, n1, 4, 10_000_000)
    assert_rejected(c, n1, :structure_quota, fn -> lamp(c, n1, 20_000_000) end)

    # 合计：4 + 2 = 6 ≤ 6 准入，第 3 个使合计到 7，拒（N2 自己只有 2 个，未到每 NPC 上限）。
    lamps(c, n2, 2, 10_000_000)
    assert_rejected(c, n2, :region_budget, fn -> lamp(c, n2, 20_000_000) end)
    assert %{npc_units: 6.0, npc_budget_units: 6.0, present: []} = admission(c)
  end

  @tag quotas: %{"region_budget_units" => 8, "region_reserve_units" => 2}
  test "W7-3 NPC 不享在场保底与预留（probe B = 8、R = 2）：用量到 B 后 NPC 拒，同样名下为空的在场玩家用预留准入", c do
    n = caster(%{cid: 2001, controller: :npc})
    [a, b, p] = for cid <- [1001, 1002, 1003], do: caster(%{cid: cid, controller: :player})
    for x <- [a, b, p], do: present(c, x)
    for {x, k} <- Enum.with_index([n, a, b, p]), do: fund(c, x, 1_000_000 + k)

    lamps(c, n, 1, 10_000_000)
    lamps(c, a, 5, 10_000_000)
    # 用量 6 ≥ 75%·8：份额 0.75·8 / 3 人 = 2；B 先用保底、再用份额，到 B = 8。
    lamps(c, b, 2, 10_000_000)
    assert %{usage_units: 8.0, npc_units: 1.0} = admission(c)

    # NPC 合计 1 + 1 = 2 ≤ 25%·8，但 8 + 1 > B，NPC 不能用预留：拒。
    assert_rejected(c, n, :region_budget, fn -> lamp(c, n, 20_000_000) end)
    # 名下没有结构的在场玩家用预留保底：8 + 1 ≤ B + R，准入。NPC 的施放没有让它进在场集合。
    assert {:ok, %{outcome: nil}} = lamp(c, p, 20_000_000)
    assert %{usage_units: 9.0, present: [1001, 1002, 1003]} = admission(c)
  end

  @tag quotas: %{"region_budget_units" => 8, "region_reserve_units" => 2}
  test "W7-5 不在场者的结构照常运行并计入用量，但拥挤时没有准入资格；推送进程退出即移出在场（经公共 API）", c do
    [a, b] = for cid <- [1001, 1002], do: caster(%{cid: cid, controller: :player})
    for x <- [a, b], do: present(c, x)
    for {x, k} <- Enum.with_index([a, b]), do: fund(c, x, 1_000_000 + k)
    lamps(c, a, 5, 10_000_000)
    lamps(c, b, 1, 10_000_000)

    # B 会话解除：他的灯照常步进（热拍推进 last_tick）、照常计入用量。
    present(c, b, :absent)
    tick = fn -> Map.get(VoxelRegion.TestSupport.observe(c.w, [], @box).thermal, :commit_tick, 0) end
    commit(c)
    assert map_size(structures(c)) == 6
    assert %{usage_units: 6.0, present: [1001]} = admission(c)
    assert tick.() >= 1

    # 用量 6 ≥ 6：只有 A 在场，份额 0.75·8 / 1 = 6，A 已有 5 < 6 → 准入；B 不在场 → 拒。
    assert_rejected(c, b, :region_budget, fn -> lamp(c, b, 20_000_000) end)
    # B 重新就绪：份额 0.75·8 / 2 = 3，B 有 1 < 3 → 准入。
    present(c, b)
    assert {:ok, %{outcome: nil}} = lamp(c, b, 21_000_000)

    # 会话 owner 进程退出（没有推 :absent）：World 的监视移出在场，不留陈旧条目。
    :ok = stop_supervised({:actor, 1002})
    await(fn -> admission(c).present == [1001] end)
  end

  @tag quotas: %{"region_flight_slots_base" => 1}
  test "分区飞行名额（probe base = 1）：在场者各有 1 个保底，其余共享部分先到先得（Q7-4）；NPC 只用共享部分", c do
    [p1, p2] = for cid <- [1001, 1002], do: caster(%{cid: cid, controller: :player})
    npc = caster(%{cid: 2001, controller: :npc})
    for x <- [p1, p2], do: present(c, x)
    for {x, k} <- Enum.with_index([p1, p2, npc]), do: fund(c, x, 1_000_000 + k)

    # 名额 = 1 + 2 人：P1 第 1 发用保底、第 2 发用共享的 1 个；第 3 发共享已满（自己的 3 个飞行上限未到）。
    assert {:ok, %{outcome: nil}} = bolt(c, p1, 2_000_000)
    assert {:ok, %{outcome: nil}} = bolt(c, p1, 3_000_000)
    assert_rejected(c, p1, :region_budget, fn -> bolt(c, p1, 4_000_000) end)
    # P2 的保底不被 P1 占走。
    assert {:ok, %{outcome: nil}} = bolt(c, p2, 2_000_000)
    # NPC 没有保底：共享已满即拒。
    assert_rejected(c, npc, :region_budget, fn -> bolt(c, npc, 2_000_000) end)
    assert %{flights: 3, flight_slots: 3} = admission(c)
  end
end
