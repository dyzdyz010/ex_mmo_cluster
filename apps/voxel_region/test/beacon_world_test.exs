defmodule VoxelRegion.BeaconWorldTest do
  @moduledoc """
  只测试：传送信标（Voxim `Docs/Gameplay/Beacon.md`）的 World 侧，经真实 World 入口。

  目录 = 当前世界测试目录 b1aca503（`fixtures/combustion/`）加锚心石材料 88（`beacon_anchor`，三种伤害响应倍率 0）、
  工具 21 `beacon.use`（reach_m 3、读条 3 s + 1 s/km）与同名标签。地形只经作者编辑入口，信标只经维护入口 `beacon_install/3`，
  调谐只经正式工具意图（先 action 0 查询命中，再以同一身份 action 1）。出发两次校验经 Player 发给 World 的同一消息。

  期望的独立依据：核心中心 = (微格 + 0.5) / 8 m 手算；两座信标核心相距 10 m（宏格 x 0 与 10），读条 = 3 + 1 × 10/1000 s。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.World
  alias VoxelRegion.TestSupport.{Actor, Log, Source}

  @current "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  @fixtures Path.expand("fixtures", __DIR__)
  @stone 11
  @anchor 88
  @pick 1
  @beacon 21
  @a 1001

  @qinglan %{id: "qinglan", name: "青岚驿", core: {4, 20, 4}, landing: {0.5, 3.5, 1.5}}
  @ruyuan %{id: "ruyuan", name: "如园", core: {84, 20, 4}, landing: {10.5, 3.5, 1.5}}

  setup do
    root = Path.join(System.tmp_dir!(), "beacon_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    data = Jason.decode!(File.read!(Path.join(@fixtures, "combustion/#{@current}.json")))
    zero = for a <- ~w(damage damage.impact damage.impact.pick), do: %{"action" => a, "multiplier" => 0}
    anchor = %{"material_id" => @anchor, "display_name" => "Anchor", "tags" => ["material.rock"],
      "max_hp_per_macro" => 100, "defense" => 8, "density_kg_m3" => 2700, "beacon_anchor" => true, "responses" => zero}
    tool = %{"tool_id" => @beacon, "id" => "beacon.use", "action" => "beacon.use", "power" => 1, "range_macro" => 8,
      "interval_seconds" => 0.5, "reach_m" => 3, "windup_base_s" => 3, "windup_per_km_s" => 1}
    data = %{data | "materials" => data["materials"] ++ [anchor], "tools" => data["tools"] ++ [tool],
      "tags" => data["tags"] ++ [%{"id" => "beacon.use", "display_name" => "beacon.use"}]}
    catalog = Path.join(root, "properties.json")
    File.write!(catalog, Jason.encode!(data))
    File.cp!(Path.join(@fixtures, "combustion/environment-radiation.json"), Path.join(root, "environment.json"))
    File.mkdir_p!(Path.join(root, "prefabs"))
    %{root: root, catalog: catalog}
  end

  defp start(c) do
    opts = [source: Source, log: Log, root: c.root, observer: self(), name: nil, property_catalog_path: c.catalog,
      thermal_environment_path: Path.join(c.root, "environment.json"), prefab_catalog_path: Path.join(c.root, "prefabs"),
      production_materials: [@stone]]
    start_supervised!({World, opts}, id: :world)
  end

  defp restart(c), do: (:ok = stop_supervised(:world); start(c))

  # 地面 y 0，两座信标核心是宏格 (0,2,0) 与 (10,2,0) 的锚心石。
  defp build(w) do
    {:ok, _} = World.apply_edits(w, [{{0, 2, 0}, @anchor}, {{10, 2, 0}, @anchor} | for(x <- -2..12, z <- -2..2, do: {{x, 0, z}, @stone})])
    w
  end

  defp next, do: System.unique_integer([:positive, :monotonic])

  # 正式工具路径：先查询命中，再以同一身份执行。position 是角色胶囊中心（信标可达距离按它算）。
  defp use_tool(w, eye, position, direction, tool) do
    a = %{cid: @a, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2, eye: eye, position: position, tick_us: 16_667}
    a = Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
    seq = next()
    q = %{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 0, tool_id: tool, direction: direction,
      micro: {0, 0, 0}, granularity: 0, incarnation: 0, owner: {0, 0}, material: 0}

    case World.tool_intent(w, a, q) do
      {:ok, t} ->
        r = Map.merge(q, Map.take(t, [:micro, :granularity, :incarnation, :owner, :material]))
        World.tool_intent(w, Map.merge(a, %{received_us: seq * 1_000_000, clock_node: node()}), %{r | action: 1})

      error ->
        error
    end
  end

  # 站在信标 x+2 处朝 -x 看核心格。
  defp attune(w, x), do: use_tool(w, {x + 2.5, 2.5, 0.5}, {x + 2.5, 1.9, 0.5}, {-1.0, 0.0, 0.0}, @beacon)

  defp travel(w, message, position, request) do
    key = make_ref()
    send(w, {message, key, %{cid: @a, player: self(), position: position}, request})
    reply = if message == :prepare_beacon, do: :beacon_prepared, else: :beacon_committed
    assert_receive {^reply, ^key, result}, 5_000
    result
  end

  test "维护入口只在锚心石上装、同 key 只装一次；目录给出手算的核心中心与调谐", c do
    w = c |> start() |> build()
    assert {:ok, %{beacon: "qinglan"} = receipt} = World.beacon_install(w, "q1", @qinglan)
    seq = World.seq(w)
    assert {:ok, ^receipt} = World.beacon_install(w, "q1", @qinglan)
    assert World.seq(w) == seq
    assert {:error, :not_an_anchor} = World.beacon_install(w, "bad", %{@ruyuan | core: {84, 4, 4}})
    assert {:ok, _} = World.beacon_install(w, "r1", @ruyuan)

    assert World.beacon_directory(w, @a) == [
             %{id: "qinglan", name: "青岚驿", core: {0.5625, 2.5625, 0.5625}, landing: {0.5, 3.5, 1.5}, attuned: false},
             %{id: "ruyuan", name: "如园", core: {10.5625, 2.5625, 0.5625}, landing: {10.5, 3.5, 1.5}, attuned: false}
           ]
  end

  test "G 调谐：可达距离内的最近信标、重复调谐不提交、远了与非锚心拒绝、锚心石挖不动；冷重启后保留", c do
    w = c |> start() |> build()
    {:ok, _} = World.beacon_install(w, "q1", @qinglan)
    {:ok, _} = World.beacon_install(w, "r1", @ruyuan)

    assert {:error, :not_an_anchor} = use_tool(w, {2.5, 1.5, 0.5}, {2.5, 1.0, 0.5}, {0.0, -1.0, 0.0}, @beacon)
    assert {:error, :too_far} = use_tool(w, {6.5, 2.5, 0.5}, {6.5, 1.9, 0.5}, {-1.0, 0.0, 0.0}, @beacon)
    assert {:ok, seq} = attune(w, 0)
    assert seq == World.seq(w)
    assert {:ok, ^seq} = attune(w, 0)
    assert World.seq(w) == seq
    assert {:error, :ineffective_tool} = use_tool(w, {2.5, 2.5, 0.5}, {2.5, 1.9, 0.5}, {-1.0, 0.0, 0.0}, @pick)

    attuned = fn w -> for e <- World.beacon_directory(w, @a), do: {e.id, e.attuned} end
    assert attuned.(w) == [{"qinglan", true}, {"ruyuan", false}]
    assert World.beacon_directory(w, 2002) |> Enum.map(& &1.attuned) == [false, false]

    w = restart(c)
    assert attuned.(w) == [{"qinglan", true}, {"ruyuan", false}]
  end

  test "出发：开始校验可达、调谐与完好，读条按距离；结束只认目的完好；核心挖掉即失效", c do
    w = c |> start() |> build()
    {:ok, _} = World.beacon_install(w, "q1", @qinglan)
    {:ok, _} = World.beacon_install(w, "r1", @ruyuan)
    {:ok, _} = attune(w, 0)
    near_q = {2.5, 1.9, 0.5}
    go = %{from: "qinglan", to: "ruyuan"}

    assert {:error, :not_attuned} = travel(w, :prepare_beacon, near_q, go)
    {:ok, _} = attune(w, 10)
    assert {:ok, windup} = travel(w, :prepare_beacon, near_q, go)
    assert_in_delta windup, 3.01, 1.0e-9
    assert {:error, :too_far} = travel(w, :prepare_beacon, {5.5, 1.9, 0.5}, go)
    assert {:error, :same_beacon} = travel(w, :prepare_beacon, near_q, %{go | to: "qinglan"})
    assert {:error, :unknown_beacon} = travel(w, :prepare_beacon, near_q, %{go | to: "nowhere"})
    assert {:ok, {10.5, 3.5, 1.5}} = travel(w, :commit_beacon, near_q, go)

    {:ok, _} = World.apply_edits(w, [{{10, 2, 0}, 0}])
    assert {:error, :beacon_lost} = travel(w, :commit_beacon, near_q, go)
    assert {:error, :beacon_lost} = travel(w, :prepare_beacon, near_q, go)
    assert {:error, :beacon_lost} = travel(w, :prepare_beacon, {12.5, 1.9, 0.5}, %{from: "ruyuan", to: "qinglan"})
  end
end
