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

  # action：1 = 用镐打一下，2 = 拆卸（拆下命中的构件）。
  defp hit(c, n, action \\ 1) do
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
      |> Map.put(:action, action)
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

    # 散格：没有所属实例（instance / anchor 为 nil，也就谈不上“整座被移除”）。
    assert [
             %{seq: 2, actor: 1001, kind: :build, cell: {1, 1, 2}, material: 19, placed_by: nil, prefab: nil,
               instance: nil, anchor: nil, instance_removed: false},
             %{seq: 3, actor: 2002, kind: :damage, cell: {1, 1, 2}, material: 19, placed_by: 1001, prefab: nil,
               instance: nil, anchor: nil, instance_removed: false}
           ] = result.events

    assert Enum.all?(result.events, &is_integer(&1.at_ms))
    assert {:ok, ^result} = World.interactions_since(c.world, 0)
    assert {:ok, %{cursor: 3, events: []}} = World.interactions_since(c.world, nil)
    assert {:ok, %{cursor: 3, events: []}} = World.interactions_since(c.world, 3)
    assert {:error, :invalid_interaction_cursor} = World.interactions_since(c.world, -1)
    assert {:error, :invalid_interaction_cursor} = World.interactions_since(c.world, 4)
  end

  # 小屋 = 自己的一格（上）+ 一个子定义“门”的一格（下，锚点格）。视线沿 +Z 先打到锚点格 {1, 1, 2}，即子实例的那一格：
  # 事件记的是整体放下的根实例（小屋）的定义与身份，不是子实例（门）的。实例身份 = {放下它的事务序号, 节点序}，根是 0
  # （同 prefab_macro_world_test）。锚点微格 (8, 8, 16) / 8 = 宏格 (1, 1, 2)。
  # 打一下没毁 → :damage，小屋还在；再拆掉门这个叶子构件 → :destroy，门没了但根（小屋）还有自己那一格，仍在。
  test "damage and dismantling a leaf of a placed prefab record the root instance, which remains", c do
    door = VoxelRegion.Prefab.encode(%{cells: [], macro_cells: [{{0, 0, 0}, 19}], children: [], attachments: []})
    assert {:ok, door_id} = World.publish_prefab(c.world, c.actor, door, "door")

    hut =
      VoxelRegion.Prefab.encode(%{
        cells: [],
        macro_cells: [{{0, 1, 0}, 19}],
        children: [%{slot: 0, definition_id: door_id, anchor: {0, 0, 0}, orientation: 0}],
        attachments: []
      })

    assert {:ok, hut_id} = World.publish_prefab(c.world, c.actor, hut, "small hut")
    assert hut_id != door_id
    assert {:ok, _} = World.material_supply(c.world, 1001, "finite-author-sample", %{19 => 1024})

    assert {:ok, _} =
             World.prefab_intent(c.world, c.actor, :voxel_prefab_place_v1, %{
               definition_id: hut_id,
               anchor: {8, 8, 16},
               orientation: 0,
               client_intent_seq: 1
             })

    assert {:ok, %{cursor: placed}} = World.interactions_since(c.world, nil)
    other = %{c | actor: other_actor(c)}
    assert {:ok, _} = hit(other, 2)
    assert {:ok, _} = hit(other, 3, 2)

    assert {:ok, %{events: [damage, destroy]}} = World.interactions_since(c.world, placed)

    assert %{actor: 2002, kind: :damage, cell: {1, 1, 2}, material: 19, placed_by: 1001, prefab: ^hut_id,
             instance: {^placed, 0}, anchor: {1, 1, 2}, instance_removed: false} = damage

    assert %{actor: 2002, kind: :destroy, cell: {1, 1, 2}, material: 19, placed_by: 1001, prefab: ^hut_id,
             instance: {^placed, 0}, anchor: {1, 1, 2}, instance_removed: false} = destroy

    # 与事件同一判据的现查：小屋只剩自己那一格。
    assert {:ok, [{1, 2, 2}]} = World.instance_cells(c.world, {placed, 0})

    # 名字不在事件里：按定义 id 查发布元信息。
    assert [%{id: ^door_id, name: "door"}, %{id: ^hut_id, name: "small hut", publisher: 1001}] =
             World.published_prefab_metadata(c.world)
  end

  # 只有一个构件（一格细化石料，锚点微格 (8, 8, 16) = 宏格 (1, 1, 2) 的 0 号槽）的小屋：放下的 build 事件带刚放下的这座
  # （所属建筑按提交后取；placed_by 仍是提交前的空槽 nil）；另一角色对它拆卸（action 2，拆下整个叶子构件，
  # S1-C 实跑走的就是这条）→ 根实例没了。
  test "dismantling the only component of a placed prefab removes the whole building", c do
    hut = VoxelRegion.Prefab.encode(%{cells: [{{0, 0, 0}, 19}], macro_cells: [], children: [], attachments: []})
    assert {:ok, hut_id} = World.publish_prefab(c.world, c.actor, hut, "small hut")
    assert {:ok, _} = World.material_supply(c.world, 1001, "finite-author-sample", %{19 => 1024})
    assert {:ok, %{cursor: before}} = World.interactions_since(c.world, nil)

    assert {:ok, placed} =
             World.prefab_intent(c.world, c.actor, :voxel_prefab_place_v1, %{
               definition_id: hut_id,
               anchor: {8, 8, 16},
               orientation: 0,
               client_intent_seq: 1
             })

    assert {:ok, _} = hit(%{c | actor: other_actor(c)}, 2, 2)
    assert {:ok, %{events: [build, destroy]}} = World.interactions_since(c.world, before)

    assert %{seq: ^placed, actor: 1001, kind: :build, cell: {1, 1, 2}, material: 19, placed_by: nil, prefab: ^hut_id,
             instance: {^placed, 0}, anchor: {1, 1, 2}, instance_removed: false} = build

    assert %{actor: 2002, kind: :destroy, cell: {1, 1, 2}, material: 19, placed_by: 1001, prefab: ^hut_id,
             instance: {^placed, 0}, anchor: {1, 1, 2}, instance_removed: true} = destroy

    assert {:error, :instance_not_found} = World.instance_cells(c.world, {placed, 0})
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
