defmodule VoxelRegion.PrefabResidencyTest do
  @moduledoc "只测试：P3冷目录的公开元数据契约；当前待首红运行，不以返回整张World状态测内存。"
  use ExUnit.Case, async: false
  alias VoxelRegion.{Prefab, TestSupport, World}

  test "没有放置请求的World目录只返回轻描述，不搬运完整几何定义" do
    root = Path.join(System.tmp_dir!(), "prefab_residency_#{System.unique_integer([:positive])}")
    catalog_path = Path.join(root, "catalog")
    File.mkdir_p!(catalog_path)
    on_exit(fn -> File.rm_rf!(root) end)

    ids = for offset <- 0..3 do
      cells = for x <- 0..15, y <- 0..3, z <- 0..3, do: {{x + offset * 32, y, z}, 19}
      bytes = Prefab.encode(%{cells: cells, macro_cells: [], children: [], attachments: []})
      id = :crypto.hash(:sha256, bytes)
      File.write!(Path.join(catalog_path, Base.encode16(id, case: :lower) <> ".vxpd"), bytes)
      id
    end

    world = start_supervised!({World, [source: TestSupport.Source, log: TestSupport.Log,
      root: root, observer: self(), name: nil, prefab_catalog_path: catalog_path,
      property_catalog_path: TestSupport.catalog()]})
    catalog = World.prefab_catalog(world)
    assert MapSet.new(Map.keys(catalog)) == MapSet.new(ids)
    assert World.seq(world) == 0
    leaks = for {id, entry} <- catalog,
      Map.has_key?(entry, :nodes) or match?(%{definition: %{cells: _}}, entry),
      do: Base.encode16(id, case: :lower)
    IO.inspect(%{definitions: map_size(catalog), returned_words: :erts_debug.size(catalog),
      geometry_entries: length(leaks)}, label: "PREFAB_COLD_CATALOG")
    assert leaks == []
  end

  test "按id保留四版原字节，geometry及草稿只准备实际子闭包并释放请求" do
    root = Path.join(System.tmp_dir!(), "prefab_versions_#{System.unique_integer([:positive])}")
    path = Path.join(root, "catalog")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(root) end)
    cell = <<0::signed-little-32, 0::signed-little-32, 0::signed-little-32, 19::16-little>>
    v1 = <<"VXPD", 1::32-little, 1::32-little, cell::binary, 0::32-little>>
    v2 = <<"VXPD", 2::32-little, 1::32-little, cell::binary, 0::32-little, 0::32-little>>
    v3 = Prefab.encode(%{cells: [], macro_cells: [{{0,0,0},19}], children: [], attachments: []})
    v4 = Prefab.encode(%{cells: [], macro_cells: [{{0,0,0},73}], children: [], attachments: [], presentation_bindings: %{73 => 1}})
    originals = Map.new([v1,v2,v3,v4], fn bytes ->
      id = :crypto.hash(:sha256, bytes)
      File.write!(Path.join(path, Base.encode16(id, case: :lower) <> ".vxpd"), bytes)
      {id,bytes}
    end)
    world = start_supervised!({World, [source: TestSupport.Source, log: TestSupport.Log, root: root,
      observer: self(), name: nil, prefab_catalog_path: path, property_catalog_path: TestSupport.catalog(), payload_cache_bytes: 131_072]})
    for {id, bytes} <- originals do
      assert {:ok, ^bytes} = World.prefab_definition(world, id)
      assert {:ok, geometry} = World.prefab_geometry(world, id)
      assert is_map(geometry.material_counts)
      refute Map.has_key?(geometry.definition, :cells)
    end
    leaf = :crypto.hash(:sha256, v1)
    draft = Prefab.encode(%{cells: [], macro_cells: [], attachments: [],
      children: [%{slot: 1, definition_id: leaf, anchor: {16,0,0}, orientation: 0}]})
    draft_id = :crypto.hash(:sha256, draft)
    assert {:ok, ^draft_id, compiled} = World.compile_prefab(world, draft)
    assert Prefab.footprint(compiled, {0,0,0}, 0) == [{{16,0,0},19}]
    assert {:ok, ^draft_id, _, %{publishable: true}} = World.preview_prefab(world, draft)
    assert {:error, :definition_not_found} = World.prefab_definition(world, <<0::256>>)
    stats = World.stats(world)
    assert stats.prefab_residency.preparing == 0
    assert stats.prefab_residency.source_inflight_bytes == 0
    assert stats.shared_cache.pins == 0
    assert stats.page_waiters == 0
    assert stats.shared_cache.namespaces.prefab.entries == 4
  end

  test "原bytes只读取请求id，子源丢失只使需要几何的请求显式失败" do
    leaf = Prefab.encode(%{cells: [{{0,0,0},19}], macro_cells: [], children: [], attachments: []})
    leaf_id = :crypto.hash(:sha256, leaf)
    parent = Prefab.encode(%{cells: [], macro_cells: [], attachments: [],
      children: [%{slot: 1, definition_id: leaf_id, anchor: {8,0,0}, orientation: 0}]})
    parent_id = :crypto.hash(:sha256, parent)
    {world, path} = catalog_world([leaf, parent])
    File.rm!(Path.join(path, Base.encode16(leaf_id, case: :lower) <> ".vxpd"))
    assert {:ok, ^parent} = World.prefab_definition(world, parent_id)
    assert {:error, {:definition_read, :enoent}} = World.prefab_geometry(world, parent_id)
    assert World.stats(world).shared_cache.pins == 0
    assert World.stats(world).prefab_residency.preparing == 0
  end

  test "准备caller退出停止其worker并释放唯一monitor及cache pin" do
    bytes = Prefab.encode(%{cells: [{{0,0,0},19}], macro_cells: [], children: [], attachments: []})
    id = :crypto.hash(:sha256, bytes)
    {world, _path} = catalog_world([bytes])
    assert {:ok, ^bytes} = World.prefab_definition(world, id)
    parent = self()
    hook = fn debug, event, _ ->
      case event do
        {:in, {:"$gen_call", {worker, _}, {:prefab_inputs, _, _}}} ->
          unless Process.get(:prefab_test_held, false) do
            Process.put(:prefab_test_held, true)
            send(parent, {:prefab_worker, worker})
            receive do: (:continue_prefab_test -> :ok)
          end
        _ -> :ok
      end
      debug
    end
    :ok = :sys.install(world, {hook, nil})
    on_exit(fn -> send(world, :continue_prefab_test) end)
    caller = spawn(fn -> World.prefab_geometry(world, id) end)
    assert_receive {:prefab_worker, worker}, 1_000
    monitor = Process.monitor(worker)
    :erlang.suspend_process(worker)
    send(world, :continue_prefab_test)
    try do
      assert World.stats(world).prefab_residency.preparing == 1
      assert World.stats(world).shared_cache.pins == 1
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
      await(fn -> World.stats(world).prefab_residency.preparing == 0 end)
      stats = World.stats(world)
      assert stats.prefab_residency.source_inflight_bytes == 0
      assert stats.shared_cache.pins == 0
      assert stats.page_waiters == 0
    after
      if Process.alive?(worker), do: Process.exit(worker, :kill)
      if Process.alive?(caller), do: Process.exit(caller, :kill)
    end
  end

  test "冷源损坏与零缓存预算都显式失败并退休请求" do
    bytes = Prefab.encode(%{cells: [{{0,0,0},19}], macro_cells: [], children: [], attachments: []})
    id = :crypto.hash(:sha256, bytes)
    {world, path} = catalog_world([bytes], payload_cache_bytes: 0)
    assert {:error, {:definition_cache, :too_large}} = World.prefab_definition(world, id)
    assert World.stats(world).prefab_residency.preparing == 0
    assert World.stats(world).page_waiters == 0
    File.write!(Path.join(path, Base.encode16(id, case: :lower) <> ".vxpd"), "broken")
    assert {:error, :definition_content_mismatch} = World.prefab_geometry(world, id)
    stats = World.stats(world)
    assert stats.shared_cache.pins == 0
    assert stats.prefab_residency.source_inflight_bytes == 0
    assert stats.prefab_residency.preparing == 0
    assert stats.page_waiters == 0
  end

  test "冷几何文件读取不在World回调内执行" do
    bytes = Prefab.encode(%{cells: [{{0,0,0},19}], macro_cells: [], children: [], attachments: []})
    id = :crypto.hash(:sha256, bytes)
    {world, _} = catalog_world([bytes])
    :erlang.trace_pattern({File, :read, 1}, true, [:local])
    :erlang.trace(world, true, [:call, :arity])
    try do
      assert {:ok, _} = World.prefab_geometry(world, id)
      marker = :erlang.trace_delivered(world)
      assert_receive {:trace_delivered, ^world, ^marker}
      refute_received {:trace, ^world, :call, {File, :read, 1}}
    after
      :erlang.trace(world, false, [:call])
      :erlang.trace_pattern({File, :read, 1}, false, [:local])
    end
  end

  test "有界共享缓存逐出定义后按同id重读，源失败不借旧解码副本兜底" do
    definitions = for offset <- [0, 16] do
      cells = for x <- 0..7, y <- 0..7, z <- 0..7, do: {{x + offset,y,z},19}
      Prefab.encode(%{cells: cells, macro_cells: [], children: [], attachments: []})
    end
    [a, b] = definitions
    a_id = :crypto.hash(:sha256, a)
    b_id = :crypto.hash(:sha256, b)
    {world, path} = catalog_world(definitions, payload_cache_bytes: 12_000)
    assert {:ok, ^a} = World.prefab_definition(world, a_id)
    assert {:ok, ^b} = World.prefab_definition(world, b_id)
    stats = World.stats(world)
    assert stats.shared_cache.bytes <= 12_000
    assert stats.shared_cache.namespaces.prefab.entries == 1
    target = Path.join(path, Base.encode16(a_id, case: :lower) <> ".vxpd")
    File.rm!(target)
    assert {:error, {:definition_read, :enoent}} = World.prefab_definition(world, a_id)
    File.write!(target, a)
    assert {:ok, ^a} = World.prefab_definition(world, a_id)
    assert World.stats(world).shared_cache.pins == 0
    assert World.stats(world).prefab_residency.preparing == 0
  end

  defp catalog_world(definitions, opts \\ []) do
    root = Path.join(System.tmp_dir!(), "prefab_prepare_#{System.unique_integer([:positive])}")
    path = Path.join(root, "catalog")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(root) end)
    for bytes <- definitions do
      id = :crypto.hash(:sha256, bytes)
      File.write!(Path.join(path, Base.encode16(id, case: :lower) <> ".vxpd"), bytes)
    end
    world = start_supervised!({World, Keyword.merge([source: TestSupport.Source, log: TestSupport.Log, root: root,
      observer: self(), name: nil, prefab_catalog_path: path, property_catalog_path: TestSupport.catalog()], opts)})
    {world, path}
  end

  defp await(fun), do: await(fun, System.monotonic_time(:millisecond) + 1_000)
  defp await(fun, deadline) do
    unless fun.() do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(1)
      await(fun, deadline)
    end
  end
end
