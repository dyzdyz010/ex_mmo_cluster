defmodule VoxelRegion.BodyContactWorldTest do
  @moduledoc """
  只测试：魔法增量 4 在真实 World 里的身体接触换热（Voxim Docs/Magic.md §6）——身体皮肤与局部接触组织块是热内核的两个
  外部节点（之间一条内部边），World 把每段演进的交换热（及其中存进组织块的部分）回传给报告者（这里测试进程扮演 Scene 的
  Player），两端各记一笔、同值。

  目录：材料 `b1aca503…`（石 11 k 25、木 19 k 150 燃点 573.15 K、水 21、蓄能石 42），魔法 `1ff967d7…`（拟态 k_s 400）；
  热环境 = 生产 ε 0.9、环境 293.15 K、容差 1 K。地面石 11 铺 y = 0；身体脚 y = 1.0、身高 1.8 m、半径 0.3 m、
  皮肤 307.15 K（34 °C）、皮肤热容 24430 J/K、体表 1.8 m²；组织块 307.15 K、热容 209.4 J/K、组织块-皮肤导热
  0.378207 W/K（0.03 m² × 调定点 K_cs 12.6069）。热初态（600 K 的石 / 木、10 MJ 蓄能石）作为作者初态经持久化
  边界安装一次（同 magic_semblance_world_test）；水经 Test-only `liquid_experiment` 作者入口装入围起的两格坑。

  手算导热（BodyContact）：鞋底（冬靴 R 0.15）踩石 0.03/(0.15 + 0.5/25) = 0.17647059 W/K；两格水 [1,2) 与 [2,2.8) 浸没
  1.8·1.0/1.8/0.04 + 1.8·0.8/1.8/0.04 = 25 + 20 = 45 W/K；触碰 r 0.4 m 拟态 0.01/(0.4/400) = 10 W/K。
  World 自身每 500 ms 也提交：断言只用每条回传里的同段量（q、段长、接触温度）与两端累计。
  鞋底与触碰接组织块、浸没接皮肤。组织块解析解（段内世界格温度 T_w 与皮肤 T_s 视为常数）：k = (G_c + G_i)/C_t，
  T_ss = (G_c·T_w + G_i·T_s)/(G_c + G_i)，T_末 = T_ss + (T_0 − T_ss)·e^(−k·dt)，q = G_c·[(T_w − T_ss)·dt + (T_ss − T_0)·(1 − e^(−k·dt))/k]。
  接触温度诊断分两路：鞋底格 `sole_k`、其余裸接触（浸没、触碰）最高温 `max_contact_k`，某路没有接触为 nil。
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
  @tissue_c 209.4
  @tissue_g 0.378207
  @body %{height: 1.8, radius: 0.3, skin_k: 307.15, capacity: 24_430.0, area: 1.8, tissue_k: 307.15,
    tissue_capacity: 209.4, tissue_g: 0.378207}

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
  defp contact(w, feet, fields \\ %{}), do: send(w, {:body_contact, @cid, self(), Map.merge(@body, Map.put(fields, :feet, feet))})

  # 本段起点组织块温度 = 段末 − tissue_j / C_t。
  defp start_k(h), do: h.tissue_k - h.tissue_j / @tissue_c

  # 组织块解析解 {T_末, q}（见 moduledoc）。
  defp tissue(g_c, t_w, t0, dt) do
    k = (g_c + @tissue_g) / @tissue_c
    ss = (g_c * t_w + @tissue_g * @skin) / (g_c + @tissue_g)
    {ss + (t0 - ss) * :math.exp(-k * dt), g_c * ((t_w - ss) * dt + (ss - t0) * (1 - :math.exp(-k * dt)) / k)}
  end

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

  # 鞋底接组织块：G_c = 0.17647059，T_ss = (0.17647059·~600 + 0.378207·307.15)/0.5546776 ≈ 400 K，k = 0.0026489 /s。
  # 两次报告之间 World 自己推进组织块（段末温度作下一段起点），报告再覆盖；每段按解析解核对段末温度与 q。
  test "脚下 600 K 石：鞋底边接组织块，每段组织块段末温度与 q 符合解析解；组织块逐段升温、跨段相接；两端交换量相等", c do
    c = install(c, [{{0.5, 2.5, 0.5}, {4, 7, 4}, %{temperature_kelvin: 600.0}}])

    {heats, reported} =
      Enum.reduce(1..4, {[], [@skin]}, fn _, {acc, [tracked | _] = reported} ->
        contact(c.w, {0.5, 1.0, 0.5}, %{tissue_k: tracked})
        commit(c.w)
        new = drain()
        {acc ++ new, [Enum.reduce(new, tracked, &(&2 + &1.tissue_j / @tissue_c)) | reported]}
      end)

    assert length(heats) >= 4

    for h <- heats do
      assert h.immersed == 0.0 and h.max_contact_k == nil and h.sole_k > 590
      {t_end, q} = tissue(0.03 / 0.17, h.sole_k, start_k(h), h.dt_s)
      assert_in_delta h.tissue_k, t_end, 1.0e-3
      # q 对 T_w 敏感：600 K 石同时向四周石地传热、段内降约 1 K，而回传的是段末温度 → 放宽到 1%。
      assert_in_delta h.q_j, q, 1.0e-2 * q
    end

    # 段与段首尾相接：每段起点是上一段段末（World 自己推进）或本端刚报告的温度（= 按回传累加），组织块逐段升温。
    for [a, b] <- Enum.chunk_every(heats, 2, 1, :discard),
        do: assert(Enum.any?([a.tissue_k | reported], &(abs(start_k(b) - &1) < 1.0e-9)))
    # 初始升温率 0.17647·(600 − 307.15)/209.4 ≈ 0.247 K/s，4 次提交 ≥ 2 s 模拟 → 至少约 +0.45 K。
    assert List.last(heats).tissue_k > @skin + 0.4
    both_ends(heats, observe(c.w))
  end

  # 只有内部边：组织块 330 K、皮肤 307.15 K 站在环境温度地面上——没有接触也登记，按两节点解析解趋同
  # （温差按 e^(−G·(1/C_t + 1/C_s)·t) 衰减，G = 0.378207），经接触边进身体的热 q = 0；报告温差回到容差内即注销。
  test "组织块与皮肤不平衡：无接触也登记、只经内部边趋同（解析解）、q = 0；平衡后注销、不再回传", c do
    contact(c.w, {3.5, 1.0, 3.5}, %{tissue_k: 330.0})
    commit(c.w)
    heats = drain()
    assert heats != []
    rate = @tissue_g * (1 / @tissue_c + 1 / 24_430.0)

    for h <- heats do
      assert abs(h.q_j) < 1.0e-6 and h.sole_k == nil and h.max_contact_k == nil
      t0 = start_k(h)
      # 皮肤得到的 = −tissue_j：T_s 段末 = 307.15 − tissue_j / 24430；两节点温差按指数衰减。
      skin_end = @skin - h.tissue_j / 24_430.0
      assert_in_delta h.tissue_k - skin_end, (t0 - @skin) * :math.exp(-rate * h.dt_s), 1.0e-3
    end

    contact(c.w, {3.5, 1.0, 3.5}, %{tissue_k: @skin + 0.5})
    before = ledger(commit(c.w))
    drain()
    after_leave = commit(c.w)
    assert drain() == [] and ledger(after_leave) == before
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
    assert Enum.all?(heats, &(&1.q_j > 0 and &1.sole_k >= 573.15 and &1.max_contact_k == nil))
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
      assert h.sole_k == nil
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

  test "手碰 2000 K 炽热拟态：G = 10 W/K 接组织块，q 夹在段末与段前温差之间、组织块升温；拟态降温、拟态账闭合、两端相等", c do
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

    # 球以辐射为主急速冷却（εσT⁴·4πr² 在 2000 K 约 1.6 MW），组织块急速升温，一段内两者都不是常数：触碰边接组织块，
    # 用单调性夹住 q = G·∫(T_球 − T_组织)dt——G·(T_球段末 − T_组织段末)·dt ≤ q ≤ G·(T_球段前观测 − T_组织段首)·dt
    # （T_球段末 即回传的接触最高温，段前观测不晚于该段起点）。
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
      assert h.q_j >= 10.0 * (h.max_contact_k - h.tissue_k) * h.dt_s
      assert h.q_j <= 10.0 * (h.start_k - start_k(h)) * h.dt_s
      assert h.tissue_k > start_k(h)
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
