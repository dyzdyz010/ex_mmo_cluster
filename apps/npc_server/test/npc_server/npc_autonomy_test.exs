Code.require_file("../support/npc_world.exs", __DIR__)

defmodule NpcServer.NpcAutonomyTest do
  @moduledoc """
  只测试：真实 World/Scene/Body 的有限材料循环；测试进程安排动作，不证明模型自主选择。
  作者一次安装两格采料样本；NPC 零余额，经正式 gather/place 消费，再受另一角色破坏后重新采集恢复。
  攻击者采用既有 Actor 边界替身，只有其工具入口时钟受控；NPC 自身全部经过正式 Session/Body。
  """
  use ExUnit.Case, async: false
  alias NpcServer.Body
  alias NpcServer.NpcWorld
  alias VoxelRegion.World

  defp command(body, id, command) do
    Body.command(body, Map.put(command, :id, id))
    NpcWorld.await(fn -> Enum.find(Body.observe(body).outcomes, &(&1.id == id)) end, 30_000)
  end

  @tag timeout: 90_000
  test "两份有限材料分别采得、消耗并在破坏后由同NPC恢复，耗尽不冒充成功" do
    fixture = NpcWorld.start()
    cid = 9101
    samples = [{7, 64, 12}, {8, 64, 12}]
    target = {6, 64, 8}
    {:ok, _} = World.apply_edits(fixture.world, Enum.map(samples, &{&1, 11}))
    profile = %{steps: [], tools: %{1 => "镐"}, skills: %{gather: %{}}, memory: NpcWorld.Memory}
    %{body: body} = NpcWorld.body(fixture, {NpcServer.Brain.Routine, profile}, cid: cid)
    NpcWorld.await(fn -> Body.observe(body).position end)
    assert NpcWorld.balance(fixture.world, cid) == 0

    for {cell, round} <- Enum.with_index(samples, 1) do
      {:ok, %{cursor: before_gather}} = World.interactions_since(fixture.world, 0)

      assert %{status: :done, data: %{mined: 1, gained: 512}} =
               command(body, round * 10, %{
                 verb: :skill,
                 skill: :gather,
                 args: %{
                   "box" => [Tuple.to_list(cell), Tuple.to_list(cell)],
                   "material" => 11,
                   "units" => 512,
                   "tool_id" => 1
                 }
               })

      assert NpcWorld.balance(fixture.world, cid) == 512
      {:ok, gathered} = World.interactions_since(fixture.world, before_gather)
      assert gathered.events != []
      assert Enum.all?(gathered.events, &(&1.actor == cid and &1.cell == cell))

      assert [%{kind: :destroy, seq: gather_seq}] =
               Enum.filter(gathered.events, &(&1.kind == :destroy))

      assert gather_seq > before_gather
      assert length(Enum.uniq_by(gathered.events, & &1.seq)) == length(gathered.events)

      assert %{status: :done, data: %{seq: seq}} =
               command(body, round * 10 + 1, %{
                 verb: :place,
                 coord: target,
                 material: 11,
                 tool_id: 1
               })

      assert NpcWorld.balance(fixture.world, cid) == 0

      assert %{^target => %{material: 11, placed_by: ^cid}} =
               NpcWorld.cells(fixture.world, [target])

      {:ok, events} = World.interactions_since(fixture.world, seq - 1)
      assert [%{seq: ^seq, actor: ^cid, cell: ^target, kind: :build}] = events.events
      if round == 1, do: destroy(fixture.world, target)
    end

    assert Enum.all?(Map.values(NpcWorld.cells(fixture.world, samples)), &(&1.material == 0))

    assert %{status: :rejected, reason: :exhausted} =
             command(body, 30, %{
               verb: :skill,
               skill: :gather,
               args: %{
                 "box" => [[7, 64, 12], [8, 64, 12]],
                 "material" => 11,
                 "units" => 512,
                 "tool_id" => 1
               }
             })

    assert NpcWorld.balance(fixture.world, cid) == 0

    assert %{^target => %{material: 11, placed_by: ^cid}} =
             NpcWorld.cells(fixture.world, [target])
  end

  defp destroy(world, cell) do
    actor = NpcWorld.actor(4242, {6.5, 65.5, 6.5})

    query = %{
      request_id: 1,
      client_intent_seq: 1,
      logical_scene_id: 1,
      action: 0,
      tool_id: 1,
      direction: {0.0, -1.0, 2.0},
      micro: {0, 0, 0},
      granularity: 0,
      incarnation: 0,
      owner: {0, 0},
      material: 0
    }

    {:ok, hit} = World.tool_intent(world, actor, query)
    assert hit.material == 11

    for seq <- 1..4 do
      {:ok, _} =
        World.tool_intent(
          world,
          Map.merge(actor, %{received_us: seq * 1_000_000, clock_node: node()}),
          query
          |> Map.merge(Map.take(hit, [:micro, :granularity, :incarnation, :owner, :material]))
          |> Map.merge(%{action: 1, request_id: seq + 1, client_intent_seq: seq + 1})
        )
    end

    assert %{^cell => %{material: 0}} = NpcWorld.cells(world, [cell])
  end
end
