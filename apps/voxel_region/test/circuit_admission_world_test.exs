defmodule VoxelRegion.CircuitAdmissionWorldTest do
  @moduledoc "只测试：正常玩家建造在唯一World提交前裁决潜在人工导电分量，不用私有状态填充来源。"
  use ExUnit.Case, async: false
  alias VoxelRegion.{Prefab, TestSupport, World}
  alias VoxelRegion.TestSupport.{Actor, Source, SimulationIoLog, WorldClock}

  @capacity 2_097_152
  @catalog Path.expand("fixtures/combustion/b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec.json", __DIR__)

  setup context do
    root = Path.join(System.tmp_dir!(), "circuit_admission_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    clock = start_supervised!({WorldClock, 0})
    opts = [source: Source, root: root, observer: self(), name: nil, clock: {WorldClock, clock},
      property_catalog_path: @catalog, prefab_catalog_path: Path.join(root, "prefabs"),
      production_materials: [24]]
    opts = if context[:default_limit], do: opts, else: Keyword.put(opts, :circuit_component_limit, 1)
    opts = if context[:cold], do: Keyword.put(opts, :log, SimulationIoLog), else: opts
    world = start_supervised!({World, opts})
    actor = %{cid: 1001, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2,
      eye: {0.5, 1.5, -1.0}, tick_us: 16_667}
    actor = Map.put(actor, :player, start_supervised!({Actor, actor}))
    on_exit(fn -> SimulationIoLog.clear(); File.rm_rf!(root) end)
    %{world: world, actor: actor, root: root, opts: opts}
  end

  test "玩家Prefab微格放置超限拒绝，同潜在拓扑替换保留已接纳分量", c do
    assert {:ok, _} = World.material_supply(c.world, 1001, "d11-prefab", %{24 => @capacity})
    publish = fn cells ->
      bytes = Prefab.encode(%{cells: cells, macro_cells: [], children: [], attachments: []})
      {:ok, id} = World.publish_prefab(c.world, c.actor, bytes)
      id
    end
    two = publish.([{{0, 0, 0}, 24}, {{1, 0, 0}, 24}])
    request = %{definition_id: two, anchor: {0, 8, 8}, orientation: 0, client_intent_seq: 1}
    seq = World.seq(c.world)
    balance = World.material_balances(c.world, 1001)
    assert {:error, :circuit_component_limit} = World.prefab_intent(c.world, c.actor, :voxel_prefab_place_v1, request)
    assert World.seq(c.world) == seq
    assert World.material_balances(c.world, 1001) == balance
    one = publish.([{{0, 0, 0}, 24}])
    assert {:ok, birth} = World.prefab_intent(c.world, c.actor, :voxel_prefab_place_v1,
      %{request | definition_id: one, client_intent_seq: 2})
    assert {:ok, _} = World.prefab_intent(c.world, c.actor, :voxel_prefab_replace_v1,
      %{definition_id: one, instance_id: {birth, 0}, client_intent_seq: 3})
  end

  test "附件逐件接纳且拒绝不扣料", c do
    assert {:ok, _} = World.apply_edits(c.world, [{{0, 0, 1}, 11}])
    assert {:ok, _} = World.material_supply(c.world, 1001, "d11-wire", %{24 => @capacity})
    request = %{request_id: 1, client_intent_seq: 1, logical_scene_id: 1, action: 0,
      kind: 1, axis: 0, size: 1, anchor: {0, 8, 8}, id: 0, material: 24, tool_id: 1}
    assert {:ok, seq} = World.attachment_intent(c.world, c.actor, request)
    balance = World.material_balances(c.world, 1001)
    assert {:error, :circuit_component_limit} = World.attachment_intent(c.world, c.actor,
      %{request | request_id: 2, client_intent_seq: 2, anchor: {1, 8, 8}})
    assert World.seq(c.world) == seq
    assert World.material_balances(c.world, 1001) == balance
  end

  @tag :default_limit
  test "实测默认容量27的公开完整新连接通过而第28格拒绝", c do
    assert {:ok, _} = World.material_supply(c.world, 1001, "d11-default", %{24 => 28 * @capacity})
    cells = for x <- 0..2, y <- 0..2, z <- 0..2, {x, y, z} != {2, 2, 2}, do: {{x, y, z}, 24}
    bytes = Prefab.encode(%{cells: [], macro_cells: cells, children: [], attachments: []})
    assert {:ok, id} = World.publish_prefab(c.world, c.actor, bytes)
    assert {:ok, _} = World.prefab_intent(c.world, c.actor, :voxel_prefab_place_v1,
      %{definition_id: id, anchor: {0, 8, 8}, orientation: 0, client_intent_seq: 1})
    request = %{request_id: 2, client_intent_seq: 2, logical_scene_id: 1, action: 1,
      tool_id: 1, material: 24, coord: {2, 3, 3}}
    {elapsed, result} = :timer.tc(fn -> World.production_intent(c.world, c.actor, request) end)
    assert {:ok, seq} = result
    assert World.stats(c.world).circuit_component_limit == 27
    balance = World.material_balances(c.world, 1001)
    assert {:error, :circuit_component_limit} = World.production_intent(c.world, c.actor,
      %{request | request_id: 3, client_intent_seq: 3, coord: {3, 3, 3}})
    assert World.seq(c.world) == seq
    assert World.material_balances(c.world, 1001) == balance
    assert [%{material: 0}] = World.material_snapshot(c.world, [], [{3, 3, 3}]).probe_occupancy
    IO.puts("D11_WORLD_BOUNDARY " <> Jason.encode!(%{limit: 27, complete_new_connection_us: elapsed,
      accepted_seq: seq, rejected_units: 28}))
  end

  @tag :cold
  test "潜在分量冷页等待不提交，取消后同一请求重新发现完整分量并拒绝", c do
    assert {:ok, _} = World.apply_edits(c.world, for(x <- 2..129, do: {{x, 1, 1}, 24}))
    assert {:ok, _} = World.material_supply(c.world, 1001, "d11-cold", %{24 => 2 * @capacity})
    assert :ok = GenServer.call(c.actor.player, {:eye, {130.5, 1.5, -1.0}})
    request = %{request_id: 1, client_intent_seq: 1, logical_scene_id: 1, action: 1,
      tool_id: 1, material: 24, coord: {130, 1, 1}}
    assert {:ok, seq} = World.production_intent(c.world, c.actor, request)
    assert :ok = World.compact(c.world)
    stop_supervised!(World)
    world = start_supervised!({World, c.opts})
    assert :ok = GenServer.call(c.actor.player, {:eye, {0.5, 1.5, -1.0}})
    cold = {0, {2, 0, 0}}
    refute VoxelRegion.World.Pages.resident?(:sys.get_state(world), cold)
    balance = World.material_balances(world, 1001)
    request = %{request | request_id: 2, client_intent_seq: 2, coord: {1, 1, 1}}
    SimulationIoLog.mode(:hold, self(), cold)
    parent = self()
    caller = spawn(fn -> send(parent, {:admitted, World.production_intent(world, c.actor, request)}) end)
    assert_receive {:simulation_io_read, reader, ^cold}, 10_000
    assert World.seq(world) == seq
    assert World.material_balances(world, 1001) == balance
    Process.exit(caller, :kill)
    await(fn -> map_size(:sys.get_state(world).page_load.callers) == 0 end)
    SimulationIoLog.clear()
    send(reader, :continue)
    assert {:error, :circuit_component_limit} = World.production_intent(world, c.actor, request)
    assert World.seq(world) == seq
    assert World.material_balances(world, 1001) == balance
    assert [%{material: 0}] = World.material_snapshot(world, [], [{1, 1, 1}]).probe_occupancy
  end

  defp await(fun, remaining \\ 100)
  defp await(fun, remaining) when remaining > 0 do
    if fun.(), do: :ok, else: (Process.sleep(10); await(fun, remaining - 1))
  end
  defp await(_fun, 0), do: flunk("已取消请求未退休")

  test "第二人工宏格使潜在分量超过1时拒接且不扣料、不递增序号", c do
    assert {:ok, _} = World.material_supply(c.world, 1001, "d11-material", %{24 => 2 * @capacity})
    request = %{request_id: 1, client_intent_seq: 1, logical_scene_id: 1, action: 1,
      tool_id: 1, material: 24, coord: {0, 1, 1}}
    assert {:ok, first} = World.production_intent(c.world, c.actor, request)
    balances = World.material_balances(c.world, 1001)
    assert {:error, :circuit_component_limit} = World.production_intent(c.world, c.actor,
      %{request | request_id: 2, client_intent_seq: 2, coord: {1, 1, 1}})
    assert World.seq(c.world) == first
    assert World.material_balances(c.world, 1001) == balances
    assert [%{material: 0}] = World.material_snapshot(c.world, [], [{1, 1, 1}]).probe_occupancy
    assert TestSupport.payload(c.world, 0, {0, 0, 0}).seq == first
  end
end
