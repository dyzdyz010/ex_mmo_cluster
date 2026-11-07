Code.require_file("../../../../voxel_region/test/support/world_fixtures.exs", __DIR__)

defmodule SceneServer.Movement.ToolActionTest do
  use ExUnit.Case, async: true
  @moduletag :t0
  alias SceneServer.{Body, Movement.Player}
  alias MmoContracts.Session

  defmodule Sink do
    def reliable(pid, _, _, message), do: send(pid, {:wire, message})
  end

  defmodule Owner do
    # 只测试：进程外壳委托真实Player回调；不启动移动/时钟，不冒充完整Scene登录。
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}
    def handle_call(message, from, state), do: Player.handle_call(message, from, state)
    def handle_info(_, state), do: {:noreply, state}
  end

  defmodule Members do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, [])
    def init(players), do: {:ok, players}
    def handle_call({:players, players}, _, _), do: {:reply, :ok, players}
    def handle_call(:tool_candidates, _, :closed), do: {:reply, {:error, :combat_not_permitted}, :closed}
    def handle_call(:tool_candidates, _, players), do: {:reply, {:ok, players}, players}
  end

  # Test-only：受控 owner 回调，不冒充真实网络／World 集成。
  setup do
    identity = %Session.Identity{session_epoch: 7, scene_id: 1, scene_epoch: 2}
    body_store = start_supervised!({MmoTest.BodyStore, []})
    {:ok, nil} = MmoTest.BodyStore.claim(20, identity.session_epoch, store: body_store)

    state = %{
      identity: identity,
      id: 20,
      epoch: 1,
      ready: true,
      transfer: nil,
      failure: nil,
      state: %{position: {2.0, 0.0, 0.0}, velocity: {0.0, 0.0, 0.0}, yaw: 0},
      # 真实 Player 状态恒有该字段；工具上下文把它作为确认位置的 tick 交给观察日志。
      simulation_tick: 0,
      scene: self(),
      gate: self(),
      sink: Sink,
      config: %{
        profile: %{half_height: 0.9, radius: 0.3},
        combat_scope: {{-5.0, -5.0, -5.0}, {5.0, 5.0, 5.0}}
      },
      body: Body.new(),
      body_store: {MmoTest.BodyStore, store: body_store},
      body_owned: true,
      body_fence: nil,
      body_heat: %{q_j: 0.0, tissue_j: 0.0, max_contact_k: nil, sole_k: nil, immersed: 0.0},
      body_exchange_j: 0.0,
      food_cursors: %{},
      body_sent: nil,
      life_generation: 99,
      effect_receipts: %{},
      tool_action: nil,
      action: nil,
      tick: 40,
      scene_id: 1,
      scene_epoch: 2,
      updates: %{transaction_seq: 0, revision: 1},
      clock: {SceneServer.Movement.Clock, nil},
      time_origin: 0,
      time_mono_origin: 0,
      mono_origin: 0
    }

    actor = %{identity: identity, position: {0.0, 0.0, 0.0}, cid: 10, life_generation: 98}

    hit = %{
      key: MmoContracts.Action.key(identity, 11),
      actor: actor,
      target: %{id: 20, identity: identity, life_generation: 99, position: state.state.position},
      part: :torso,
      impact: %{depth: 0.2, protein_g: 2.0, heal_s: 100.0},
      request_id: 42
    }

    %{state: state, hit: hit, identity: identity, from: {self(), make_ref()}}
  end

  test "同一作用重投只返回原回执，新生命拒绝旧作用", c do
    {:reply, {:ok, receipt}, after_hit} =
      Player.handle_call({:receive_effect, c.hit}, c.from, c.state)

    assert receipt.body.life == 80
    assert receipt.action_seq == 11 and receipt.target_id == 20 and receipt.source_id == 10
    assert_receive {:wire, %Session.ToolState{request_id: 42, target_life: 99, life: 80}}
    assert_receive {:wire, %Session.BodyState{life: 80, recoverable: 20}}

    assert {:reply, {:ok, ^receipt}, ^after_hit} =
             Player.handle_call({:receive_effect, c.hit}, c.from, after_hit)

    refute_receive {:wire, _}, 0
    # 复活不清空回执：旧作用重投仍只返回原回执、不再结算；旧生命的新作用拒绝。
    revived = %{after_hit | life_generation: 100, body: Body.revive()}

    assert {:reply, {:ok, ^receipt}, ^revived} =
             Player.handle_call({:receive_effect, c.hit}, c.from, revived)

    fresh = %{c.hit | key: MmoContracts.Action.key(c.identity, 12)}

    assert {:reply, {:error, :stale_life}, ^revived} =
             Player.handle_call({:receive_effect, fresh}, c.from, revived)
  end

  test "工具作用复核目标身份；回执随存档恢复后重投不再结算", c do
    stale = put_in(c.hit, [:target, :identity], %{c.identity | session_epoch: 6})

    state = c.state

    assert {:reply, {:error, :stale_owner}, ^state} =
             Player.handle_call({:receive_effect, stale}, c.from, state)

    {:reply, {:ok, receipt}, next} = Player.handle_call({:receive_effect, c.hit}, c.from, c.state)
    recovered = Map.merge(c.state, SceneServer.Body.Snapshot.decode!(SceneServer.Body.Snapshot.encode(next)))
    assert {:reply, {:ok, ^receipt}, ^recovered} = Player.handle_call({:receive_effect, c.hit}, c.from, recovered)
  end

  test "投射物焦耳只入局部热一次；存档恢复仍去重，旧生命与 owner 拒绝", c do
    hit = %{key: {77, 15, 0}, actor: c.hit.actor,
      target: %{id: 20, identity: c.identity, life_generation: 99}, q_j: 2094.0,
      position: {1.5, 0.0, 0.0}}
    assert {:reply, {:ok, receipt}, next} = Player.handle_call({:receive_effect, hit}, c.from, c.state)
    assert receipt.q_j == 2094.0
    assert next.body_heat.q_j == 2094.0
    assert next.body_heat.tissue_j == 2094.0
    assert next.body_exchange_j == 2094.0
    assert next.body == c.state.body
    saved = SceneServer.Body.Snapshot.decode!(SceneServer.Body.Snapshot.encode(next))
    recovered = Map.merge(c.state, saved)
    assert {:reply, {:ok, ^receipt}, ^recovered} = Player.handle_call({:receive_effect, hit}, c.from, recovered)
    stale = put_in(hit.target.life_generation, 98)
    assert {:reply, {:error, :stale_life}, _} = Player.handle_call({:receive_effect, stale}, c.from, c.state)
    old = put_in(hit.target.identity.session_epoch, 6)
    assert {:reply, {:error, :stale_owner}, _} = Player.handle_call({:receive_effect, old}, c.from, c.state)
    {body, account} = SceneServer.Body.Thermo.step(next.body, 1.0, %{q_j: 2094.0, tissue_j: 2094.0, air_k: 293.15})
    # 0.06kg × 3490 J/(kg K) = 209.4 J/K；2094 J 独立手算升温 10 K。
    assert_in_delta body.tissue_k - c.state.body.tissue_k, 10.0, 1.0e-10
    assert account.q_j == 2094.0 and account.tissue_j == 2094.0
    assert_in_delta Body.heat_content_j(body) - Body.heat_content_j(next.body), account.stored_j, 1.0e-7
  end

  test "范围外和关闭战斗场拒绝，本次采样后继续移动不撤回即时命中", c do
    for state <- [
          %{c.state | config: %{c.state.config | combat_scope: nil}},
          %{c.state | state: %{position: {6.0, 0.0, 0.0}}}
        ] do
      assert {:reply, {:error, :combat_not_permitted}, ^state} =
               Player.handle_call({:receive_effect, c.hit}, c.from, state)
    end

    moved = %{c.state | state: %{position: {2.1, 0.0, 0.0}}}

    assert {:reply, {:ok, %{body: %{life: 80}}}, _} =
             Player.handle_call({:receive_effect, c.hit}, c.from, moved)
  end

  test "工具登记绑定完整会话与请求，完成后重投不再授权", c do
    request = %{action: 1, client_intent_seq: 11, request_id: 42}

    {:reply, {:ok, actor}, state} =
      Player.handle_call({:authorize_tool, c.identity, request, %{}}, c.from, c.state)

    assert actor.action_key == {c.identity, 11}

    {:reply, {:ok, 123}, state} =
      Player.handle_call({:finish_tool, actor.action_key, {:ok, 123}}, c.from, state)

    assert {:reply, {:done, {:ok, 123}}, ^state} =
             Player.handle_call({:authorize_tool, c.identity, request, %{}}, c.from, state)

    assert {:reply, {:error, :replayed_attack}, ^state} =
             Player.handle_call(
               {:authorize_tool, c.identity, %{request | request_id: 43}, %{}},
               c.from,
               state
             )

    assert {:reply, {:error, :invalid_state}, ^state} =
             Player.handle_call(
               {:authorize_tool, %{c.identity | session_epoch: 6}, request, %{}},
               c.from,
               state
             )
  end

  test "candidate geometry omits Body report except the queried target", c do
    for requested <- [nil, c.state.id + 1] do
      assert {:reply, {:ok, %{body: nil, position: position}}, _} =
               Player.handle_call({:hit_context, requested}, c.from, c.state)

      assert position == c.state.state.position
    end

    assert {:reply, {:ok, %{body: %{life: 100}}}, _} =
             Player.handle_call({:hit_context, c.state.id}, c.from, c.state)
  end

  test "target owner leaving rejects both calls without exiting the attacker", c do
    {target, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^target, :normal}
    assert {:error, :invalid_state} = Player.hit_context(target)
    assert {:error, :invalid_state} = Player.receive_effect(target, c.hit)
  end

  # 只测试：真实 World 与 Player 回调，Scene 成员由 Members 夹具给出。手算：攻击者站 {0,0,0}、眼点 (0,0.6,0)、yaw 0（前向 +X）；
  # offset 2、radius 1 → 判定球心 (2,0.6,0)。A(20) 站 {2,0,0} 距中心 0；B(21) 站 {2,0,0.8} 距中心 0.8 ≤ 1+0.3。
  defp area_world(c) do
    root = Path.join(System.tmp_dir!(), "area_action_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    catalog = Path.join(root, "properties.json")
    materials = for id <- 0..23, do: %{material_id: id, max_hp_per_macro: 100.0,
      defense: 2.0, tags: [], responses: [%{action: "damage", multiplier: 1.0}]}
    area = %{tool_id: 23, id: "area", action: "damage", power: 30.0, target_mode: "direction",
      range_macro: 3.0, interval_seconds: 0.8, area_radius_m: 1.0, area_offset_m: 2.0, aim_max_deg: 45.0,
      body_impact: %{depth: 0.2, protein_g: 2.0, heal_s: 100.0}}
    single = Map.merge(area, %{tool_id: 22, id: "melee", target_mode: "object", interval_seconds: 0.5})
    File.write!(catalog, Jason.encode!(%{schema_version: 1, tags: [%{id: "damage"}],
      materials: materials, tools: [single, area], definitions: []}))
    world = start_supervised!({VoxelRegion.World, name: nil, source: VoxelRegion.TestSupport.Source,
      log: VoxelRegion.TestSupport.Log, observer: self(), root: root, property_catalog_path: catalog})
    # 判定球边界接触的墙 {3,0,0}：旧实现会扣它的 HP；不挡眼点到 A、B 的射线。
    assert {:ok, _} = VoxelRegion.World.apply_edit(world, {3, 0, 0}, 19)
    scene = start_supervised!(Members)
    %{world: world, scene: scene, state: %{c.state | scene: scene, body_owned: false}}
  end

  defp owner(w, id, position, config \\ %{}) do
    state = %{w.state | id: id, config: Map.merge(w.state.config, config),
      state: %{position: position, velocity: {0.0, 0.0, 0.0}, yaw: 0}}
    start_supervised!({Owner, state}, id: id)
  end

  defp swing(w, attacker, c, seq, at, changes \\ %{}) do
    request = Map.merge(%{request_id: seq, client_intent_seq: seq, logical_scene_id: 1, action: 1,
      granularity: 6, tool_id: 23, direction: {1.0, 0.0, 0.0}, owner: {0, 0},
      incarnation: 0, material: 0, micro: {0, 0, 0}}, changes)
    SceneServer.Movement.ToolAction.run(attacker, c.identity, w.world, request, %{received_us: at, clock_node: node()})
  end

  defp life(pid, id) do
    {:ok, %{body: %{life: life}}} = Player.hit_context(pid, id)
    life
  end

  defp damage(w), do: VoxelRegion.TestSupport.observe(w.world, [10], {{-1, -1, -1}, {6, 5, 5}}).damage

  test "单体段经 g6 按提示/最近者只作用一个，范围段作用区内全部，重投不重复，墙不受损", c do
    w = area_world(c)
    attacker = owner(w, 10, {0.0, 0.0, 0.0})
    a = owner(w, 20, {2.0, 0.0, 0.0})
    b = owner(w, 21, {2.0, 0.0, 0.8})
    assert :ok = GenServer.call(w.scene, {:players, [attacker, a, b]})
    walls = damage(w)
    # 单体招式不再经 g5 人物射线（设计 §6.4／§10：战斗招式一律 g6 判定区）。
    assert {:error, :stale_or_forbidden_target} =
      swing(w, attacker, c, 69, 1_000_000, %{granularity: 5, tool_id: 22, owner: {20, 0}, incarnation: 99})
    assert {:area, _, [%{target_id: 21, body: %{life: 80}}]} =
      swing(w, attacker, c, 70, 1_000_000, %{tool_id: 22, owner: {21, 0}, incarnation: 99})
    assert life(a, 20) == 100
    assert {:area, _, [%{target_id: 20, body: %{life: 80}}]} = swing(w, attacker, c, 71, 2_000_000, %{tool_id: 22})
    assert {:area, _, receipts} = result = swing(w, attacker, c, 72, 3_000_000)
    # 身体作用按既有乘数合成：两次 0.2 深度剩 0.8×0.8 = 64%。
    assert Enum.sort(Enum.map(receipts, &{&1.target_id, &1.body.life})) == [{20, 64}, {21, 64}]
    assert result == swing(w, attacker, c, 72, 3_000_000)
    assert life(a, 20) == 64 and life(b, 21) == 64
    assert damage(w) == walls
  end

  test "单体段候选先经 Harm 许可：更近的禁伤人物不抢选，作用落到区内可伤者", c do
    w = area_world(c)
    attacker = owner(w, 10, {0.0, 0.0, 0.0})
    # 手算：guarded(22) 站 {2,0,0} 距判定球心 0（最近）但自身战斗范围为空；B(21) 站 {2,0,0.8} 距中心 0.8，入区且许可。
    guarded = owner(w, 22, {2.0, 0.0, 0.0}, %{combat_scope: nil})
    b = owner(w, 21, {2.0, 0.0, 0.8})
    assert :ok = GenServer.call(w.scene, {:players, [attacker, guarded, b]})
    assert {:area, _, [%{target_id: 21, body: %{life: 80}}]} = swing(w, attacker, c, 90, 1_000_000, %{tool_id: 22})
    assert life(guarded, 22) == 100
  end

  test "打空接纳频率，朝向超限不消耗频率，区内全部被拒与战斗关闭返回拒绝且不改生命", c do
    w = area_world(c)
    attacker = owner(w, 10, {0.0, 0.0, 0.0})
    far = owner(w, 20, {2.0, 0.0, 3.0}) # 距中心 3.0，区外
    assert :ok = GenServer.call(w.scene, {:players, [attacker, far]})
    walls = damage(w)
    assert {:area, _, []} = swing(w, attacker, c, 80, 1_000_000)
    assert {:error, :tool_cooldown} = swing(w, attacker, c, 81, 1_000_000)
    # 已确认 yaw 0；方向 -X 与前向差 180° > 45°。
    assert {:error, :facing} = swing(w, attacker, c, 82, 2_000_000, %{direction: {-1.0, 0.0, 0.0}})
    assert {:area, _, []} = swing(w, attacker, c, 83, 2_000_000)
    guarded = owner(w, 22, {2.0, 0.0, 0.0}, %{combat_scope: nil})
    assert :ok = GenServer.call(w.scene, {:players, [attacker, far, guarded]})
    assert {:error, :combat_not_permitted} = swing(w, attacker, c, 84, 3_000_000)
    assert life(guarded, 22) == 100
    assert :ok = GenServer.call(w.scene, {:players, :closed})
    assert {:error, :combat_not_permitted} = swing(w, attacker, c, 85, 4_000_000)
    assert life(guarded, 22) == 100 and life(far, 20) == 100
    assert damage(w) == walls
  end
end
