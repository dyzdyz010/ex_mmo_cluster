Code.require_file("../support/life_fixtures.exs", __DIR__)

defmodule NpcServer.NpcLifeInteractionGapTest do
  @moduledoc """
  只测试：真实 World、Life 与 VM 独占 PostgreSQL。经公开角色意图制造一次刚超过保留上限的断层，
  同时验证在运行的 Life 和重启后读持久行的 Life。真实数据库触发器拒绝这两个角色的记忆写入，
  不替换存储适配器；角色授权、路由、观察和 Hindsight 使用测试夹具。场景不经客户端或付费模型。

  在 apps/npc_server 运行 mix test --no-start test/npc_server/npc_life_interaction_gap_test.exs。
  """
  use ExUnit.Case, async: false
  import NpcServer.LifeFixtures, only: [actor: 1, damage: 4]
  alias DataService.{NpcMemory, Repo}
  alias NpcServer.{Life, NpcWorld}
  alias VoxelRegion.World

  defmodule Hindsight do
    def ensure(_, _), do: {:ok, %{}}
    def models(_), do: {:ok, %{models: %{"self" => "builder"}, metadata: %{}}}
    def status(_), do: {:ok, %{stats: %{"memory_unit_count" => 0}, usage: %{}}}
  end

  setup_all do
    MmoTest.Database.start!()
    :ok
  end

  test "同一个世界断层后，冷热 Life 只原子恢复仍可用的经历" do
    %{world: world} = NpcWorld.start()
    warm = 100_000 + System.unique_integer([:positive])
    cold = warm + 100
    bystander = cold + 20
    old_cell = {4, 64, 8}
    clock = start_supervised!({Agent, fn -> System.system_time(:millisecond) end})

    for cid <- [warm, cold] do
      start_life(cid, clock)
      await_life(cid, &(&1.cache != nil and &1.job == nil))
    end

    damage(world, warm, 1, {6, 65, 8})
    damage(world, cold, 2, old_cell)
    {:ok, %{world_id: world_id, cursor: before}} = World.interactions_since(world, nil)

    for cid <- [warm, cold] do
      await_life(cid, &(&1.state["cursor"] == before and &1.pending_episodes == 1))
    end

    warm_row = stored(warm)
    cold_row = stored(cold)
    assert :ok = stop_supervised({Life, cold})
    trigger = block_writes(warm, cold)

    # 损坏过程在缺口里结束，其他人在同一格放同样的材料也不能认作修复了旧建筑。
    destroy(world, cold, old_cell)
    overflow_history(world, bystander + 1)

    assert {:ok, _} = World.material_supply(world, bystander, "rebuild", %{11 => 512})
    assert {:ok, rebuild_seq} = build(world, actor(bystander), 523, old_cell)
    damage(world, cold, 524, {4, 65, 10})

    assert {:ok, %{cursor: cursor, events: [rebuild, _placed, damaged]}} =
             World.interactions_since(world, rebuild_seq - 1)

    assert rebuild.actor == bystander
    assert damaged.placed_by == cold
    assert {:error, {:interaction_gap, oldest}} = World.interactions_since(world, before)

    # 故意让回放时的当前位置和事件的新鲜度都满足所见条件，反例才能抓住补写旧观察的错误。
    Agent.update(clock, fn _ -> rebuild.at_ms end)
    observation = %{self: %{entity_id: cold, position: {4.5, 65.5, 8.5}}, entities: []}
    cold_life = start_life(cold, clock)
    Life.observation(cold_life, observation)

    cold_failed = await_life(cold, &(&1.error != nil))
    assert cold_failed.error == {:memory_unavailable, Postgrex.Error}
    assert cold_failed.state == nil
    assert cold_failed.last_interaction_gap == nil
    assert stored(cold) == cold_row
    refute_received {:life_state, %{"cid" => ^cold, "cursor" => ^cursor}, _}

    warm_failed = await_life(warm, &(&1.error != nil))
    assert warm_failed.error == {:memory_unavailable, Postgrex.Error}
    assert warm_failed.state == warm_row["state"]
    assert warm_failed.last_interaction_gap == nil
    assert stored(warm) == warm_row

    allow_writes(trigger)
    expected_gap = %{"from_cursor" => before, "oldest_seq" => oldest, "resumed_cursor" => cursor}

    for cid <- [warm, cold] do
      resumed = await_life(cid, &(&1.state != nil and &1.state["cursor"] == cursor))
      assert resumed.state["world_id"] == world_id
      assert resumed.error == nil
      assert resumed.last_interaction_gap == expected_gap
    end

    assert stored(warm)["pending"] == warm_row["pending"]
    assert stored(warm)["state"]["relationships"] == warm_row["state"]["relationships"]

    resumed_row = stored(cold)
    assert [prior, recovered] = resumed_row["pending"]
    assert [prior] == cold_row["pending"]
    assert recovered["seq"] == damaged.seq
    assert recovered["tags"] == ["kind:event", "actor:#{cold + 10}"]
    assert resumed_row["state"]["evidence"]["help_count"] == 0
    assert resumed_row["state"]["relationships"][to_string(cold + 10)]["trust"] == -0.70

    Agent.update(clock, &(&1 + 31_000))
    Life.observation(cold_life, observation)
    assert {:ok, %{pending_episodes: 2}} = Life.observe(cold)
    assert stored(cold) == resumed_row

    assert :ok = stop_supervised({Life, cold})
    start_life(cold, clock)
    restored = await_life(cold, &(&1.state != nil))
    assert restored.last_interaction_gap == expected_gap
    assert restored.state == resumed_row["state"]
    assert stored(cold) == resumed_row

    damage(world, cold, 525, {4, 65, 6})
    {:ok, %{cursor: next}} = World.interactions_since(world, nil)
    continued = await_life(cold, &(&1.state["cursor"] == next))
    assert continued.pending_episodes == 3
    assert continued.last_interaction_gap == expected_gap
  end

  defp start_life(cid, clock) do
    context = %{cid: cid, scene_id: 1, router: NpcWorld.Route}

    profile = %{
      life: %{
        hindsight: Hindsight,
        url: "http://life.test.invalid",
        clock: fn -> Agent.get(clock, & &1) end,
        poll_ms: 30
      }
    }

    start_supervised!(%{id: {Life, cid}, start: {Life, :start_link, [self(), context, profile]}})
  end

  defp await_life(cid, predicate) do
    NpcWorld.await(fn ->
      {:ok, observation} = Life.observe(cid)
      if predicate.(observation), do: observation
    end)
  end

  defp stored(cid), do: NpcMemory.get(cid, "life", "state")

  # 首击已提交；继续正常击打同一格三次，最后一次将其破坏。
  defp destroy(world, cid, cell) do
    attacker = actor(cid + 10)

    for n <- 3..5 do
      query = %{
        request_id: n,
        client_intent_seq: n,
        logical_scene_id: 1,
        action: 0,
        tool_id: 1,
        direction: {0.0, -1.0, 0.0},
        micro: {0, 0, 0},
        granularity: 0,
        incarnation: 0,
        owner: {0, 0},
        material: 0
      }

      assert {:ok, target} = World.tool_intent(world, attacker, query)

      commit =
        query
        |> Map.merge(Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))
        |> Map.put(:action, 1)

      attacker = Map.merge(attacker, %{received_us: n * 1_000_000, clock_node: node()})
      assert {:ok, _} = World.tool_intent(world, attacker, commit)
    end

    assert %{^cell => %{material: 0}} = NpcWorld.cells(world, [cell])
  end

  # 远处 513 次普通放置填满保留窗；只给这批放置发一次有限作者样本。
  defp overflow_history(world, cid) do
    builder = NpcWorld.actor(cid, {35.5, 65.5, 35.5})

    cells =
      for x <- -5..5,
          y <- -1..5,
          z <- -5..5,
          x * x + y * y + z * z <= 30 do
        {35 + x, 65 + y, 35 + z}
      end

    assert {:ok, _} = World.material_supply(world, cid, "fill-retention", %{11 => 513 * 512})

    for {cell, n} <- cells |> Enum.take(513) |> Enum.with_index(10) do
      assert {:ok, _} = build(world, builder, n, cell)
    end
  end

  defp build(world, actor, n, cell) do
    World.production_intent(world, actor, %{
      request_id: n,
      client_intent_seq: n,
      logical_scene_id: 1,
      action: 1,
      tool_id: 1,
      coord: cell,
      material: 11
    })
  end

  defp block_writes(warm, cold) do
    name = "test_interaction_gap_#{warm}"

    sql!("""
    CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.cid IN (#{warm}, #{cold}) AND NEW.kind = 'life' AND NEW.key = 'state'
        THEN RAISE EXCEPTION 'test interaction gap write refused';
      END IF;
      RETURN NEW;
    END $$
    """)

    sql!(
      "CREATE TRIGGER #{name} BEFORE INSERT ON npc_memories FOR EACH ROW EXECUTE FUNCTION #{name}()"
    )

    on_exit(fn ->
      allow_writes(name)
      sql!("DROP FUNCTION IF EXISTS #{name}()")
    end)

    name
  end

  defp allow_writes(name), do: sql!("DROP TRIGGER IF EXISTS #{name} ON npc_memories")
  defp sql!(statement), do: Ecto.Adapters.SQL.query!(Repo, statement, [])
end
