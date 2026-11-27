defmodule VoxelRegion.MagicStructureNeighborsTest do
  @moduledoc """
  只测试：结构步进的拍首邻居查找 `World.Structures.neighbor_index/2` + `neighbors_of/4`（决策稿
  `docs/10-active/magic/2026-11-26-p1-closure-slices4-8.md` §14 切片 8a 负载结论 2 的修复；设计 TheWorldBook
  `docs/2026-11-19-glyph-composition-game-design.md` §5.3 第 1 步“本拍开始时建一次 8 m 空间网格，取贡献最大的 ≤ 16 个邻居”、
  §5.3.2“并列按 id”）。

  - 契约：按网格桶索引后的查找与改前的全表扫描逐项相等——同样的邻居集合、同样的 ≤ `env_neighbor_max` 截断与并列规则、
    同样的输出顺序与浮点值，因而 `Structure.step/4` 的输入不变；每拍查找的工作量（`distance/2` 调用次数）与结构数成线性。
  - 参照：`reference_*` 是改前生产实现（d3a95e89 `structures.ex:1146–1165`）的只测试副本，即“每个结构遍历整张索引、用
    8 m 网格桶相邻只作过滤”的蛮力定义；生产代码只留新实现。
  - 夹具（算法层，Testing.md §2.1）：结构由冻结样本 `fixtures/magic/ir-v2-samples.json` 经真实 `Program.decode_ir/2`、
    `Cost.quote_structure/3`、`Structure.new/4` 出生（同 `magic_structure_test.exs`），物理体只给静止位置 `rest` 或飞行中的
    `origin/velocity/age_s`（`Structures.position/1` 的两种输入）。位置是手排的边界情形（跨桶边界、负坐标、重合、恰好
    r_N、贡献相同按 id、> 16 个候选）与固定种子的随机散布。
  - 计数（不用墙钟，生产代码不插桩）：比较次数用 BEAM 的 `call_count` 跟踪数 `Structures.distance/2` 的调用（每个候选算一次
    距离）；总工作量用本进程的 reductions。改前实现同样只对相邻桶的候选算距离，平方项在“遍历整张索引”上，所以只有 reductions
    能分辨新旧，规模用例同时对参照量一次，确认这个计量对平方增长是红的。
  - 不覆盖：`Structure.step/4` 对邻居项的消费（`magic_structure_test.exs`）、World 拍内接线（`magic_structure_world_test.exs`
    与负载测试 `magic_load_test.exs`）。
  """
  use ExUnit.Case, async: false
  @moduletag :t0
  alias VoxelRegion.Magic.{Catalog, Cost, Program, Structure}
  alias VoxelRegion.World.Structures

  @digest "22c459f0a8beb59d2396131d935736b98f4a6d0933f77152103f25e0b6b1ecdc"
  @path Application.app_dir(:voxel_region, "priv/magic/#{@digest}.json")
  @samples Path.expand("fixtures/magic/ir-v2-samples.json", __DIR__)
  @site %{ambient_k: 293.15, formation_distance_m: 3.0, emissivity: 0.9, exchange_w_per_m2_k: 10.0}
  @presets ~w(lamp fireball hot_throw scorch dispel_pulse timed_ember guarded_fireball staff_bolt_massless)
  # 改前实现的网格边长（`Structures` 的 `@grid_m`，设计 §5.3 第 1 步的 8 m）。
  @grid_m 8.0

  setup_all do
    catalog = Catalog.load(@path)
    samples = Map.new(Jason.decode!(File.read!(@samples))["samples"], &{&1["id"], &1["program_hex"]})

    births =
      Map.new(@presets, fn name ->
        {:ok, %Program{kind: :structure, groups: [group]} = program} =
          Program.decode_ir(Base.decode16!(samples[name], case: :lower), catalog)

        {name, {group, Cost.quote_structure(program, catalog, @site)}}
      end)

    %{catalog: catalog, births: births}
  end

  # 第 n 个结构：id {seq, 0}，预设按 n 轮换（除非指定），位置 `at`；`flight` 给出时为飞行中的物理体。
  defp entry(c, n, at, opts \\ []) do
    name = Keyword.get(opts, :preset, Enum.at(@presets, rem(n, length(@presets))))
    {group, quote} = c.births[name]
    id = {1000 + n, 0}

    body =
      case Keyword.get(opts, :flight) do
        nil -> %{flight: nil, rest: at}
        {velocity, age} -> %{flight: %{age_s: age}, origin: at, velocity: velocity, massless: name == "staff_bolt_massless"}
      end

    {id, %{structure: Structure.new(id, group, quote, 0), body: body}}
  end

  # ---------------------------------------------------------------------------
  # 改前实现的只测试副本（参照）
  # ---------------------------------------------------------------------------

  defp reference_index(ordered, catalog) do
    for {id, %{structure: s, body: body}} <- ordered, into: %{} do
      position = Structures.position(body)
      leak_w = Structure.running_loss_w(s, s.e_op_mj + abs(s.e_th_mj), catalog)
      {id, %{position: position, leak_w: leak_w, bucket: reference_bucket(position)}}
    end
  end

  defp reference_bucket({x, y, z}), do: {floor(x / @grid_m), floor(y / @grid_m), floor(z / @grid_m)}

  defp reference_neighbors(index, id, position, %Catalog{runtime: rt}) do
    {bx, by, bz} = reference_bucket(position)
    r = rt.env_neighbor_radius_m

    for({other, n} <- index, other != id, adjacent?(n.bucket, {bx, by, bz}), d = distance(position, n.position), d < r,
        do: {other, %{leak_w: n.leak_w, distance_m: d}})
    |> Enum.sort_by(fn {other, n} -> {-n.leak_w * (1 - n.distance_m / r), other} end)
    |> Enum.take(rt.env_neighbor_max)
    |> Enum.map(&elem(&1, 1))
  end

  defp adjacent?({nx, ny, nz}, {bx, by, bz}), do: abs(nx - bx) <= 1 and abs(ny - by) <= 1 and abs(nz - bz) <= 1
  defp distance({ax, ay, az}, {bx, by, bz}), do: :math.sqrt((bx - ax) ** 2 + (by - ay) ** 2 + (bz - az) ** 2)

  # ---------------------------------------------------------------------------
  # 判定
  # ---------------------------------------------------------------------------

  # 新旧逐项相等（`===`：浮点逐位，含 -0.0 / 0.0 之分）；查询点为每个结构的拍首位置（同 `tick/3`）与额外的探查点。
  # 返回非空查询数与被截断的查询数，供调用方确认夹具确实覆盖了这些情形。
  defp assert_equivalent(ordered, catalog, probes \\ []) do
    index = Structures.neighbor_index(ordered, catalog)
    reference = reference_index(ordered, catalog)
    assert index.sites === reference

    queries = for({id, site} <- reference, do: {id, site.position}) ++ for(p <- probes, do: {:probe, p})

    results =
      for {id, position} <- queries do
        expected = reference_neighbors(reference, id, position, catalog)
        assert Structures.neighbors_of(index, id, position, catalog) === expected, "查询 #{inspect(id)} @ #{inspect(position)}"
        expected
      end

    %{nonempty: Enum.count(results, &(&1 != [])), truncated: Enum.count(results, &(length(&1) == catalog.runtime.env_neighbor_max))}
  end

  defp count_distance_calls(fun) do
    mfa = {Structures, :distance, 2}
    Code.ensure_loaded!(Structures)
    assert :erlang.trace_pattern(mfa, true, [:call_count]) == 1

    try do
      fun.()
      {:call_count, n} = :erlang.trace_info(mfa, :call_count)
      n
    after
      :erlang.trace_pattern(mfa, false, [:call_count])
    end
  end

  # 固定种子的均匀散布：n 个结构放进体积 n × 512 m³ 的立方体（平均每个 8 m 桶 1 个），密度与 n 无关。
  defp scatter(c, n, seed) do
    :rand.seed(:exsss, {seed, 7, 11})
    side = :math.pow(n * 512.0, 1 / 3)
    for k <- 1..n, do: entry(c, k, {:rand.uniform() * side - side / 2, :rand.uniform() * side, :rand.uniform() * side - side / 2})
  end

  test "手排边界情形：跨桶与负坐标、重合、恰好 r_N、贡献相同按 id、超过 16 个候选时截断，新旧逐项相等", c do
    # 24 个灯围着原点（桶 {−1, 0, −1} … {0, 0, 0} 的交界）排成两圈：同半径同预设，贡献相同，按 id 打破并列；超过 16 个。
    ring =
      for k <- 0..23 do
        a = k * :math.pi() / 12
        rr = if rem(k, 2) == 0, do: 1.5, else: 3.0
        entry(c, k, {rr * :math.cos(a), 1.0, rr * :math.sin(a)}, preset: "lamp")
      end

    edges = [
      # 重合（d = 0）
      entry(c, 100, {20.25, 1.0, 20.25}),
      entry(c, 101, {20.25, 1.0, 20.25}),
      # 恰好 r_N = 8 m（不计入）与差一点（计入），跨两个桶
      entry(c, 102, {40.5, 1.0, 0.5}),
      entry(c, 103, {48.5, 1.0, 0.5}),
      entry(c, 104, {48.499, 1.0, 0.5}),
      # 桶边界两侧 0.001 m
      entry(c, 105, {-16.0005, -8.0005, 15.9995}),
      entry(c, 106, {-15.9995, -7.9995, 16.0005}),
      # 相隔两个桶（< r_N 不可能），以及飞行中的物理体
      entry(c, 107, {60.0, 30.0, 60.0}),
      entry(c, 108, {62.0, 30.0, 61.0}, flight: {{4.0, 1.0, -2.0}, 0.35}),
      entry(c, 109, {58.0, 31.0, 59.0}, flight: {{-30.0, 0.0, 0.0}, 0.1})
    ]

    probes = [{0.0, 1.0, 0.0}, {-0.0, 1.0, -0.0}, {4.0, 4.0, 4.0}, {44.5, 1.0, 0.5}, {-16.0, -8.0, 16.0}, {59.0, 30.0, 60.0}]
    result = assert_equivalent(Enum.sort(ring ++ edges), c.catalog, probes)
    assert result.truncated >= 24 and result.nonempty >= 34
  end

  test "固定种子的随机散布（混合预设、稠密与稀疏两种密度）：新旧逐项相等", c do
    for {n, seed} <- [{200, 1}, {256, 2}] do
      assert_equivalent(Enum.sort(scatter(c, n, seed)), c.catalog)
    end

    # 稠密：120 个挤在 12 m 立方体里，大多数查询有 > 16 个候选。
    :rand.seed(:exsss, {3, 7, 11})
    dense = for k <- 1..120, do: entry(c, k, {:rand.uniform() * 12 - 6, :rand.uniform() * 12, :rand.uniform() * 12 - 6})
    assert assert_equivalent(Enum.sort(dense), c.catalog).truncated > 60
  end

  test "规模：密度不变时每拍查找的比较次数与总工作量与结构数成线性；同一计量下改前的全表扫描按平方增长", c do
    [{256, small}, {1024, large}] =
      for n <- [256, 1024] do
        ordered = Enum.sort(scatter(c, n, n))
        index = Structures.neighbor_index(ordered, c.catalog)
        reference = reference_index(ordered, c.catalog)
        queries = for {id, site} <- index.sites, do: {id, site.position}
        lookup = fn -> for {id, at} <- queries, do: Structures.neighbors_of(index, id, at, c.catalog) end

        # 比较次数：每个候选（相邻 27 桶内的其他结构）恰好算一次距离；候选对数由测试独立数出。
        calls = count_distance_calls(lookup)
        candidates = Enum.count(for {a, sa} <- index.sites, {b, sb} <- index.sites, a != b, adjacent?(sa.bucket, sb.bucket), do: b)
        assert calls == candidates

        work = reductions(lookup)
        reference_work = reductions(fn -> for {id, at} <- queries, do: reference_neighbors(reference, id, at, c.catalog) end)
        {n, %{calls: calls / n, work: work / n, reference: reference_work / n}}
      end

    message = "每结构：256 个时 #{inspect(small)}，1024 个时 #{inspect(large)}"
    # 结构数 ×4：线性实现的每结构量只随边缘效应略增（< 1.5 倍）；改前的全表扫描每结构多看 3 倍的条目（> 2.5 倍），
    # 证明这个计量分辨得出平方增长（Testing.md §5 保留能证伪旧判定的反例）。
    assert large.calls < 1.5 * small.calls, message
    assert large.work < 1.5 * small.work, message
    assert large.reference > 2.5 * small.reference, message
  end

  # 本进程执行 `fun` 消耗的 reductions（BEAM 的确定性工作量计数：函数调用与 BIF 工作，不受调度与墙钟影响）。
  defp reductions(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    fun.()
    {:reductions, later} = Process.info(self(), :reductions)
    later - before
  end
end
