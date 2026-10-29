Code.require_file("../../../voxel_region/test/support/world_fixtures.exs", __DIR__)

defmodule NpcServer.NpcCastWorldTest do
  @moduledoc """
  只测试：NPC 施法（角色能力函数库设计稿 docs/10-active/cross-cutting/2026-10-07-character-capability-library.md
  §7.8、T4.1–T4.3）。真实 VoxelRegion.World（空白 Source + 作者一次写入的石地与一块目标石，Test-only 属性目录
  b1aca503… 与热环境、魔法目录 v4 19c513f9…）、真实流送 Scene（`collision_window_radius_tiles` 1，同 world_server
  p0_body_world_test；非流送 Scene 没有 authority_ref，施法不可用，F26）、真实 Player / CollisionStream / Session.Claims /
  Body。施法命令经 `Abilities.command/4` 构造（作者法术带 `profile.spells`），Body 不知道的目录 digest 由执行进程经
  `World.magic_digest/1` 填入。不注入施法者能量或身体真值：新 NPC 能量 0。

  期望值手算自夹具 JSON 与 Voxim Docs/Magic.md §4、§13.6（公式见 `VoxelRegion.Magic.Cost` moduledoc，这里不调用它）：
  程序 = 目录预设 ignite_near（act.heat，energy_j 400 000）。rest_pose 全 0 → act.heat 姿态 [45, −90, 90, −90, 0, 0]°：
  d = √(45² + 90² + 90² + 90²)° = 162.2498…° = 2.8317933498 rad；S = 1（权重），H = 400 000 J，
  b = b0·(S + H/E_ref)^α = 1000·1.4^1.5 = 1656.5023393 W；T_adj = d·√(η/b) = 2.8317933·√(50/1656.5023) = 0.4919834945 s，
  T_inj = E/P_max = 400 000/1 000 000 = 0.4 s，release_lead_s = 0 → 前摇 0.8919834945 s；
  E_loss = 2·d·√(η·b) + b·T_inj = 2·2.8317933·√82 825.117 + 662.6009 = 2292.5445548 J → 报价 402 292.5445548 J。
  结构 S = 1 ≤ 相干度 4（目录 4.0 × 健康身体系数 1.0），能量 0 < 报价 → 走火 misfire_energy，
  支出 = min(报价, 余额 0) = 0、施放后能量 0。
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias NpcServer.{Abilities, Body}
  alias SceneServer.Movement.{Player, Scene}
  alias VoxelRegion.World

  @fixtures Path.expand("../../../voxel_region/test/fixtures", __DIR__)
  @catalog "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  @magic "19c513f9ceb29b327ae1f5fb07edcea8e8001adc1a6f938078095e214aceba88"
  @npc 9201
  @stone 11
  # 地面石 y = 3（x、z 0..15），目标石 (6, 4, 9)：NPC 站在 (6.5, ·, 6.5)，目标宏格中心在 +Z 约 3 m、低于眼点。
  @target {6, 4, 9}
  # 作者法术带（D-10）：目录预设 ignite_near 原样。
  @ignite ~s({"v":1,"target":{"kind":"aim"},"emit":"at_target","steps":[{"sym":"act.heat","args":{"energy_j":400000,"power_w":200000}}]})
  @spells %{spells: %{"ignite" => @ignite}}
  # 手算见 moduledoc。
  @quote_j 402_292.5445548
  @windup_ms 892

  defmodule Route do
    def route(1),
      do:
        {:ok,
         %{
           scene_ref: Process.whereis(:npc_cast_scene),
           world_ref: Process.whereis(:npc_cast_world),
           scene_epoch: 7
         }}
  end

  # 只测试：把每个 Outcome 与 Observation 里 self.caster 的变化原样转给测试进程；自己不发命令。
  defmodule Relay do
    @behaviour NpcServer.Brain
    def init(%{owner: owner}), do: %{owner: owner, caster: nil}

    def handle_event({:outcome, outcome}, state) do
      send(state.owner, {:outcome, outcome})
      {[], state}
    end

    def handle_event({:observation, %{self: %{caster: caster}}}, %{caster: last} = state)
        when caster != last do
      send(state.owner, {:caster, caster})
      {[], %{state | caster: caster}}
    end

    def handle_event(_event, state), do: {[], state}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "npc_cast_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    world =
      start_supervised!(
        {World,
         source: VoxelRegion.TestSupport.Source,
         root: root,
         observer: self(),
         name: :npc_cast_world,
         property_catalog_path: Path.join([@fixtures, "combustion", @catalog <> ".json"]),
         thermal_environment_path:
           Path.join([@fixtures, "combustion", "environment-radiation.json"]),
         magic_catalog_path: Path.join([@fixtures, "magic", @magic <> ".json"]),
         prefab_catalog_path: nil}
      )

    # 作者入口一次写入。
    floor = for x <- 0..15, z <- 0..15, do: {{x, 3, z}, @stone}
    {:ok, _} = World.apply_edits(world, floor ++ [{@target, @stone}])

    profile =
      Path.expand("../../../../../Voxim/Docs/M0/fixtures/suite.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("profile")
      |> Map.put("fixed_hz", 60)

    config = %{
      "schema" => "voxim-m1-demo-v1",
      "l0_min" => [0, 0, 0],
      "l0_max_exclusive" => [1, 1, 1],
      "travel_min_m" => [2.0, 2.0, 2.0],
      "travel_max_exclusive_m" => [14.0, 14.0, 14.0],
      "spawn_probes_m" => [[6.5, 10.0, 6.5]],
      "spawn_min_y_m" => 3.0,
      "collision_window_radius_tiles" => 1,
      "profile" => profile
    }

    replica =
      start_supervised!(
        {VoxelRegion.Replica, [authority_ref: world, l0_box: {{0, 0, 0}, {1, 1, 1}}, name: nil]}
      )

    body_store = start_supervised!({MmoTest.BodyStore, []})

    scene =
      start_supervised!(
        {Scene,
         [
           name: :npc_cast_scene,
           scene_id: 1,
           scene_epoch: 7,
           world_ref: replica,
           world_api: VoxelRegion.Replica,
           body_store: {MmoTest.BodyStore, store: body_store},
           config: config
         ]}
      )

    await(fn -> Scene.observe(scene).initialized || nil end, 30_000)
    claims = start_supervised!({WorldServer.Session, route_module: Route})

    body =
      start_supervised!(
        {Body,
         claims: claims,
         route_module: Route,
         scene_id: 1,
         cid: @npc,
         bounds: {{0, 0, 0}, {64, 64, 64}},
         spawn: {6.5, 10.0, 6.5},
         brain: {Relay, Map.merge(@spells, %{owner: self()})}},
        restart: :temporary
      )

    %{world: world, body: body}
  end

  defp await(fun, timeout), do: await_until(fun, System.monotonic_time(:millisecond) + timeout)

  defp await_until(fun, deadline) do
    case fun.() do
      nil ->
        assert System.monotonic_time(:millisecond) < deadline, "condition not reached"
        Process.sleep(50)
        await_until(fun, deadline)

      value ->
        value
    end
  end

  defp outcome(id, timeout \\ 5_000) do
    assert_receive {:outcome, %{id: ^id} = outcome}, timeout
    outcome
  end

  # 沿眼点到目标宏格中心的方向探测（镐 tool 1，射程 8 格）：done data 即目标句柄（含本次 direction）。
  defp probe(body) do
    {ex, ey, ez} = Player.eye_position(await(fn -> Body.observe(body).position end, 10_000))
    {tx, ty, tz} = @target
    {dx, dy, dz} = {tx + 0.5 - ex, ty + 0.5 - ey, tz + 0.5 - ez}
    length = :math.sqrt(dx * dx + dy * dy + dz * dz)

    Body.command(body, %{
      id: :probe,
      verb: :probe_toward,
      tool_id: 1,
      direction: {dx / length, dy / length, dz / length}
    })

    assert %{status: :done, data: handle} = outcome(:probe)
    # g0 命中的 micro = 宏格 × 8。
    assert %{granularity: 0, micro: {48, 32, 72}, material: @stone, owner: {0, 0}} = handle
    handle
  end

  # LLM / 行为树的写法：句柄抄成 JSON（数组、字符串键），法术只给名字，程序字节由 profile.spells 填入。
  defp cast(body, id, handle) do
    target = %{
      "granularity" => handle.granularity,
      "micro" => Tuple.to_list(handle.micro),
      "incarnation" => handle.incarnation,
      "owner" => Tuple.to_list(handle.owner),
      "material" => handle.material,
      "direction" => Tuple.to_list(handle.direction)
    }

    command =
      Abilities.command("cast_spell", %{"spell" => "ignite", "target" => target}, id, @spells)

    assert %{verb: :cast_spell, program: @ignite} = command
    Body.command(body, command)
  end

  # 前摇已登记在角色 owner 上的证据：同一句柄的 use_tool 被施法互斥挡下（authorize_tool 回 casting）。
  defp blocked_by_cast(body, handle) do
    Body.command(body, %{
      id: :dig,
      verb: :use_tool,
      tool_id: 1,
      target: handle,
      direction: handle.direction
    })

    assert %{status: :rejected, reason: :casting} = outcome(:dig)
  end

  test "T4.1 施放：前摇中工具回 casting、再施放回 cast_too_soon；前摇结束后 World 结算为走火，Outcome 带原样回复",
       %{world: world, body: body} do
    handle = probe(body)
    started = System.monotonic_time(:millisecond)
    cast(body, :cast, handle)
    blocked_by_cast(body, handle)

    # 前摇中再施放：Player 立即拒绝，经同一 reply_to 回到 Body（T4.4 的 Body 侧，死亡见 scene cast_action_test）。
    cast(body, :again, handle)
    assert %{status: :rejected, reason: :cast_too_soon} = outcome(:again)

    assert %{status: :done, data: %{seq: seq, outcome: :misfire_energy, caster: caster}} =
             outcome(:cast)

    assert System.monotonic_time(:millisecond) - started >= @windup_ms
    assert is_integer(seq) and caster.seq == seq
    assert caster.energy_j == 0.0 and caster.spent_j == 0.0
    assert caster.quote_s == 1.0 and caster.capacity_j == 5.0e6 and caster.coherence == 4.0
    assert_in_delta caster.quote_j, @quote_j, 1.0e-4

    # Observation 的 self.caster 只取自施法回复（{:mmo_spell_reply, …}）。
    assert_receive {:caster, %{energy_j: +0.0, capacity_j: 5.0e6, coherence: 4.0}}
    refute_receive {:outcome, %{id: :cast}}, 300
    assert {:ok, %{energy_j: +0.0}} = World.caster_state(world, @npc)
  end

  test "T4.2 取消：前摇中 cancel_cast 完成，原施法以 cast_cancelled 结束且不再结算；没有前摇时 no_active_cast",
       %{world: world, body: body} do
    handle = probe(body)
    {:ok, %{energy_j: energy}} = World.caster_state(world, @npc)
    cast(body, :cast, handle)
    Body.command(body, Abilities.command("cancel_cast", %{}, :cancel, @spells))

    assert %{status: :done, data: data} = outcome(:cancel)
    assert data == %{}
    assert %{status: :rejected, reason: :cast_cancelled} = outcome(:cast)

    # 等过整段前摇：World 不在取消后结算。结算的回复会被 Body 忽略（id 已不在表中），能量 0 → 0 也看不出差别；
    # 而 World 结算时先发给 caster_recipient 的施法者状态会经 Observation 的 self.caster 出现（初值 nil，会话一直在），
    # 它不出现才说明没有结算。
    refute_receive {:caster, _}, @windup_ms + 300
    refute_received {:outcome, %{id: :cast}}
    assert {:ok, %{energy_j: ^energy}} = World.caster_state(world, @npc)

    Body.command(body, %{id: :late, verb: :cancel_cast})
    assert %{status: :rejected, reason: :no_active_cast} = outcome(:late)
  end

  test "T4.3a 前摇中经 Player.stop/1 结束会话：恰好一个终态 cast_cancelled，能量不变",
       %{world: world, body: body} do
    handle = probe(body)

    # 会话结束后没有 Observation，改在 World 侧看：每笔施放 / 走火结算 World 记一行 voxel_spell。
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    log =
      capture_log(fn ->
        cast(body, :cast, handle)
        blocked_by_cast(body, handle)
        # 角色 owner 已登记动作不等于 World 已开始前摇：prepare_cast 可能仍在等装页，此时取消会经 page_cancel
        # 撤回未接纳的请求、World 不开始前摇。本例要测的是前摇中结束会话，故先等 World 的待施放记录（live 1）出现。
        await(fn -> match?(%{live: 1}, VoxelRegion.TestSupport.observe(world, [@npc], {{0, 0, 0}, {16, 16, 16}}).casts[@npc]) || nil end, 5_000)

        %{player: player} = :sys.get_state(body)
        assert :ok = Player.stop(player)

        assert %{status: :rejected, reason: :cast_cancelled} = outcome(:cast)
        refute_receive {:outcome, %{id: :cast}}, @windup_ms + 600
      end)

    # 判定器自检：捕获到了本 cid 的施放开始行，才说明这段日志看得见 World 的 info 行；整段前摇之后仍没有结算行。
    assert log =~ ~r/voxel_cast_begin seq=\d+ cid=#{@npc} /
    refute log =~ ~r/voxel_spell seq=\d+ cid=#{@npc} /
    assert {:ok, %{energy_j: +0.0}} = World.caster_state(world, @npc)
  end

  test "T4.3b 前摇中 Player 被 kill：恰好一个终态（World 的 invalid_session 与 Body 的 session_lost 先到者）",
       %{body: body} do
    handle = probe(body)
    cast(body, :cast, handle)
    blocked_by_cast(body, handle)

    %{player: player} = :sys.get_state(body)
    Process.exit(player, :kill)

    assert %{status: :rejected, reason: reason} = outcome(:cast)
    assert reason in [:session_lost, :invalid_session]
    refute_receive {:outcome, %{id: :cast}}, @windup_ms + 600
  end
end
