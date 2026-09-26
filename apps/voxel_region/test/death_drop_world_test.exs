defmodule VoxelRegion.DeathDropWorldTest do
  @moduledoc """
  只测试：身体闭环 H2 死亡掉落（Voxim Docs/Magic.md §6.10）经真实 World：Scene 送来 `{:body_death, cid, 脚位}`，
  World 按确定性掷骰 5% 从死者余额里选一种有 1/8 m³ 世界形态的可放置材料，写到死亡点附近第一个可用空格并同量扣余额。

  目录 = 散体测试目录 `7b69b79f…`（沙 5、煤 15、铜矿 16 等带休止阈值，可倾倒；花草 32–39 单次放置 262 144 = 1/8 m³）。
  单格容量 2 097 152（每微格 4096 × 512），1/8 m³ = 262 144。
  掷骰契约（与 `drop_roll` 同一公式，独立在测试里算）：sha256(<<cv::64, seq + 1::64, x, y, z 各 ::64-signed, index::16>>)
  前 32 位 / 2³²；index 0 判是否掉（< 0.05），index 1 在按材料 id 排序的候选里选 ⌊roll × 候选数⌋。
  材料只经 material_supply（一次、记账）；地形只经作者编辑。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.{Source, Log}

  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @loose "7b69b79f1786756e857fb8cc0c855e911ce1d015ca2a5efdb25fc76f2a52b45e"
  @cap 2_097_152
  @eighth 262_144
  @sand 5
  @dirt 7
  @stone 11
  @coal 15
  @ore 16
  @water 21
  @dandelion 36
  @box {{-9, -1, -9}, {17, 8, 17}}

  setup do
    root = Path.join(System.tmp_dir!(), "death_drop_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    data = Jason.decode!(File.read!(Path.join(@fixtures, @loose <> ".json")))
    data = put_in(data, ["liquid", "step_seconds"], 3600)
    catalog = Path.join(root, "properties.json")
    File.write!(catalog, Jason.encode!(data))
    env = Path.join(root, "environment.json")
    File.cp!(Path.join(@fixtures, "environment.json"), env)

    w = start_supervised!({World, [source: Source, log: Log, root: root, observer: self(), name: nil,
      property_catalog_path: catalog, thermal_environment_path: env,
      production_materials: [@sand, @stone, @coal, @ore, @water, @dandelion],
      liquid_bounds: {{0, 0, 0}, {8, 8, 8}}]})

    {:ok, _} = World.apply_edits(w, for(x <- -8..15, z <- -8..15, do: {{x, 0, z}, @dirt}))
    {:ok, _} = World.material_supply(w, 1001, "death-drop",
      %{@sand => 8 * @cap, @stone => 16 * @cap, @coal => 4 * @cap, @ore => @cap, @water => @cap})
    %{w: w}
  end

  defp roll(w, {x, y, z}, index) do
    <<n::32, _::binary>> =
      :crypto.hash(:sha256, <<:sys.get_state(w).cv::64, World.seq(w) + 1::64, x::64-signed, y::64-signed,
        z::64-signed, index::16>>)

    n / 4_294_967_296
  end

  defp die(w, cid, {x, y, z}) do
    send(w, {:body_death, cid, {x + 0.5, y * 1.0, z + 0.5}})
    World.seq(w)
  end

  defp balances(w, cid), do: VoxelRegion.TestSupport.observe(w, [cid], @box).material_balances
  defp quantities(w), do: VoxelRegion.TestSupport.observe(w, [1001], @box).liquid_units
  defp material(w, cell), do: hd(World.material_snapshot(w, [], [cell]).probe_occupancy).material
  defp find(w, cells, pred), do: Enum.find(cells, &pred.(roll(w, &1, 0)))

  @inside for y <- 1..6, x <- 0..7, z <- 0..7, do: {x, y, z}
  @floor for x <- -8..15, z <- -8..15, do: {x, 1, z}

  test "掷骰 ≥ 5% 不掉；< 5% 掉 1/8 m³ 散体到死亡格：余额减少 = 世界格数量 = 262 144，其余材料不变", %{w: w} do
    miss = find(w, @inside, &(&1 >= 0.05))
    before = balances(w, 1001)
    seq = World.seq(w)
    assert die(w, 1001, miss) == seq
    assert balances(w, 1001) == before

    hit = find(w, @inside, &(&1 < 0.05))
    # 候选按 id 排序：沙 5、煤 15、铜矿 16（石头整格、水是液体，都不参选）
    expected = Enum.at([@sand, @coal, @ore], floor(roll(w, hit, 1) * 3))
    assert die(w, 1001, hit) == seq + 1
    after_drop = balances(w, 1001)
    assert before[{1001, expected}] - after_drop[{1001, expected}] == @eighth
    assert Map.delete(after_drop, {1001, expected}) == Map.delete(before, {1001, expected})
    assert quantities(w)[hit] == @eighth
    assert material(w, hit) == expected
  end

  test "只选有 1/8 m³ 形态且余额 ≥ 1/8 m³ 的可放置材料：整格石、液体水、不足 1/8 的沙都不参选；唯一候选蒲公英放置成一格；无候选不掉", %{w: w} do
    {:ok, _} = World.material_supply(w, 2002, "death-drop-2",
      %{@stone => 16 * @cap, @water => @cap, @sand => @eighth - 1, @dandelion => @eighth})
    {:ok, _} = World.material_supply(w, 3003, "death-drop-3", %{@stone => 16 * @cap, @water => @cap, @sand => @eighth - 1})
    hit = find(w, @floor, &(&1 < 0.05))
    seq = World.seq(w)
    before = balances(w, 3003)
    assert die(w, 3003, hit) == seq
    assert balances(w, 3003) == before

    before = balances(w, 2002)
    assert die(w, 2002, hit) == seq + 1
    after_drop = balances(w, 2002)
    assert Map.get(after_drop, {2002, @dandelion}, 0) == 0
    assert Map.delete(after_drop, {2002, @dandelion}) == Map.delete(before, {2002, @dandelion})
    assert material(w, hit) == @dandelion
  end

  test "死亡点在他人地块内不掉（即使掷骰 < 5%）", %{w: w} do
    {:ok, _} = World.author_regions(w, [%{holder: {:character, 9009}, min: {-8, -8}, max: {15, 15}}])
    hit = find(w, @inside, &(&1 < 0.05))
    before = balances(w, 1001)
    seq = World.seq(w)
    assert die(w, 1001, hit) == seq
    assert balances(w, 1001) == before
    assert quantities(w)[hit] == nil
  end
end
