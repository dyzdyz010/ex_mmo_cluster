defmodule VoxelRegion.BodyContactWorldTest do
  @moduledoc """
  只测试：魔法增量 4 在真实 World 里的身体接触换热（Voxim Docs/Magic.md §6）——身体皮肤是热内核外部节点，
  World 把每段演进的交换热回传给报告者（这里测试进程扮演 Scene 的 Player），两端各记一笔、同值。

  目录：材料 `b1aca503…`（石 11 k 25、木 19 k 150 燃点 573.15 K、水 21、蓄能石 42），魔法 `1ff967d7…`（拟态 k_s 400）；
  热环境 = 生产 ε 0.9、环境 293.15 K、容差 1 K。地面石 11 铺 y = 0；身体脚 y = 1.0、身高 1.8 m、半径 0.3 m、
  皮肤 307.15 K（34 °C）、皮肤热容 24430 J/K、体表 1.8 m²。热初态（600 K 的石 / 木、10 MJ 蓄能石）作为作者初态经持久化
  边界安装一次（同 magic_semblance_world_test）；水经 Test-only `liquid_experiment` 作者入口装入围起的两格坑。

  手算导热（BodyContact）：鞋底踩石 0.03/(0.06 + 0.5/25) = 0.375 W/K；两格水 [1,2) 与 [2,2.8) 浸没
  1.8·1.0/1.8/0.04 + 1.8·0.8/1.8/0.04 = 25 + 20 = 45 W/K；触碰 r 0.4 m 拟态 0.01/(0.4/400) = 10 W/K。
  World 自身每 500 ms 也提交：断言只用每条回传里的同段量（q、段长、接触最高温）与两端累计。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.{World, OverlayLog}
  alias VoxelRegion.TestSupport.{Actor, Log, Source}

  @catalog "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  @magic "1ff967d746cd0f1064924292011ce5227dcb6db03d99d45a9befa98a89908075"
  @fixtures Path.expand("fixtures", __DIR__)
  @stone 11
  @wood 19
  @water 21
  @battery 42
  @box {{-2, -2, -2}, {2, 2, 2}}
  @cid 1001
  @skin 307.15
  @body %{height: 1.8, radius: 0.3, skin_k: 307.15, capacity: 24_430.0, area: 1.8}

  setup do
    root = Path.join(System.tmp_dir!(), "body_contact_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.cp!(Path.join([@fixtures, "combustion", @catalog <> ".json"]), Path.join(root, "properties.json"))
    File.cp!(Path.join([@fixtures, "combustion", "environment-radiation.json"]), Path.join(root, "environment.json"))
    File.cp!(Path.join([@fixtures, "magic", @magic <> ".json"]), Path.join(root, "magic.json"))
    w = start(root)
    ground = for x <- -2..8, z <- -2..8, do: {{x, 0, z}, @stone}
    # 水坑 (6, 1..2, 6) 的四面石墙；木 (0,0,6) 替换地面；蓄能石 (2,1,0)。
    walls = for {x, z} <- [{5, 6}, {7, 6}, {6, 5}, {6, 7}], y <- 1..2, do: {{x, y, z}, @stone}
    {:ok, _} = World.apply_edits(w, ground ++ walls ++ [{{0, 0, 6}, @wood}, {{2, 1, 0}, @battery}])
    data = Jason.decode!(File.read!(Path.join(root, "magic.json")))
    %{w: w, root: root, digest: Base.decode16!(@magic, case: :lower),
      presets: Map.new(data["presets"], &{&1["id"], &1["program"]})}
  end

  defp start(root) do
    start_supervised!({World, [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: Path.join(root, "properties.json"),
      thermal_environment_path: Path.join(root, "environment.json"),
      magic_catalog_path: Path.join(root, "magic.json"), liquid_bounds: {{0, 0, 0}, {8, 8, 8}}]}, id: :world)
  end

  defp restart(c), do: (:ok = stop_supervised(:world); start(c.root))

  defp actor(eye, feet) do
    a = %{cid: @cid, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2, eye: eye, feet: feet,
      tick_us: 16_667}
    Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
  end

  defp next, do: System.unique_integer([:positive, :monotonic])
  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [@cid], @box)
  defp commit(w), do: (send(w, :thermal_commit); observe(w))
  defp contact(w, feet), do: send(w, {:body_contact, @cid, self(), Map.put(@body, :feet, feet)})

  defp query(a, {x, y, z} = micro) do
    {ex, ey, ez} = a.eye
    {dx, dy, dz} = {(x + 0.5) / 8 - ex, (y + 0.5) / 8 - ey, (z + 0.5) / 8 - ez}
    n = :math.sqrt(dx * dx + dy * dy + dz * dz)
    seq = next()
    %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 0, tool_id: 1,
      direction: {dx / n, dy / n, dz / n}, micro: micro, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}
  end

  # 作者初态：眼睛射线取得格的属性行，改字段后经日志边界安装一次（重启后生效）。
  defp install(c, rows) do
    rows = Enum.map(rows, fn {eye, micro, fields} ->
      a = actor(eye, {0.0, 0.0, 0.0})
      {:ok, row} = World.tool_intent(c.w, a, query(a, micro))
      {row, fields}
    end)

    seq = World.seq(c.w)
    :ok = stop_supervised(:world)
    OverlayLog.File.append(Path.join(c.root, "overlay.log"), %{seq: seq + 1, entries: [], coarse: [],
      property_states: for({row, fields} <- rows, do: Map.merge(row, Map.merge(fields, %{seq: seq + 1, request_id: 0})))})
    %{c | w: start(c.root)}
  end

  # 取尽邮箱里的回传（World 先发回传、后答 observe，同一进程内有序）。
  defp drain(acc \\ []) do
    receive do
      {:body_heat, heat} -> drain([heat | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp ledger(s), do: Map.get(s.thermal, :body_exchange_j, 0.0)

  # 两端同值：本端逐条累加（同一加法次序）等于 World 账。
  defp both_ends(heats, s), do: assert(Enum.reduce(heats, 0.0, &(&2 + &1.q_j)) == ledger(s))

  test "脚下 600 K 石：G = 0.375 W/K，每段 q/dt = G·(T_接触 − 307.15)（1%）；皮肤升温方向；两端交换量相等", c do
    c = install(c, [{{0.5, 2.5, 0.5}, {4, 7, 4}, %{temperature_kelvin: 600.0}}])
    heats =
      for _ <- 1..4 do
        contact(c.w, {0.5, 1.0, 0.5})
        commit(c.w)
        drain()
      end
      |> List.flatten()

    assert heats != []

    for h <- heats do
      assert h.immersed == 0.0 and h.max_contact_k > 590
      expected = 0.375 * (h.max_contact_k - @skin) * h.dt_s
      assert_in_delta h.q_j, expected, 0.01 * expected
    end

    both_ends(heats, observe(c.w))
  end

  test "站在 600 K 木上：木着火燃烧，接触最高温 ≥ 燃点、身体持续吸热；两端交换量相等", c do
    c = install(c, [{{0.5, 2.5, 6.5}, {4, 7, 52}, %{temperature_kelvin: 600.0}}])

    {heats, s} =
      Enum.reduce(1..8, {[], nil}, fn _, {acc, _} ->
        contact(c.w, {0.5, 1.0, 6.5})
        s = commit(c.w)
        {acc ++ drain(), s}
      end)

    wood = Enum.find(Map.values(s.damage), &(&1.granularity == 0 and &1.micro == {0, 0, 48}))
    assert wood.burning
    assert Enum.all?(heats, &(&1.q_j > 0 and &1.max_contact_k >= 573.15))
    both_ends(heats, s)
  end

  test "两格 293.15 K 水坑里站立：浸没 1.0、G = 45 W/K，q/dt = 45·(T_水 − 307.15)（1%，身体放热）；离开即注销", c do
    path = Path.join(c.root, "basin.json")
    File.write!(path, Jason.encode!(%{classification: "Test-only",
      deposits: [%{macro: [6, 1, 6], material: @water}, %{macro: [6, 2, 6], material: @water}]}))
    {:ok, _} = World.liquid_experiment(c.w, path)

    heats =
      for _ <- 1..3 do
        contact(c.w, {6.5, 1.0, 6.5})
        commit(c.w)
        drain()
      end
      |> List.flatten()

    assert heats != []

    for h <- heats do
      assert_in_delta h.immersed, 1.0, 1.0e-12
      assert_in_delta h.max_contact_k, 293.15, 0.05
      expected = 45.0 * (h.max_contact_k - @skin) * h.dt_s
      assert h.q_j < 0
      assert_in_delta h.q_j, expected, 0.01 * abs(expected)
    end

    both_ends(heats, observe(c.w))

    # 走到环境温度的地面上：报告后注销，此后没有回传，账不再变。
    contact(c.w, {3.5, 1.0, 3.5})
    before = ledger(commit(c.w))
    drain()
    after_leave = commit(c.w)
    assert drain() == [] and ledger(after_leave) == before
  end

  test "环境温度的地面：不登记接触、不回传", c do
    contact(c.w, {3.5, 1.0, 3.5})
    s = commit(c.w)
    assert drain() == [] and ledger(s) == 0.0
  end

  test "手碰 2000 K 炽热拟态：G = 10 W/K，q 夹在段末与段前温差之间；拟态降温、拟态账闭合、两端相等", c do
    c = install(c, [{{0.5, 2.5, 0.5}, {20, 12, 4}, %{stored_j: 1.0e7}}])
    a = actor({0.5, 2.5, 0.5}, {0.5, 1.0, 0.5})
    {:ok, target} = World.tool_intent(c.w, a, query(a, {20, 12, 4}))
    draw = %{v: 1, target: %{kind: "aim"}, emit: "at_target", steps: [%{sym: "energy.draw", args: %{energy_j: 2_000_000}}]}
    request = %{request_id: next(), client_intent_seq: next(), logical_scene_id: 1, action: 1, catalog_digest: c.digest,
      direction: query(a, {20, 12, 4}).direction, program: Jason.encode!(draw), semblance: {0, 0}}
      |> Map.merge(Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
    assert {:ok, %{outcome: nil}} = VoxelRegion.TestSupport.spell(c.w, Map.merge(a, %{received_us: 1_000_000, clock_node: node()}), request)

    # 竖直向下投掷：手边 (0.5, 2.0, 0.5)，v = (0, −12, 0)，球心停在地面顶面上方一个半径 (0.5, 1.4, 0.5)，正在施法者脚边。
    seq = next()
    throw = %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 1, catalog_digest: c.digest,
      direction: {0.0, -1.0, 0.0}, micro: {0, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0,
      semblance: {0, 0}, program: Jason.encode!(c.presets["hot_throw"])}
    assert {:ok, %{outcome: nil, seq: ball_seq}} =
             VoxelRegion.TestSupport.spell(c.w, Map.merge(a, %{received_us: 2_000_000, clock_node: node()}), throw)

    landed = Enum.find_value(1..10, fn _ -> s = commit(c.w); b = s.semblances[{ball_seq, 0}]; if b.age_s >= b.flight_s, do: s end)
    ball = landed.semblances[{ball_seq, 0}]
    assert ball.rest == {0.5, 1.4, 0.5}
    drain()
    base = ledger(landed)

    # 球以辐射为主急速冷却（εσT⁴·4πr² 在 2000 K 约 1.6 MW），一段内温度不是常数：用单调冷却夹住手算式——
    # G·(T_段末 − T_皮)·dt ≤ q ≤ G·(T_段前观测 − T_皮)·dt（T_段末 即回传的接触最高温，段前观测不晚于该段起点）。
    {heats, s} =
      Enum.reduce(1..3, {[], landed}, fn _, {acc, prev} ->
        contact(c.w, {0.5, 1.0, 0.5})
        s = commit(c.w)
        start = prev.semblances[{ball_seq, 0}].temperature_k
        {acc ++ Enum.map(drain(), &Map.put(&1, :start_k, start)), s}
      end)

    assert heats != []

    for h <- heats do
      assert h.max_contact_k > @skin + 100
      assert h.q_j >= 10.0 * (h.max_contact_k - @skin) * h.dt_s
      assert h.q_j <= 10.0 * (h.start_k - @skin) * h.dt_s
    end

    cooled = s.semblances[{ball_seq, 0}]
    assert cooled.temperature_k < ball.temperature_k
    assert Enum.reduce(heats, base, &(&2 + &1.q_j)) == ledger(s)
    out = Enum.sum(for k <- [:semblance_exchanged_j, :semblance_light_j, :semblance_released_j, :semblance_thermal_j,
      :semblance_stored_j], do: Map.get(s.thermal, k, 0.0))
    assert_in_delta s.thermal.semblance_created_j, out, 1.0e-6 * s.thermal.semblance_created_j
  end

  test "冷重启：身体登记是派生状态，不随日志恢复；重启后未续报即无回传", c do
    c = install(c, [{{0.5, 2.5, 0.5}, {4, 7, 4}, %{temperature_kelvin: 600.0}}])
    contact(c.w, {0.5, 1.0, 0.5})
    commit(c.w)
    assert drain() != []
    w = restart(c)
    commit(w)
    assert drain() == []
  end
end
