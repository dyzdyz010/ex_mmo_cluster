defmodule VoxelRegion.MagicWorldTest do
  @moduledoc """
  只测试：魔法增量 1 在真实 World 里的取能、远程点火、走火、拒绝与持久化（Voxim Docs/Magic.md §4、§10）。

  目录：材料 `b1aca503…`（UE 发布字节：蓄能石 42 每宏格 10 MJ、叶 28 热容 1200 J/K 燃点 523.15 K），
  魔法 `ff15757b…`（Test-only 手写，结构与数值同契约初版）；热环境 = 生产 ε 0.9。
  场景（Y-up，1 宏格 = 1 m）：地面石 11 铺 y = 0；施法者脚 (0.5, 1.0, 0.5) → 脚下宏格 (0,0,0)，眼 (0.5, 2.5, 0.5)；
  蓄能石 (2,1,0) 立在地上（眼到格心 √5 ≈ 2.24 m）；孤立叶 (0,2,3) 悬空（眼到格心 3 m，射线沿 +z 先经两格空气）；
  远叶 (7,2,0)（眼到格心 7 m > 施法域 6 m）。
  蓄能石的 10 MJ 储能：新蓄能石为空，只能由热电石回路充电（约 0.4 kW，10 MJ 需数小时模拟），单测无法经正常玩法建立；
  这里作为冷启动恢复的作者初态，经持久化边界（文件日志追加一笔带 stored_j 的属性事务）安装一次，之后只经正式施法入口变化。
  期望值全部按契约公式手算，写在断言旁；不取自被测函数（构型损耗按前摇契约 §2 手算表：取能 1053.7222 J、
  点火 0.4 MJ 2292.5446 J、点火 0.3 MJ 1986.4898 J）。施放先进入前摇（开始事务 + 结算事务，seq 各 +1），
  测试经 `TestSupport.spell/3` 在待施放出现后直接投递到期消息，不等墙钟。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.{World, OverlayLog}
  alias VoxelRegion.TestSupport.{Actor, Log, Source}

  @catalog "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  @magic "ff15757b8a7bfc20954ffde9370f04f0bc22b8a0b93fe31e03eb893165c7e9b1"
  @fixtures Path.expand("fixtures", __DIR__)
  @stone 11
  @leaf 28
  @battery 42
  @box {{-2, -2, -2}, {2, 2, 2}}
  @cid 1001

  setup do
    root = Path.join(System.tmp_dir!(), "magic_world_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.cp!(Path.join([@fixtures, "combustion", @catalog <> ".json"]), Path.join(root, "properties.json"))
    File.cp!(Path.join([@fixtures, "combustion", "environment-radiation.json"]), Path.join(root, "environment.json"))
    File.cp!(Path.join([@fixtures, "magic", @magic <> ".json"]), Path.join(root, "magic.json"))
    w = start(root)
    ground = for x <- -2..8, z <- -2..4, do: {{x, 0, z}, @stone}
    {:ok, _} = World.apply_edits(w, ground ++ [{{2, 1, 0}, @battery}, {{0, 2, 3}, @leaf}, {{7, 2, 0}, @leaf}])
    a = actor()
    # 作者初态：查询蓄能石的正式属性行，再经持久化边界写入 10 MJ 储能（见 moduledoc）。
    {:ok, row} = World.tool_intent(w, a, query(a, {20, 12, 4}, 1))
    seq = World.seq(w)
    :ok = stop_supervised(:world)
    OverlayLog.File.append(Path.join(root, "overlay.log"), %{seq: seq + 1, entries: [], coarse: [],
      property_states: [Map.merge(row, %{stored_j: 1.0e7, seq: seq + 1, request_id: 0})]})
    w = start(root)
    assert battery(observe(w)).stored_j == 1.0e7
    %{w: w, root: root, a: a, digest: Base.decode16!(@magic, case: :lower)}
  end

  defp start(root) do
    start_supervised!({World, [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: Path.join(root, "properties.json"),
      thermal_environment_path: Path.join(root, "environment.json"),
      magic_catalog_path: Path.join(root, "magic.json")]}, id: :world)
  end

  defp restart(c), do: (:ok = stop_supervised(:world); start(c.root))

  defp actor(cid \\ @cid) do
    a = %{cid: cid, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2,
      eye: {0.5, 2.5, 0.5}, feet: {0.5, 1.0, 0.5}, tick_us: 16_667}
    Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
  end

  defp next, do: System.unique_integer([:positive, :monotonic])
  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [@cid], @box)
  defp commit(w), do: (send(w, :thermal_commit); observe(w))
  defp cell(s, {x, y, z}), do: Enum.find(Map.values(s.damage), &(&1.granularity == 0 and &1.micro == {x * 8, y * 8, z * 8}))
  defp battery(s), do: cell(s, {2, 1, 0})
  defp energy(c), do: elem(World.caster_state(c.w, @cid), 1).energy_j
  defp ledger(s, key), do: Map.get(s.thermal, key, 0.0)

  # 眼睛指向目标微格中心的单位方向（与客户端准星同一表示）。
  defp aim(a, {x, y, z}) do
    {ex, ey, ez} = a.eye
    {dx, dy, dz} = {(x + 0.5) / 8 - ex, (y + 0.5) / 8 - ey, (z + 0.5) / 8 - ez}
    n = :math.sqrt(dx * dx + dy * dy + dz * dz)
    {dx / n, dy / n, dz / n}
  end

  defp query(a, micro, tool) do
    seq = next()
    %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 0, tool_id: tool,
      direction: aim(a, micro), micro: micro, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
  end

  defp heat_program(energy, power \\ 50_000),
    do: %{v: 1, target: %{kind: "aim"}, emit: "at_target", steps: [%{sym: "act.heat", args: %{energy_j: energy, power_w: power}}]}

  defp draw_program(energy),
    do: %{v: 1, target: %{kind: "aim"}, emit: "at_target", steps: [%{sym: "energy.draw", args: %{energy_j: energy}}]}

  # 正式路径：先用工具查询取得目标身份（与客户端命中同一射线），再以同一身份施法。
  defp spell(c, a, micro, program, opts \\ []) do
    {:ok, target} = World.tool_intent(c.w, a, query(a, micro, 1))
    seq = Keyword.get(opts, :seq, next())
    request = %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: Keyword.get(opts, :action, 1),
      catalog_digest: Keyword.get(opts, :digest, c.digest), direction: aim(a, micro),
      program: Jason.encode!(program)}
    request = Map.merge(request, Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
    VoxelRegion.TestSupport.spell(c.w, Map.merge(a, %{received_us: Keyword.get(opts, :at, seq * 1_000_000), clock_node: node()}), request)
  end

  @stone_micro {20, 12, 4}
  @leaf_micro {4, 20, 28}

  test "取能：10 MJ 石取 1 MJ、η 0.9 → 施法者得 0.9 MJ（付 1053.7222 J 构型损耗后余 898 946.2778 J）、石格热源 0.1 MJ、石剩 9 MJ；热提交后两处有限热源全部进世界", c do
    before = observe(c.w)
    assert {:ok, %{outcome: nil, seq: seq, caster: caster}} = spell(c, c.a, @stone_micro, draw_program(1_000_000))
    # 前摇开始事务 before.seq + 1（只带施放记录），结算事务 before.seq + 2。
    assert seq == before.seq + 2
    s = observe(c.w)
    # ΔE = min(1 MJ, 10 MJ, 5 MJ − 0) = 1 MJ；得 0.9 × 1 MJ = 900 000 J；E_loss = 1053.7222097 J（契约表“取能”）。
    assert_in_delta caster.energy_j, 898_946.2777903, 1.0e-6
    assert_in_delta caster.spent_j, 1053.7222097, 1.0e-6
    assert_in_delta caster.quote_j, 1053.7222097, 1.0e-6
    assert {caster.quote_s, caster.capacity_j, caster.coherence} == {1.0, 5.0e6, 4.0}
    assert_in_delta energy(c), 898_946.2777903, 1.0e-6
    assert battery(s).stored_j == 9.0e6
    assert_in_delta ledger(s, :caster_drawn_j), 900_000.0, 1.0e-6
    assert_in_delta ledger(s, :draw_loss_j), 100_000.0, 1.0e-6
    assert_in_delta ledger(s, :cast_waste_j), 1053.7222097, 1.0e-6
    # 验收式：石减少 1 MJ = 施法者取得 + 取能损耗；施法支出 = spell_heat_j (0) + cast_waste_j。
    assert_in_delta ledger(s, :caster_drawn_j) + ledger(s, :draw_loss_j), 1.0e7 - battery(s).stored_j, 1.0e-6
    # 有限热源：石格 0.1 MJ、脚下 1053.7222 J，都在一个 500 ms 提交内放完（功率 = 能量 / 0.5 s）。
    assert_in_delta s.thermal.sources[{2, 1, 0}].remaining_j, 100_000.0, 1.0e-6
    assert_in_delta s.thermal.sources[{2, 1, 0}].power_w, 200_000.0, 1.0e-6
    assert_in_delta s.thermal.sources[{0, 0, 0}].remaining_j, 1053.7222097, 1.0e-6
    assert_in_delta s.thermal.sources[{0, 0, 0}].power_w, 2107.4444193, 1.0e-6
    after_commit = commit(c.w)
    assert after_commit.thermal.sources == %{}
    assert_in_delta after_commit.thermal.supplied_j - s.thermal.supplied_j, 101_053.7222097, 1.0e-3
  end

  # 功率取槽上限 200 kW（0.4 MJ 在 2 s 内放完）：同样 0.4 MJ 以契约预设的 50 kW 投入时，孤立叶在 ε 0.9 辐射环境里
  # 8 s 内的对流 + 辐射散热使其峰值只到约 516 K（实测），不越过燃点 523.15 K；成本与功率无关。
  test "远程点火：孤立叶宏格 0.4 MJ / 200 kW → 着火；投入全部经热源进世界，账与余额一致", c do
    {:ok, _} = spell(c, c.a, @stone_micro, draw_program(1_000_000), at: 1_000_000)
    s0 = commit(c.w)
    assert {:ok, %{outcome: nil, caster: caster}} = spell(c, c.a, @leaf_micro, heat_program(400_000, 200_000), at: 2_000_000)
    # 总支出 = 0.4 MJ + E_loss 2292.5445548 J（契约表“远程点火”）= 402 292.5445548 J；
    # 余额 898 946.2777903 − 402 292.5445548 = 496 653.7332355 J。
    assert_in_delta caster.spent_j, 402_292.5445548, 1.0e-4
    assert_in_delta caster.energy_j, 496_653.7332355, 1.0e-4
    s = observe(c.w)
    assert s.thermal.sources[{0, 2, 3}] == %{remaining_j: 400_000.0, power_w: 200_000.0}
    assert ledger(s, :spell_heat_j) == 400_000.0
    assert_in_delta ledger(s, :cast_waste_j), 1053.7222097 + 2292.5445548, 1.0e-4
    # 同一目标已有热源：第二次点火拒绝，不扣能量。
    assert {:error, :heat_source_busy} = spell(c, c.a, @leaf_micro, heat_program(400_000), at: 3_000_000)
    assert_in_delta energy(c), 496_653.7332355, 1.0e-4
    # 0.4 MJ / 200 kW = 2 s = 4 个提交放完；叶 ΔT 上限 0.4 MJ / 1200 J/K ≈ 333 K，散热后仍越过燃点 523.15 K。
    burning = Enum.find_value(1..40, fn _ ->
      t = commit(c.w)
      if Map.get(cell(t, {0, 2, 3}) || %{}, :burning, false), do: t
    end)
    assert burning, "leaf never ignited"
    done = Enum.find_value(1..40, fn _ -> t = commit(c.w); if t.thermal.sources == %{}, do: t end)
    # 热源放完后：本次施法进入世界的热 = 0.4 MJ（目标）+ 2292.5445548 J（脚下）。内核供热账 supplied_j 含燃烧放热，
    # 燃烧另记 combustion_j；两者之差的增量即热源注入，与施法账同额。
    fed = fn t -> t.thermal.supplied_j - ledger(t, :combustion_j) end
    assert ledger(done, :combustion_j) > 0
    assert_in_delta fed.(done) - fed.(s0), 402_292.5445548, 1.0e-2
    IO.puts("MAGIC_IGNITE burning_at_s=#{burning.thermal.elapsed_s - s0.thermal.elapsed_s} temperature=#{cell(burning, {0, 2, 3}).temperature_kelvin}")
  end

  test "走火：余额 100 kJ、成本 301 986.49 J → 走完前摇后余额 0、脚下热源 100 kJ、目标无热源；结果为已提交事务", c do
    # 余额 100 kJ：取能 R 使 0.9 R − 1053.7222097 = 100 000 → R = 112 281.913566… J。
    {:ok, _} = spell(c, c.a, @stone_micro, draw_program(112_281.91356628455), at: 1_000_000)
    assert_in_delta energy(c), 100_000.0, 1.0e-6
    s0 = commit(c.w)
    waste0 = ledger(s0, :cast_waste_j)
    # 0.3 MJ 加热：b = 1000·1.3^1.5 = 1482.228 W，E_loss = 2·2.831793·√(50·b) + b·0.3 = 1986.4898170 J；
    # 总支出 301 986.4898 J > 100 000 J → 走完前摇后结算为 misfire_energy（开始事务 + 结算事务）。
    assert {:ok, %{outcome: :misfire_energy, seq: seq, caster: caster}} =
             spell(c, c.a, @leaf_micro, heat_program(300_000), at: 2_000_000)
    assert seq == s0.seq + 2
    assert_in_delta caster.spent_j, 100_000.0, 1.0e-6
    assert_in_delta caster.energy_j, 0.0, 1.0e-6
    assert_in_delta caster.quote_j, 301_986.4898170, 1.0e-4
    s = observe(c.w)
    assert_in_delta s.thermal.sources[{0, 0, 0}].remaining_j, 100_000.0, 1.0e-6
    refute Map.has_key?(s.thermal.sources, {0, 2, 3})
    assert_in_delta ledger(s, :cast_waste_j) - waste0, 100_000.0, 1.0e-6
    assert ledger(s, :spell_heat_j) == 0.0
    # 余额为 0 时再次走火：扣 0，不产生热源。
    assert {:ok, %{outcome: :misfire_energy, caster: %{spent_j: spent}}} =
             spell(c, c.a, @leaf_micro, heat_program(300_000), at: 3_000_000)
    assert spent == 0.0
  end

  test "拒绝不扣能量、不改世界：他人地块、超出施法域、射线未命中、施法过快、目录过期、程序非法、目标不是蓄能石；报价不改世界", c do
    {:ok, _} = spell(c, c.a, @stone_micro, draw_program(1_000_000), at: 1_000_000)
    seq = World.seq(c.w)
    energy = energy(c)
    unchanged = fn seq -> assert {World.seq(c.w), energy(c)} == {seq, energy} end

    # 施法过快：间隔 500 ms，上一笔在 1.0 s → 1.1 s 被拒。
    assert {:error, :cast_too_soon} = spell(c, c.a, @leaf_micro, heat_program(400_000), at: 1_100_000)
    unchanged.(seq)
    # 远叶格心距眼 7 m > 6 m；朝天空的射线 30 m 内无命中。
    assert {:error, :out_of_domain} = spell(c, c.a, {60, 20, 4}, heat_program(400_000), at: 2_000_000)
    {:ok, target} = World.tool_intent(c.w, c.a, query(c.a, @leaf_micro, 1))
    sky = %{request_id: 7, client_intent_seq: next(), logical_scene_id: 1, action: 1, catalog_digest: c.digest,
      direction: {0.0, 1.0, 0.0}, program: Jason.encode!(heat_program(400_000))}
      |> Map.merge(Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
    assert {:error, :out_of_domain} = VoxelRegion.TestSupport.spell(c.w, Map.merge(c.a, %{received_us: 3_000_000, clock_node: node()}), sky)
    # 取能只作用于蓄能石。
    assert {:error, :invalid_target} = spell(c, c.a, @leaf_micro, draw_program(1_000_000), at: 4_000_000)
    assert {:error, :stale_magic_catalog} = spell(c, c.a, @leaf_micro, heat_program(400_000), at: 5_000_000, digest: <<0::256>>)
    assert {:error, :invalid_program} = spell(c, c.a, @leaf_micro, heat_program(999), at: 6_000_000)
    unchanged.(seq)

    # 他人（cid 2002）认领叶所在列：目标格在他人地块 → protected_region。
    {:ok, _} = World.author_regions(c.w, [%{holder: {:character, 2002}, min: {0, 3}, max: {0, 3}}])
    seq = World.seq(c.w)
    assert {:error, :protected_region} = spell(c, c.a, @leaf_micro, heat_program(400_000), at: 7_000_000)
    unchanged.(seq)
    # 报价（action 0）：同一成本函数，不改世界、不占施法间隔。
    assert {:ok, %{caster: q}} = spell(c, c.a, @leaf_micro, heat_program(400_000), action: 0, at: 7_000_001)
    assert_in_delta q.quote_j, 402_292.5445548, 1.0e-4
    assert {q.quote_s, q.spent_j} == {1.0, 0.0}
    unchanged.(seq)
    # 脚下宏格在他人地块同样拒绝：认领脚下列后取能被拒。
    {:ok, _} = World.author_regions(c.w, [%{holder: {:character, 2002}, min: {0, 0}, max: {0, 0}}])
    seq = World.seq(c.w)
    assert {:error, :protected_region} = spell(c, c.a, @stone_micro, draw_program(1_000_000), at: 8_000_000)
    unchanged.(seq)
  end

  test "冷重启：施法者能量随日志重放与检查点保留；不自动回复", c do
    {:ok, _} = spell(c, c.a, @stone_micro, draw_program(1_000_000), at: 1_000_000)
    assert_in_delta energy(c), 898_946.2777903, 1.0e-6
    w = restart(c)
    c = %{c | w: w}
    assert_in_delta energy(c), 898_946.2777903, 1.0e-6
    assert battery(observe(w)).stored_j == 9.0e6
    assert :ok = World.compact(w)
    w = restart(c)
    c = %{c | w: w}
    assert_in_delta energy(c), 898_946.2777903, 1.0e-6
    # 未施法的角色能量为 0；多次热提交后施法者能量不变。
    for _ <- 1..3, do: commit(w)
    assert_in_delta energy(c), 898_946.2777903, 1.0e-6
    assert {:ok, %{energy_j: +0.0}} = World.caster_state(w, 2002)
  end
end
