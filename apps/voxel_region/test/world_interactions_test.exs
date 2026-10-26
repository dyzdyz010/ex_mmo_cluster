defmodule VoxelRegion.WorldInteractionsTest do
  @moduledoc "只测试：真实 World 意图与文件日志；角色上下文/空气源是替身，不证明玩家网络链路。"
  use ExUnit.Case, async: false
  alias VoxelRegion.{World, OverlayLog}
  alias VoxelRegion.TestSupport.{Source, Actor, Log}

  setup context do
    if context[:database], do: (MmoTest.Database.start!(); DataService.Voxel.OverlayLogStore.reset())

    root =
      Path.join(
        System.tmp_dir!(),
        "world_interactions_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    catalog = Path.join(root, "properties.json")

    materials =
      for id <- 0..23,
          do: %{
            material_id: id,
            max_hp_per_macro: if(id == 0, do: 0.0, else: 100_000.0),
            defense: 0.0,
            tags: [],
            responses: [%{action: "damage", multiplier: 1.0}]
          }

    File.write!(
      catalog,
      Jason.encode!(%{
        schema_version: 1,
        tags: [%{id: "damage"}],
        materials: materials,
        tools: [
          %{
            id: "pickaxe",
            tool_id: 1,
            action: "damage",
            power: 30.0,
            range_macro: 6.0,
            interval_seconds: 0.5
          }
        ],
        definitions: []
      })
    )

    opts = [
      source: Source,
      log: Log,
      root: root,
      observer: self(),
      property_catalog_path: catalog,
      name: nil,
      production_materials: [19]
    ]

    opts = if context[:database], do: Keyword.put(opts, :log, OverlayLog.Db), else: opts

    world = start_supervised!({World, opts})

    actor = %{
      cid: 1001,
      gate: self(),
      identity: make_ref(),
      refresh: &Actor.tool_context/2,
      eye: {1.0625, 1.0625, 0.0625},
      tick_us: 16_667
    }

    actor = Map.put(actor, :player, start_supervised!({Actor, actor}))
    on_exit(fn -> File.rm_rf!(root) end)
    %{world: world, actor: actor, opts: opts, root: root}
  end

  defp build(c, n, cell \\ {1, 1, 2}) do
    World.production_intent(c.world, c.actor, %{
      request_id: n,
      client_intent_seq: n,
      logical_scene_id: 1,
      action: 1,
      coord: cell,
      material: 19,
      tool_id: 1
    })
  end

  defp hit(c, n) do
    query = %{
      request_id: n,
      client_intent_seq: n,
      logical_scene_id: 1,
      action: 0,
      tool_id: 1,
      direction: {0.0, 0.0, 1.0},
      micro: {0, 0, 0},
      granularity: 0,
      incarnation: 0,
      owner: {0, 0},
      material: 0
    }

    {:ok, target} = World.tool_intent(c.world, c.actor, query)
    actor = Map.merge(c.actor, %{received_us: n * 1_000_000, clock_node: node()})

    World.tool_intent(
      c.world,
      actor,
      Map.merge(query, Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
      |> Map.put(:action, 1)
    )
  end

  defp other_actor(c) do
    actor = %{c.actor | cid: 2002, identity: make_ref()}

    Map.put(
      actor,
      :player,
      start_supervised!(Supervisor.child_spec({Actor, actor}, id: :other_actor))
    )
  end

  test "committed build and damage retain previous ownership; failed edits and read retries add nothing",
       c do
    assert {:ok, %{events: [], cursor: 0, world_id: world_id}} =
             World.interactions_since(c.world, nil)

    assert is_binary(world_id)
    assert {:ok, 1} = World.material_supply(c.world, 1001, "finite-author-sample", %{19 => 512})
    assert {:ok, 2} = build(c, 1)
    assert {:error, :insufficient_material} = build(c, 2, {2, 1, 2})
    File.write!(Path.join(c.root, "overlay.log.reject"), "reject")
    assert {:error, :test_disk_failure} = hit(c, 3)
    File.rm!(Path.join(c.root, "overlay.log.reject"))
    assert {:ok, 3} = hit(%{c | actor: other_actor(c)}, 4)
    assert {:ok, result} = World.interactions_since(c.world, 0)
    assert result.cursor == 3

    assert [
             %{seq: 2, actor: 1001, kind: :build, cell: {1, 1, 2}, material: 19, placed_by: nil},
             %{seq: 3, actor: 2002, kind: :damage, cell: {1, 1, 2}, material: 19, placed_by: 1001}
           ] = result.events

    assert Enum.all?(result.events, &is_integer(&1.at_ms))
    assert {:ok, ^result} = World.interactions_since(c.world, 0)
    assert {:ok, %{cursor: 3, events: []}} = World.interactions_since(c.world, nil)
    assert {:ok, %{cursor: 3, events: []}} = World.interactions_since(c.world, 3)
    assert {:error, :invalid_interaction_cursor} = World.interactions_since(c.world, -1)
    assert {:error, :invalid_interaction_cursor} = World.interactions_since(c.world, 4)
  end

  test "compaction and a fresh World replay preserve events and database metadata rows", c do
    assert {:ok, _} = World.material_supply(c.world, 1001, "finite-author-sample", %{19 => 512})
    assert {:ok, _} = build(c, 1)
    assert {:ok, _} = hit(c, 2)
    assert {:ok, expected} = World.interactions_since(c.world, 0)

    for txn <- OverlayLog.File.replay(Path.join(c.root, "overlay.log")) do
      assert [^txn] = txn |> OverlayLog.rows() |> OverlayLog.transactions()
    end

    stop_supervised!(World)
    c = %{c | world: start_supervised!({World, c.opts})}
    assert {:ok, ^expected} = World.interactions_since(c.world, 0)
    assert :ok = World.compact(c.world)
    assert {:ok, ^expected} = World.interactions_since(c.world, 0)
    # 真正新 VM：不沿用本测试进程已经加载过的元数据原子或 World state。
    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])
    expected_path = Path.join(c.root, "expected.etf")
    File.write!(expected_path, :erlang.term_to_binary(expected))
    support = Path.expand("support/world_fixtures.exs", __DIR__)

    code =
      "Logger.configure(level: :warning); Code.require_file(#{inspect(support)}); " <>
        "{:ok,w} = VoxelRegion.World.start_link(source: VoxelRegion.TestSupport.Source, log: VoxelRegion.OverlayLog.File, " <>
        "root: #{inspect(c.root)}, observer: self(), property_catalog_path: #{inspect(Path.join(c.root, "properties.json"))}, name: nil, production_materials: [19]); " <>
        "IO.write(inspect(VoxelRegion.World.interactions_since(w,0) == {:ok,VoxelRegion.OverlayLog.term(File.read!(#{inspect(expected_path)}))}))"

    assert {"true", 0} = System.cmd("elixir", paths ++ ["-e", code], stderr_to_stdout: true)
    stop_supervised!(World)
    world = start_supervised!({World, c.opts})
    assert {:ok, ^expected} = World.interactions_since(world, 0)
    assert {:ok, _} = hit(%{c | world: world}, 3)

    assert {:ok, %{events: [%{placed_by: 1001, kind: :damage}]}} =
             World.interactions_since(world, expected.cursor)
  end

  test "only evicted operations cause a cursor gap; the retained boundary survives restart", c do
    assert {:ok, _} = World.apply_edit(c.world, {1, 1, 2}, 19)
    for n <- 1..513, do: assert({:ok, _} = hit(c, n))
    assert {:error, {:interaction_gap, 3}} = World.interactions_since(c.world, 0)
    assert {:ok, %{events: events, cursor: 514}} = World.interactions_since(c.world, 2)
    assert length(events) == 512
    assert hd(events).seq == 3
    assert List.last(events).seq == 514
    assert :ok = World.compact(c.world)
    stop_supervised!(World)
    world = start_supervised!({World, c.opts})
    assert {:error, {:interaction_gap, 3}} = World.interactions_since(world, 1)
    assert {:ok, %{events: ^events}} = World.interactions_since(world, 2)
  end

  @tag :database
  test "real database append and checkpoint preserve the same committed interaction sequence",
       c do
    assert {:ok, _} = World.material_supply(c.world, 1001, "finite-author-sample", %{19 => 512})
    assert {:ok, 2} = build(c, 1)
    assert {:ok, 3} = hit(c, 2)
    assert {:ok, expected} = World.interactions_since(c.world, 0)
    assert [%{seq: 2, kind: :build}, %{seq: 3, kind: :damage, placed_by: 1001}] = expected.events
    stop_supervised!(World)
    c = %{c | world: start_supervised!({World, c.opts})}
    assert {:ok, ^expected} = World.interactions_since(c.world, 0)
    assert :ok = World.compact(c.world)
    stop_supervised!(World)
    world = start_supervised!({World, c.opts})
    assert {:ok, ^expected} = World.interactions_since(world, 0)
    assert {:ok, 4} = hit(%{c | world: world}, 3)
    assert {:ok, %{events: [%{seq: 4, placed_by: 1001}]}} = World.interactions_since(world, 3)
  end
end
