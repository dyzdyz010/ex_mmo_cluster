defmodule VoxelRegion.PersistBacklogTest do
  @moduledoc """
  只测试：受控慢写回下的积压接纳（m2a §5.3）。真值只经正常入口产生（作者实验、编辑、供料）；故障只注入在写回的发布边界
  （测试后端把写回进程停在发布点），不改 World 状态、切点或接纳算法。积压上限经 World 启动选项配小。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.Source

  @capacity 2_097_152
  @box {{60, 0, 0}, {68, 5, 5}}

  defmodule HoldLog do
    @moduledoc "只测试：文件后端；登记了停点时，下一次发布前把写回进程停在发布点（报 `{:holding_publish, 写回进程, 切点}`，收到 `:continue` 再发布）。"
    alias VoxelRegion.OverlayLog.File, as: Log
    defdelegate open(path, cv), to: Log
    defdelegate replay(path), to: Log
    defdelegate append(path, txn), to: Log
    defdelegate checkpoint(path, txn), to: Log
    defdelegate prefix(path), to: Log
    defdelegate clear_unpublished(path, prefix), to: Log
    defdelegate write_pages(path, cut, rows), to: Log
    defdelegate load(path), to: Log
    defdelegate collect(path, prefix, limit), to: Log

    def publish(path, cut, rows, globals) do
      case :persistent_term.get({__MODULE__, path}, nil) do
        owner when is_pid(owner) ->
          :persistent_term.erase({__MODULE__, path})
          send(owner, {:holding_publish, self(), cut})
          receive do :continue -> :ok end

        _ ->
          :ok
      end

      Log.publish(path, cut, rows, globals)
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "persist_backlog_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    on_exit(fn -> File.rm_rf!(root) end)
    catalog = Path.join(root, "catalog.json")
    # 只测试节拍：液体 50 ms 一步，让积压在几百毫秒内由后台步进自然涨到中上限。
    data = VoxelRegion.TestSupport.catalog() |> File.read!() |> Jason.decode!()
      |> Map.put("liquid", %{"step_seconds" => 0.05, "gravity_units_per_step" => div(@capacity, 4),
        "side_units_per_step" => div(@capacity, 16), "side_threshold_units" => 0})
    File.write!(catalog, Jason.encode!(data))
    opts = [source: Source, log: HoldLog, root: root, observer: self(), name: nil, property_catalog_path: catalog,
      prefab_catalog_path: Path.join(root, "prefabs"), production_materials: [19, 21], liquid_bounds: {{62, 0, 1}, {66, 4, 4}},
      persist_backlog: %{suffix_txns: {3, 6, 9}}]
    %{root: root, opts: opts}
  end

  test "受控慢写回：中上限暂停热 / 液体步进，硬上限在扣账前拒绝提交，写回恢复后无新输入也恢复调度", c do
    w = start_supervised!({World, c.opts})
    # 全新世界的首个切点发布 P = 0；之后的下一次发布停在发布点。
    assert :ok = World.compact(w)
    :persistent_term.put({HoldLog, Path.join(c.root, "overlay.log")}, self())
    on_exit(fn -> :persistent_term.erase({HoldLog, Path.join(c.root, "overlay.log")}) end)

    # 热源（1 W、100 J，持续远长于本例）与会下落、摊开的有限水：二者都由后台定时步进提交。
    assert {:ok, _} = World.apply_edit(w, {63, 1, 2}, 16)
    heat = Path.join(c.root, "heat.json")
    File.write!(heat, Jason.encode!(%{classification: "Test-only", source_macro: [63, 1, 2],
      ambient_kelvin: 293.15, environment_w_per_m2_k: 0.01, tolerance_kelvin: 1.0,
      emissivity: 0.0, view_range_cells: 8, power_w: 1.0, energy_j: 100.0}))
    assert :ok = World.thermal_experiment(w, heat)
    water = Path.join(c.root, "water.json")
    File.write!(water, Jason.encode!(%{classification: "Test-only", deposits: [%{macro: [65, 3, 3], material: 21}]}))
    assert {:ok, _} = World.liquid_experiment(w, water)

    # 超软上限立即排切点；写回停在发布点，后台步进把后缀推过中上限后暂停（不再开始新步进）。
    assert_receive {:holding_publish, writer, cut}, 5_000

    paused = try do
      refute writer == w
      await(fn ->
        state = :sys.get_state(w)
        state.page_store.paused and state.liquid_timer == nil and state.thermal_timer == nil and state.thermal_run == nil
      end)

      stats = World.stats(w)
      assert stats.persist_level == :mid and stats.published_seq == 0 and stats.suffix_txns >= 6
      assert stats.frozen_ms > 0 and stats.inflight_bytes > 0 and stats.oldest_dirty_ms > 0
      paused = World.liquid_activity(w)
      assert paused.active_cells > 0 and not paused.scheduled
      paused_at = observe(w)
      assert paused_at.thermal.active

      # 正常提交继续被接纳，直到硬上限。
      Enum.reduce_while(1..20, nil, fn i, _ ->
        assert {:ok, _} = World.material_supply(w, 1001, "backlog-#{i}", %{19 => 1})
        if World.stats(w).persist_level == :hard, do: {:halt, :ok}, else: {:cont, nil}
      end)

      assert World.stats(w).persist_level == :hard
      seq = World.seq(w)
      before = observe(w)
      assert {:error, :persist_backlog} = World.material_supply(w, 1001, "rejected", %{19 => 5})
      assert {:error, :persist_backlog} = World.apply_edit(w, {62, 3, 1}, 11)
      assert {:error, :persist_backlog} = World.apply_edits(w, [{{62, 3, 1}, 11}, {{63, 3, 1}, 11}])
      # 查询不受接纳边界影响；被拒的提交不改世界、余额与序号。
      assert [%{balance: _}, %{balance: _}] = World.material_balances(w, 1001)
      assert World.seq(w) == seq
      assert observe(w) == before
      paused
    after
      send(writer, :continue)
    end

    assert cut > 0
    # 写回确认后积压回落（必要时由下一个切点继续收口），被暂停的热与液体调度自动恢复：不发任何新输入。
    await(fn -> match?(%{persist_level: :ok, persist_paused: false}, World.stats(w)) end)
    resumed = observe(w)
    await(fn ->
      now = observe(w)
      now.thermal.elapsed_s > resumed.thermal.elapsed_s and
        (now.liquid_units != resumed.liquid_units or World.liquid_activity(w).active_cells != paused.active_cells)
    end)
    assert {:ok, _} = World.material_supply(w, 1001, "after", %{19 => 5})
  end

  # 死亡掉落是已确认死亡的后果、不是新意图：硬上限下照常提交（m2a §5.3），被拒即物品永久丢失。
  # 场景同 death_drop_world_test：散体目录（沙 5 可倾倒）、作者铺地、一次记账供料；掉落概率经启动参数配成 1。
  test "硬上限下死亡掉落仍提交：余额减少 = 世界格数量 = 1/8 m³，物品不丢", c do
    sand = 5
    eighth = div(@capacity, 8)
    data = Path.expand("fixtures/combustion/7b69b79f1786756e857fb8cc0c855e911ce1d015ca2a5efdb25fc76f2a52b45e.json", __DIR__)
      |> File.read!() |> Jason.decode!() |> put_in(["liquid", "step_seconds"], 3600)
    catalog = Path.join(c.root, "loose.json")
    File.write!(catalog, Jason.encode!(data))
    opts = Keyword.merge(c.opts, property_catalog_path: catalog, production_materials: [sand],
      liquid_bounds: {{0, 0, 0}, {8, 8, 8}}, death_drop_probability: 1.0)
    w = start_supervised!({World, opts})
    {:ok, _} = World.apply_edits(w, for(x <- 0..7, z <- 0..7, do: {{x, 0, z}, 7}))
    {:ok, _} = World.material_supply(w, 1001, "death-drop", %{sand => 8 * @capacity})
    assert :ok = World.compact(w)
    :persistent_term.put({HoldLog, Path.join(c.root, "overlay.log")}, self())
    on_exit(fn -> :persistent_term.erase({HoldLog, Path.join(c.root, "overlay.log")}) end)

    # 小额供料推高后缀；超软上限排出的切点停在发布点，积压停在硬上限。
    Enum.reduce_while(1..20, nil, fn i, _ ->
      assert {:ok, _} = World.material_supply(w, 2002, "backlog-#{i}", %{sand => 1})
      if World.stats(w).persist_level == :hard, do: {:halt, :ok}, else: {:cont, nil}
    end)

    assert_receive {:holding_publish, writer, _cut}, 5_000

    try do
      assert {:error, :persist_backlog} = World.material_supply(w, 1001, "rejected", %{sand => 1})
      cell = {3, 1, 3}
      seq = World.seq(w)
      before = VoxelRegion.TestSupport.observe(w, [1001], {{-9, -1, -9}, {17, 8, 17}})
      send(w, {:body_death, 1001, {3.5, 1.0, 3.5}})
      assert World.seq(w) == seq + 1
      after_drop = VoxelRegion.TestSupport.observe(w, [1001], {{-9, -1, -9}, {17, 8, 17}})
      assert before.material_balances[{1001, sand}] - after_drop.material_balances[{1001, sand}] == eighth
      assert after_drop.liquid_units[cell] == eighth
      assert World.stats(w).persist_level == :hard
    after
      send(writer, :continue)
    end

    # 写回放行后掉落随后续切点发布（压实覆盖到含掉落的 seq 才返回）。
    assert :ok = World.compact(w)
  end

  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [1001], @box)

  defp await(predicate, attempts \\ 500) do
    if predicate.() do
      :ok
    else
      assert attempts > 0
      Process.sleep(10)
      await(predicate, attempts - 1)
    end
  end
end
