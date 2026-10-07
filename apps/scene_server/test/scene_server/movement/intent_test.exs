Code.require_file("../../../../voxel_region/test/support/world_fixtures.exs", __DIR__)

defmodule SceneServer.Movement.IntentTest do
  @moduledoc """
  只测试：`SceneServer.Movement.Intent.run/3` 的接缝——角色 owner 接纳 → 真实 `VoxelRegion.World` → 原样结果与补余额标志。

  替身范围：角色 owner 是本文件的 `Owner`（只回预设的接纳结果与 actor，不冒充 Player 的授权规则；死亡 / 施法 / 重放门
  由 cast_action_test、tool_action_test 覆盖）。World 是真实进程（`VoxelRegion.TestSupport.Source` 空白地形 + 本测试写的
  属性目录），余额只经 `material_supply` 一次记账、经正式放置消费。补余额期望取自 Dispatch 改前的现行规则：
  工具 action ∈ [1, 2] 且 granularity ≠ 5（与结果无关）；生产 / prefab 仅 owner 接纳通过；发布不补。
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias SceneServer.Movement.Intent
  alias VoxelRegion.World

  @cid 1001

  defmodule Owner do
    @moduledoc "只测试：角色 owner 替身。tool_context / authorize_tool 回预设结果；通过时给出带本进程 pid 的 actor。"
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}

    def handle_call({:tool_context, id}, _, %{identity: id, tool_context: :ok} = s),
      do: {:reply, {:ok, Map.put(s.actor, :player, self())}, s}

    def handle_call({:tool_context, _}, _, s), do: {:reply, s.tool_context, s}

    def handle_call({:authorize_tool, _, %{action: 0}, ingress}, _, s),
      do: {:reply, {:ok, s.actor |> Map.put(:player, self()) |> Map.merge(ingress)}, s}

    def handle_call({:authorize_tool, _, _, _}, _, s), do: {:reply, s.authorize, s}
  end

  # 与 Prefab 发布派发测试同一份最小 VXPD v3 定义（一个材料 11 的节点）。
  @vxpd "VXPD" <> <<3::32-little, 0::32, 0::32, 0::32, 1::32-little, 0::96, 11::16-little>>

  setup do
    root = Path.join(System.tmp_dir!(), "intent_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    catalog = Path.join(root, "properties.json")

    materials =
      for id <- 0..23,
          do: %{
            material_id: id,
            max_hp_per_macro: if(id == 0, do: 0.0, else: 100.0),
            defense: 2.0,
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

    world =
      start_supervised!(
        {World,
         source: VoxelRegion.TestSupport.Source,
         root: root,
         observer: self(),
         name: nil,
         property_catalog_path: catalog,
         prefab_catalog_path: nil,
         production_materials: [19, 11]}
      )

    identity = make_ref()

    actor = %{
      cid: @cid,
      gate: self(),
      identity: identity,
      refresh: &SceneServer.Movement.Player.tool_context/2,
      eye: {1.0625, 1.0625, 0.0625},
      tick_us: 16_667,
      action_key: {identity, 1}
    }

    owner = fn replies ->
      start_supervised!(
        {Owner, Map.merge(%{identity: identity, actor: actor, tool_context: :ok}, replies)},
        id: make_ref()
      )
    end

    %{world: world, identity: identity, owner: owner}
  end

  defp session(c, owner), do: %{player: owner, identity: c.identity, world_ref: c.world, cid: @cid}
  defp ingress, do: %{received_us: System.monotonic_time(:microsecond), clock_node: node()}

  defp balance(world, material),
    do: Enum.find(World.material_balances(world, @cid), &(&1.material == material)).balance

  defp tool(action, granularity),
    do: %{
      request_id: 7,
      client_intent_seq: 7,
      logical_scene_id: 1,
      action: action,
      direction: {0.0, 0.0, 1.0},
      micro: {0, 0, 0},
      incarnation: if(granularity == 5, do: 3, else: 0),
      owner: if(granularity == 5, do: {2002, 0}, else: {0, 0}),
      material: 0,
      tool_id: 1,
      granularity: granularity
    }

  test "放置经 owner 接纳进真实 World：提交并补余额，余额按目录手算少一格", c do
    {:ok, _} = World.material_supply(c.world, @cid, "intent-test", %{19 => 4096})
    place = %{
      request_id: 10,
      client_intent_seq: 10,
      logical_scene_id: 1,
      action: 1,
      coord: {1, 1, 2},
      tool_id: 1,
      material: 19
    }

    assert {{:ok, seq}, true} =
             Intent.run(session(c, c.owner.(%{})), {:voxel_production_intent, place}, ingress())

    assert is_integer(seq) and seq > 0
    # 目录 schema 1、材料 19 无 place_units：一格 = 8³ micro × 每 micro 1 单位 = 512。
    assert balance(c.world, 19) == 4096 - 512

    assert [%{material: 19, refined: false}] =
             World.material_snapshot(c.world, [], [{1, 1, 2}]).probe_occupancy

    # prefab 同样只看 owner 接纳：World 拒绝（未发布的定义）也补余额。
    prefab = %{
      request_id: 11,
      client_intent_seq: 11,
      logical_scene_id: 1,
      definition_id: :binary.copy(<<42>>, 32),
      anchor: {8, 8, 16},
      orientation: 0
    }

    assert {{:error, :definition_not_found}, true} =
             Intent.run(session(c, c.owner.(%{})), {:voxel_prefab_place_v1, prefab}, ingress())
  end

  test "owner 拒绝（施法中）时不进 World、不补余额；缺 cid / client_intent_seq 的日志行照常", c do
    place = %{request_id: 3, logical_scene_id: 1, action: 1, coord: {1, 1, 2}, tool_id: 1, material: 19}
    owner = c.owner.(%{tool_context: {:error, :casting}})
    session = Map.delete(session(c, owner), :cid)

    log =
      capture_log(fn ->
        assert {{:error, :casting}, false} =
                 Intent.run(session, {:voxel_production_intent, place}, ingress())
      end)

    assert log =~
             "character_intent kind=voxel_production_intent cid= client_seq=0 request_id=3 elapsed_us="

    # action / tool / g 区分同一 kind 下的动作；生产没有 granularity，留空。
    assert log =~ "action=1 tool=1 g= result=error reason=:casting"
    assert World.seq(c.world) == 0
  end

  test "工具补余额只看 action 与 granularity：a0 不补，a1 被 owner 拒绝仍补，g5 不补", c do
    owner = c.owner.(%{authorize: {:error, :dead}})
    s = session(c, owner)

    # 空白世界沿 +Z 无命中：探测不进事务。
    assert {{:error, :no_target}, false} = Intent.run(s, {:voxel_tool_intent, tool(0, 0)}, ingress())
    assert {{:error, :dead}, true} = Intent.run(s, {:voxel_tool_intent, tool(1, 0)}, ingress())
    assert {{:error, :dead}, true} = Intent.run(s, {:voxel_tool_intent, tool(2, 0)}, ingress())
    log =
      capture_log(fn ->
        assert {{:error, :dead}, false} =
                 Intent.run(s, {:voxel_tool_intent, tool(1, 5)}, ingress())
      end)

    # 人物命中与地形挖掘同为 voxel_tool_intent，靠 action / g 区分。
    assert log =~ "kind=voxel_tool_intent cid=#{@cid} client_seq=7 request_id=7 elapsed_us="
    assert log =~ "action=1 tool=1 g=5 result=error reason=:dead"
  end

  test "发布经 owner 接纳进 World，返回定义 id，不补余额", c do
    publish = %{
      request_id: 4,
      client_intent_seq: 4,
      logical_scene_id: 1,
      definition: @vxpd,
      name: "intent"
    }

    assert {{:ok, id}, false} =
             Intent.run(session(c, c.owner.(%{})), {:voxel_prefab_publish_v1, publish}, ingress())

    assert id == :crypto.hash(:sha256, @vxpd)
    assert World.published_prefabs(c.world) == [{@cid, "intent", @vxpd}]
  end
end
