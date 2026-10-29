defmodule VoxelRegion.R5RecoveryPgTest do
  @moduledoc """
  只测试：R5 的隔离 PostgreSQL 联合恢复与真实 60 秒 Replica 历史窗口。
  空气 Source 只替换不可变基底；World、页存储、Replica、物理内核和发布/回放走正式实现。
  WorldClock 只控制物理 timer 运输，便于在同一完成前沿精确比较；Replica 保留仍使用默认真实 60 秒。
  """
  use ExUnit.Case, async: false
  alias DataService.Voxel.{OverlayLogStore, PageStore}
  alias VoxelRegion.{Damage, OverlayLog, Prefab, Replica, TestSupport, World}
  alias VoxelRegion.TestSupport.{Source, WorldClock}
  alias VoxelRegion.World.Pages

  @moduletag :database
  @cv 123
  @cap 2_097_152
  @box {{0, 0, 0}, {3, 1, 1}}
  @budget %{batch_bytes: 1_048_576, inflight_bytes: 4_194_304}

  defmodule MeasuredDb do
    @moduledoc "只测试：原 Db 的调用边界记录固定计数；不更改输入、返回值、顺序或失败语义。"
    alias VoxelRegion.OverlayLog.Db
    defdelegate open(path, cv), to: Db
    defdelegate replay(cv), to: Db
    defdelegate append(cv, txn), to: Db
    defdelegate checkpoint(cv, txn), to: Db
    defdelegate prefix(cv), to: Db
    defdelegate clear_unpublished(cv, prefix), to: Db
    defdelegate load(cv), to: Db
    defdelegate locate(cv, ids), to: Db
    defdelegate page_keys(cv), to: Db

    def load_head(cv, segment) do
      started = System.monotonic_time(:microsecond)
      result = Db.load_head(cv, segment)
      record(%{event: "load_head", elapsed_us: System.monotonic_time(:microsecond) - started,
        prefix: result.prefix, suffix_txns: length(Map.get(result, :txns, [])),
        activity_pages: length(Map.get(result, :activity, [])),
        globals_bytes: byte_size(Map.get(result, :globals, <<>>))})
      result
    end

    def read_pages(cv, keys, fragments) do
      started = System.monotonic_time(:microsecond)
      result = Db.read_pages(cv, keys, fragments)
      record(%{event: "read_pages", elapsed_us: System.monotonic_time(:microsecond) - started,
        requested_pages: length(keys), rows: length(result.rows), encoded_bytes: bytes(result.rows)})
      result
    end

    def write_pages(cv, cut, rows) do
      started = System.monotonic_time(:microsecond)
      result = Db.write_pages(cv, cut, rows)
      record(%{event: "write_pages", seq: cut, rows: length(rows), encoded_bytes: bytes(rows),
        elapsed_us: System.monotonic_time(:microsecond) - started})
      result
    end

    def publish(cv, cut, rows, globals) do
      notify({:r5_publish_started, self(), cut})
      started = System.monotonic_time(:microsecond)
      result = Db.publish(cv, cut, rows, globals)
      record(%{event: "publish", seq: cut, rows: length(rows), encoded_bytes: bytes(rows),
        globals_bytes: byte_size(globals), elapsed_us: System.monotonic_time(:microsecond) - started,
        result: inspect(result)})
      result
    end

    def collect(cv, prefix, limit) do
      count = Db.collect(cv, prefix, limit)
      record(%{event: "collect", prefix: prefix, deleted_rows: count})
      count
    end

    defp bytes(rows), do: Enum.reduce(rows, 0, fn row, total -> total + byte_size(Map.get(row, :payload, <<>>)) end)
    defp notify(message) do
      if pid = :persistent_term.get({__MODULE__, :observer}, nil), do: send(pid, message)
    end
    defp record(row), do: VoxelRegion.R5RecoveryPgTest.record(row)
  end

  setup context do
    MmoTest.Database.start!()
    :ok = OverlayLogStore.reset_world(@cv)
    root = Path.join(System.tmp_dir!(), "r5_pg_#{System.pid()}_#{System.unique_integer([:positive])}")
    prefabs = Path.join(root, "prefabs")
    File.mkdir_p!(prefabs)
    catalog = Path.join(root, "catalog.json")
    data = TestSupport.catalog() |> File.read!() |> Jason.decode!()
      |> Map.put("liquid", %{"step_seconds" => 1.0, "gravity_units_per_step" => div(@cap, 4),
        "side_units_per_step" => div(@cap, 16), "side_threshold_units" => div(@cap, 8)})
    File.write!(catalog, Jason.encode!(data))
    clock = start_supervised!({WorldClock, 0})
    opts = [source: Source, log: MeasuredDb, root: root, observer: self(), name: nil,
      clock: {WorldClock, clock}, property_catalog_path: catalog, prefab_catalog_path: prefabs,
      production_materials: [11, 19, 21], liquid_bounds: {{62, 0, 0}, {68, 16, 5}},
      page_write_budget: @budget]
    :persistent_term.put({MeasuredDb, :observer}, self())
    record(%{event: "test_begin", test: context.test, classification: "Test-only / real isolated PG",
      runtime: %{elixir: System.version(), otp: System.otp_release(),
        erts: to_string(:erlang.system_info(:version)), schedulers: :erlang.system_info(:schedulers_online)}})
    on_exit(fn ->
      :persistent_term.erase({MeasuredDb, :observer})
      File.rm_rf!(root)
    end)
    %{root: root, prefabs: prefabs, clock: clock, opts: opts}
  end

  @tag :r5_recovery
  @tag timeout: 90_000
  test "跨页 g2/g3、有序混合后缀与非空活动在发布/删前缀后精确冷恢复", c do
    world = start_world(c.opts, "initial")
    definition = %{cells: [{{0, 0, 0}, 19}, {{560, 0, 0}, 19}],
      macro_cells: [{{70, 1, 0}, 19}], children: [],
      attachments: [%{slot: 1, kind: 0, axis: 1, anchor: {560, 16, 0}, size: 8, material: 11}]}
    bytes = Prefab.encode(definition)
    id = :crypto.hash(:sha256, bytes)
    File.write!(Path.join(c.prefabs, "cross-page.vxpd"), bytes)
    assert :ok = World.publish_prefabs(world, c.prefabs)
    assert {:ok, birth} = World.place_prefab(world, id, {480, 16, 80}, 0)
    assert {:ok, cells} = World.instance_cells(world, {birth, 0})
    assert Enum.sort(cells) == [{60, 2, 10}, {130, 2, 10}, {130, 3, 10}]
    install_activity(world, c)
    assert World.liquid_activity(world).active_cells > 0
    initial = observe(world)
    identity_rows = Enum.filter(initial.property_states, &(&1.granularity in [2, 3]))
    assert Enum.sort(Enum.map(identity_rows, & &1.granularity)) == [2, 3]
    assert Enum.all?(identity_rows, &(&1.max_hp > 0 and &1.hp == &1.max_hp))
    assert map_size(initial.thermal_accounting.sources) == 1
    assert :ok = World.compact(world)
    prefix = World.seq(world)
    await(fn -> log_count_through(prefix) == 0 end)
    assert PageStore.prefix(@cv) == prefix

    # 正式后缀查询按seq/ordinal一次读取，无64笔或256笔边界。
    # 四笔分别覆盖全局账、同格两次有序覆盖、仅在后缀创建的新身份；不借后缀补写已发布旧整件。
    assert {:ok, _} = World.material_supply(world, 1001, "r5-suffix", %{11 => 1})
    assert {:ok, _} = World.apply_edit(world, {4, 2, 4}, 11)
    assert {:ok, _} = World.apply_edit(world, {4, 2, 4}, 19)
    assert {:ok, new_birth} = World.place_prefab(world, id, {480, 32, 88}, 0)
    assert new_birth == prefix + 4
    assert World.seq(world) == prefix + 4
    assert World.stats(world).suffix_txns == 4
    assert PageStore.prefix(@cv) == prefix
    expected = observe(world)
    expected_payloads = payloads(world)
    record(%{event: "mixed_suffix_ready", prefix: prefix, seq: World.seq(world), suffix_txns: 4,
      g2_g3_count: length(identity_rows), activity_cells: World.liquid_activity(world).active_cells,
      database: database_counts()})

    stop_supervised!(World)
    world = start_world(c.opts, "suffix_restore")
    assert World.simulation_windows(world).source_count == 0
    assert World.liquid_activity(world).active_cells > 0
    assert observe(world) == expected
    assert payloads(world) == expected_payloads
    assert :ok = World.compact(world)
    published = World.seq(world)
    await(fn -> log_count_through(published) == 0 end)
    assert PageStore.prefix(@cv) == published
    assert log_count() == 0
    after_publish = observe(world)
    after_payloads = payloads(world)
    stop_supervised!(World)

    world = start_world(c.opts, "published_restore_without_suffix")
    assert World.simulation_windows(world).source_count == 0
    assert World.liquid_activity(world).active_cells > 0
    assert observe(world) == after_publish
    assert payloads(world) == after_payloads
    # 不注册观察窗口、不再编辑；仅让已恢复的物理timer到期，真实源与活动继续结算。
    before_progress = observe(world)
    WorldClock.advance(c.clock, 1_000)
    await(fn ->
      current = observe(world)
      current.thermal_accounting.elapsed_s >= before_progress.thermal_accounting.elapsed_s + 1.0 and
        current.liquid_quantities != before_progress.liquid_quantities
    end)
    assert World.simulation_windows(world).source_count == 0
    after_progress = observe(world)
    assert after_progress.thermal_accounting.sources[{64, 8, 2}].remaining_j <
      before_progress.thermal_accounting.sources[{64, 8, 2}].remaining_j
    record(%{event: "recovery_pass", suffix_txns: 4, g2_g3_count: length(identity_rows),
      initial_hash: digest(expected), restored_hash: digest(after_publish),
      activity_advanced: true, database: database_counts()})
  end

  @tag :r5_retention
  @tag timeout: 110_000
  test "真实 PG 发布锁阻塞、接纳恢复与默认 60 秒 Replica 保留内存", c do
    opts = Keyword.put(c.opts, :persist_backlog, %{suffix_txns: {3, 6, 9}})
    world = start_world(opts, "slow_writer_initial")
    install_activity(world, c)
    assert :ok = World.compact(world)
    baseline = World.seq(world)
    replica = start_supervised!({Replica, authority_ref: world, l0_box: {{0, 0, 0}, {2, 1, 1}}, name: nil})
    assert Replica.seq(replica) == baseline
    drain_publish_notifications()
    owner = self()
    blocker = Task.async(fn ->
      DataService.Repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(DataService.Repo,
          "SELECT seq FROM voxel_safe_prefix WHERE content_version=$1 FOR UPDATE", [@cv])
        send(owner, {:r5_pg_locked, self()})
        receive do :release_pg -> :ok after 10_000 -> raise "R5 SQL lock release deadline" end
      end, timeout: 15_000)
    end)
    assert_receive {:r5_pg_locked, lock_owner}, 5_000
    compact = try do
      for i <- 1..3, do: assert({:ok, _} = World.apply_edit(world, {i, 2, 4}, 11))
      compact = Task.async(fn -> World.compact(world) end)
      assert_receive {:r5_publish_started, writer, _cut}, 5_000
      assert writer != world
      await(fn -> sql_scalar("SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() " <>
        "AND wait_event_type='Lock' AND query LIKE 'SELECT seq FROM voxel_safe_prefix%FOR UPDATE' " <>
        "AND cardinality(pg_blocking_pids(pid)) > 0", []) > 0 end)
      for i <- 4..6, do: assert({:ok, _} = World.apply_edit(world, {i, 2, 4}, 11))
      assert World.stats(world).persist_level == :mid
      WorldClock.advance(c.clock, 1_500)
      await(fn -> World.stats(world).simulation_progress.thermal.wait_reason == :writeback end)
      assert World.stats(world).simulation_progress.thermal.pending_steps >= 3
      # 已到期的物理输入正确等待旧步；用既有非物理供料入口把积压推到硬上限。
      for i <- 7..9, do: assert({:ok, _} = World.material_supply(world, 1001, "r5-backlog-#{i}", %{11 => 1}))
      assert World.stats(world).persist_level == :hard
      before = observe(world)
      assert {:error, :persist_backlog} = World.material_supply(world, 1001, "r5-rejected", %{11 => 4})
      assert {:error, :persist_backlog} = World.apply_edit(world, {12, 2, 4}, 11)
      assert observe(world) == before
      stats = World.stats(world)
      assert stats.inflight_bytes > 0 and stats.inflight_bytes <= @budget.inflight_bytes
      record(%{event: "pg_writeback_blocked", stats: stat_fields(stats), memory: memory(world, replica, writer)})
      compact
    after
      send(lock_owner, :release_pg)
    end
    assert Task.await(blocker, 5_000) == {:ok, :ok}
    assert Task.await(compact, 15_000) == :ok
    # 放锁以后不投递新物理输入；原due和自动恢复调度消化积压。
    await(fn ->
      stats = World.stats(world)
      current = observe(world)
      stats.persist_level == :ok and not stats.persist_paused and current.thermal_accounting.elapsed_s >= 1.5 and
        current.liquid_quantities != %{{65, 12, 2} => @cap}
    end)
    assert :ok = World.compact(world)
    retention_baseline = World.seq(world)
    await(fn -> Replica.seq(replica) == retention_baseline end)
    # 先等慢写回及其欠账全部发布；随后独立核对两个明确切点之间的尾段，旧通知不能被误当作提前退休。
    for x <- [14, 15], do: assert({:ok, _} = World.apply_edit(world, {x, 2, 4}, 19))
    assert :ok = World.compact(world)
    first = World.seq(world)
    first_at = System.monotonic_time(:millisecond)
    await(fn -> Replica.seq(replica) == first end)
    earlier = Replica.canonical_deltas_after(replica, retention_baseline)
    assert length(earlier) == 2
    # 两个发布确认至少隔一秒，确保观察默认窗口对两个切点的自然退休，而非同毫秒合并。
    Process.send_after(self(), :r5_second_cut_due, max(first_at + 1_000 - System.monotonic_time(:millisecond), 0))
    assert_receive :r5_second_cut_due, 2_000
    assert {:ok, later_seq} = World.apply_edit(world, {13, 2, 4}, 19)
    assert :ok = World.compact(world)
    second_at = System.monotonic_time(:millisecond)
    await(fn -> Replica.seq(replica) == later_seq end)
    all = Replica.canonical_deltas_after(replica, retention_baseline)
    later = Replica.canonical_deltas_after(replica, first)
    assert Enum.map(later, & &1.transaction_seq) == [later_seq]
    assert length(all) == length(earlier) + 1
    retained_before = Replica.stats(replica).retained_deltas
    record(%{event: "replica_retention_begin", baseline: retention_baseline, first: first, last: later_seq,
      first_at_ms: first_at, second_at_ms: second_at, checked_tail_deltas: length(all),
      retained_deltas: retained_before, memory: memory(world, replica)})
    sample_retention(world, replica, first_at + 59_000)
    assert Replica.canonical_deltas_after(replica, retention_baseline) == all
    await(fn -> Replica.stats(replica).baseline_seq >= first end, 8_000)
    elapsed = System.monotonic_time(:millisecond) - second_at
    assert elapsed >= 60_000 - 100
    assert Replica.canonical_deltas_after(replica, first) == later
    assert Replica.canonical_deltas_after(replica, first - 1) == {:error, :before_replica_snapshot}
    assert Replica.stats(replica).retained_deltas == 1
    record(%{event: "replica_retention_pass", elapsed_since_second_ms: elapsed,
      retained_before: retained_before, retained_after: 1, memory: memory(world, replica), database: database_counts()})
  end

  defp install_activity(world, c) do
    assert {:ok, _} = World.apply_edit(world, {64, 8, 2}, 19)
    heat = Path.join(c.root, "heat.json")
    File.write!(heat, Jason.encode!(%{classification: "Test-only", source_macro: [64, 8, 2],
      ambient_kelvin: 293.15, environment_w_per_m2_k: 0.01, tolerance_kelvin: 0.001,
      emissivity: 0.0, view_range_cells: 8, power_w: 1.0, energy_j: 100.0}))
    assert :ok = World.thermal_experiment(world, heat)
    water = Path.join(c.root, "water.json")
    File.write!(water, Jason.encode!(%{classification: "Test-only", deposits: [%{macro: [65, 12, 2], material: 21}]}))
    assert {:ok, _} = World.liquid_experiment(world, water)
  end

  defp start_world(opts, phase) do
    started = System.monotonic_time(:microsecond)
    world = start_supervised!({World, opts})
    record(%{event: "world_started", phase: phase, elapsed_us: System.monotonic_time(:microsecond) - started,
      stats: stat_fields(World.stats(world)), process: process_memory(world)})
    world
  end

  defp observe(world) do
    snapshot = World.simulation_snapshot(world, [1001], @box)
    Map.update!(snapshot, :property_states, &Enum.sort_by(&1, fn row -> Damage.key(row) end))
  end

  defp payloads(world), do: for(region <- [{0, 0, 0}, {1, 0, 0}, {2, 0, 0}], into: %{},
    do: {region, %{TestSupport.payload(world, 0, region) | seq: 0}})
  defp digest(value), do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)
  defp stat_fields(stats), do: Map.take(stats, [:published_seq, :suffix_txns, :dirty_units, :resident_pages,
    :persist_level, :persist_paused, :frozen_ms, :inflight_bytes, :inflight_batches, :pending_unit_bytes,
    :write_batch_limit_bytes, :write_inflight_limit_bytes, :retained_transactions])
  defp process_memory(pid), do: Process.info(pid, [:memory, :heap_size, :total_heap_size, :message_queue_len, :reductions]) |> Map.new()
  defp memory(world, replica, writer \\ nil) do
    %{world: process_memory(world), replica: process_memory(replica),
      writer: if(writer, do: process_memory(writer), else: nil), replica_stats: Map.delete(Replica.stats(replica), :authority_ref)}
  end

  defp sample_retention(world, replica, deadline) do
    record(%{event: "replica_retention_sample", memory: memory(world, replica)})
    now = System.monotonic_time(:millisecond)
    if now < deadline do
      receive do after min(1_000, deadline - now) -> :ok end
      sample_retention(world, replica, deadline)
    end
  end

  defp await(predicate, timeout \\ 10_000), do: await_until(predicate, System.monotonic_time(:millisecond) + timeout)
  defp await_until(predicate, deadline) do
    unless predicate.() do
      assert System.monotonic_time(:millisecond) < deadline
      receive do after 10 -> :ok end
      await_until(predicate, deadline)
    end
  end
  defp drain_publish_notifications do
    receive do {:r5_publish_started, _, _} -> drain_publish_notifications() after 0 -> :ok end
  end
  defp log_count_through(seq), do: sql_scalar("SELECT count(*) FROM voxel_overlay_log WHERE content_version=$1 AND seq <= $2", [@cv, seq])
  defp log_count, do: sql_scalar("SELECT count(*) FROM voxel_overlay_log WHERE content_version=$1", [@cv])
  defp sql_scalar(sql, args), do: Ecto.Adapters.SQL.query!(DataService.Repo, sql, args).rows |> hd() |> hd()
  defp database_counts do
    for {name, table} <- [segments: "voxel_page_segment", globals: "voxel_world_globals", log: "voxel_overlay_log"], into: %{} do
      [[count, bytes]] = Ecto.Adapters.SQL.query!(DataService.Repo,
        "SELECT count(*), COALESCE(sum(octet_length(payload)),0)::bigint FROM #{table} WHERE content_version=$1", [@cv]).rows
      {name, %{rows: count, payload_bytes: bytes}}
    end
    |> Map.put(:locator_rows, sql_scalar("SELECT count(*) FROM voxel_identity_locator WHERE content_version=$1", [@cv]))
  end

  @doc "仅向本轮证据目录追加固定标量；不导出 World 私有状态或原始载荷。"
  def record(row) do
    if root = System.get_env("R5_EVIDENCE_DIR") do
      value = Map.put(row, :monotonic_ms, System.monotonic_time(:millisecond))
      File.write!(Path.join(root, "r5-events.jsonl"), Jason.encode!(value) <> "\n", [:append])
    end
  end
end
