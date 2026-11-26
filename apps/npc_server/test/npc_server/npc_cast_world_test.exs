Code.require_file("../../../voxel_region/test/support/world_fixtures.exs", __DIR__)

defmodule NpcServer.NpcCastWorldTest do
  @moduledoc """
  只测试：NPC 施法（角色能力函数库设计稿 docs/10-active/cross-cutting/2026-10-07-character-capability-library.md
  §7.8、T4.1–T4.3；魔法 v2 切片 3 决策稿 docs/10-active/magic/2026-11-19-slice3-protocol.md §7、§9 N-3 / N-4、P10）。
  真实 VoxelRegion.World（空白 Source + 作者一次写入的石地与一块蓄能石，Test-only 属性目录 b1aca503… 与热环境
  `environment-radiation.json`，魔法目录 v5 发布物 `voxel_region/priv/magic/<sha256>.json`）、真实流送 Scene
  （`collision_window_radius_tiles` 1，同 world_server p0_body_world_test；非流送 Scene 没有 authority_ref，施法不可用，F26）、
  真实 Player / CollisionStream / Session.Claims / Body。施法命令经 `Abilities.command/4` 构造（作者法术带 `profile.spells`），
  Body 不知道的目录 digest 由执行进程经 `World.magic_digest/1` 填入。不注入施法者能量或身体真值：新 NPC 能量 0。

  前提：蓄能石的 10 MJ 储能经持久化边界安装一次（同 voxel_region magic_world_test：新蓄能石为空，单测无法经正常玩法充满），
  之后只经正式施法入口变化。程序字节只取自冻结样本：`ir-v2-samples.json`（draw_1mj、lamp）与 `quote-v2-samples.json`
  的 `rejected` 表（t13_first_tick：灯的〈蓄〉改为 600 J，客户端编辑器同样能写出）；`v1_ignite` 是迁移前 NPC 法术带里的
  v1 JSON 程序原样（`profile.spells` 未迁移时实际会有的字节）。

  期望值只取自报价样本与目录常数，不调 `Magic.Cost`：〈取〉1 MJ 的构型损耗 = 样本 draw_1mj 的 total 560 750 mJ、
  前摇 0.430375 s；目录 η 0.9 → 施放后能量 0.9 × 1 MJ − 560.75 J、蓄能石剩 9 MJ；Ω_eff = 目录 `resolution_omega` 16 ×
  健康身体系数 1.0；S·P = 1 × 1。
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias NpcServer.{Abilities, Body}
  alias SceneServer.Movement.{Player, Scene}
  alias VoxelRegion.{OverlayLog, World}

  @fixtures Path.expand("../../../voxel_region/test/fixtures", __DIR__)
  @properties "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  @magic Path.expand("../../../voxel_region/priv/magic", __DIR__)
         |> Path.join("*.json")
         |> Path.wildcard()
         |> then(fn [path] -> path end)
  @ir Path.join(@fixtures, "magic/ir-v2-samples.json") |> File.read!() |> Jason.decode!()
  @quotes Path.join(@fixtures, "magic/quote-v2-samples.json") |> File.read!() |> Jason.decode!()
  @external_resource @magic
  @external_resource Path.join(@fixtures, "magic/ir-v2-samples.json")
  @external_resource Path.join(@fixtures, "magic/quote-v2-samples.json")
  @npc 9201
  @stone 11
  @battery 42
  # 地面石 y = 3（x、z 0..15），蓄能石 (6, 4, 9)：NPC 站在 (6.5, ·, 6.5)，目标宏格中心在 +Z 约 3 m（施法域 6 m 内）。
  @target {6, 4, 9}

  @draw @ir["samples"] |> Enum.find(&(&1["id"] == "draw_1mj")) |> Map.fetch!("program_hex")
  @lamp @ir["samples"] |> Enum.find(&(&1["id"] == "lamp")) |> Map.fetch!("program_hex")
  @faint_lamp @quotes["rejected"]
              |> Enum.find(&(&1["id"] == "t13_first_tick"))
              |> Map.fetch!("program_hex")
  @v1_ignite ~s({"v":1,"target":{"kind":"aim"},"emit":"at_target","steps":[{"sym":"act.heat","args":{"energy_j":400000,"power_w":200000}}]})
  # 作者法术带（登记后的形状：名字 → IR v2 字节）。
  @spells %{
    spells: %{
      "draw" => Base.decode16!(@draw, case: :lower),
      "lamp" => Base.decode16!(@lamp, case: :lower),
      "faint_lamp" => Base.decode16!(@faint_lamp, case: :lower),
      "v1_ignite" => @v1_ignite
    }
  }
  @draw_quote @quotes["presets"] |> Enum.find(&(&1["id"] == "draw_1mj")) |> Map.fetch!("quote")
  @loss_j @draw_quote["total_mj"] / 1000
  @windup_ms trunc(@draw_quote["windup_s"] * 1000)
  @gained_j 0.9 * 1_000_000

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

    world = start_world(root)

    # 作者入口一次写入。
    floor = for x <- 0..15, z <- 0..15, do: {{x, 3, z}, @stone}
    {:ok, _} = World.apply_edits(world, floor ++ [{@target, @battery}])

    # 作者初态：查询蓄能石的正式属性行，再经持久化边界写入 10 MJ 储能（见 moduledoc）。
    {:ok, row} = World.tool_intent(world, scout(), battery_query())
    seq = World.seq(world)
    :ok = stop_supervised(:npc_cast_world)

    OverlayLog.File.append(Path.join(root, "overlay.log"), %{
      seq: seq + 1,
      entries: [],
      coarse: [],
      property_states: [Map.merge(row, %{stored_j: 1.0e7, seq: seq + 1, request_id: 0})]
    })

    world = start_world(root)
    assert stored_j(world) == 1.0e7

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

    body_opts = [
      claims: claims,
      route_module: Route,
      scene_id: 1,
      cid: @npc,
      bounds: {{0, 0, 0}, {64, 64, 64}},
      spawn: {6.5, 10.0, 6.5},
      brain: {Relay, Map.merge(@spells, %{owner: self()})}
    ]

    body = start_supervised!({Body, body_opts}, restart: :temporary)
    %{world: world, body: body, body_opts: body_opts}
  end

  defp start_world(root),
    do:
      start_supervised!(
        {World,
         source: VoxelRegion.TestSupport.Source,
         root: root,
         observer: self(),
         name: :npc_cast_world,
         property_catalog_path: Path.join([@fixtures, "combustion", @properties <> ".json"]),
         thermal_environment_path:
           Path.join([@fixtures, "combustion", "environment-radiation.json"]),
         magic_catalog_path: @magic,
         prefab_catalog_path: nil},
        id: :npc_cast_world
      )

  # 只用于安装储能前查询蓄能石属性行的作者替身（工具射程内、眼点在目标上方偏 −Z）。
  defp scout do
    a = %{
      cid: 1,
      gate: self(),
      identity: make_ref(),
      refresh: &VoxelRegion.TestSupport.Actor.tool_context/2,
      eye: {6.5, 5.6, 6.5},
      feet: {6.5, 4.0, 6.5},
      tick_us: 16_667
    }

    Map.put(a, :player, start_supervised!({VoxelRegion.TestSupport.Actor, a}, id: make_ref()))
  end

  defp battery_query do
    {x, y, z} = @target
    {dx, dy, dz} = {x + 0.5 - 6.5, y + 0.5 - 5.6, z + 0.5 - 6.5}
    n = :math.sqrt(dx * dx + dy * dy + dz * dz)

    %{
      request_id: 1,
      client_intent_seq: 1,
      logical_scene_id: 1,
      action: 0,
      tool_id: 1,
      direction: {dx / n, dy / n, dz / n},
      micro: {x * 8 + 4, y * 8 + 4, z * 8 + 4},
      granularity: 0,
      incarnation: 0,
      owner: {0, 0},
      material: 0
    }
  end

  defp stored_j(world) do
    {x, y, z} = @target

    VoxelRegion.TestSupport.observe(world, [@npc], {{0, 0, 0}, {16, 16, 16}}).damage
    |> Map.values()
    |> Enum.find(&(&1.granularity == 0 and &1.micro == {x * 8, y * 8, z * 8}))
    |> Map.fetch!(:stored_j)
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
    assert %{granularity: 0, micro: {48, 32, 72}, material: @battery, owner: {0, 0}} = handle
    handle
  end

  # LLM / 行为树的写法：句柄抄成 JSON（数组、字符串键），法术只给名字，程序字节由 profile.spells 填入。
  defp cast(body, id, handle, spell \\ "draw") do
    target = %{
      "granularity" => handle.granularity,
      "micro" => Tuple.to_list(handle.micro),
      "incarnation" => handle.incarnation,
      "owner" => Tuple.to_list(handle.owner),
      "material" => handle.material,
      "direction" => Tuple.to_list(handle.direction)
    }

    command =
      Abilities.command("cast_spell", %{"spell" => spell, "target" => target}, id, @spells)

    program = @spells.spells[spell]
    assert %{verb: :cast_spell, program: ^program} = command
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

  test "T4.1 / N-3 施放：前摇中工具回 casting、再施放回 cast_too_soon；前摇结束后〈取〉建成，Outcome 带原样回复",
       %{world: world, body: body} do
    handle = probe(body)
    started = System.monotonic_time(:millisecond)
    cast(body, :cast, handle)
    blocked_by_cast(body, handle)

    # 前摇中再施放：Player 立即拒绝，经同一 reply_to 回到 Body（T4.4 的 Body 侧，死亡见 scene cast_action_test）。
    cast(body, :again, handle)
    assert %{status: :rejected, reason: :cast_too_soon} = outcome(:again)

    # 结算回复带 fail_step（魔法 v2 切片 6，决策稿 §3.4 / R2）：建成为 0。
    assert %{status: :done, data: %{seq: seq, outcome: nil, fail_step: 0, caster: caster}} = outcome(:cast)
    assert System.monotonic_time(:millisecond) - started >= @windup_ms
    assert is_integer(seq) and caster.seq == seq
    assert caster.capacity_j == 5.0e6 and caster.resolution_eff == 16.0 and caster.quote_s == 1.0
    assert_in_delta caster.quote_j, @loss_j, 1.0e-9
    assert_in_delta caster.spent_j, @loss_j, 1.0e-9
    assert_in_delta caster.energy_j, @gained_j - @loss_j, 1.0e-6

    # Observation 的 self.caster 只取自施法回复（{:mmo_spell_reply, …}）。
    assert_receive {:caster, %{energy_j: energy, capacity_j: 5.0e6, resolution_eff: 16.0}}
    assert_in_delta energy, @gained_j - @loss_j, 1.0e-6
    refute_receive {:outcome, %{id: :cast}}, 300
    assert {:ok, %{energy_j: left}} = World.caster_state(world, @npc)
    assert_in_delta left, @gained_j - @loss_j, 1.0e-6
    assert stored_j(world) == 9.0e6
  end

  # 魔法 v2 切片 6（决策稿 §3.4、§11.1 R2）：NPC 的 Outcome 原样带 World 结算回复，所以拿得到中断步 k。新 NPC 余额 0，灯在
  # 第 1 步〈握〉（累计 286.787 J）余额不足：World 预判第 1 步中断，Player 到 t_1 检查，World 结算 interrupted_energy、fail_step 1。
  test "结构法术在第 k 步中断：NPC Outcome 的 data 带 fail_step（k = 1），扣到余额为止（0）",
       %{world: world, body: body} do
    handle = probe(body)
    cast(body, :lamp, handle, "lamp")
    assert %{status: :done, data: %{outcome: :interrupted_energy, fail_step: 1, caster: caster}} = outcome(:lamp)
    assert caster.spent_j == 0.0
    assert {:ok, %{energy_j: +0.0}} = World.caster_state(world, @npc)
  end

  # 魔法 v2 切片 6（决策稿 Q6-4）：主动取消的原因是 interrupted_cancelled；取消紧跟施放、在第一笔注能前，免费（k = 0）。
  test "T4.2 取消：前摇中 cancel_cast 完成，原施法以 interrupted_cancelled 结束且不再结算；没有前摇时 no_active_cast",
       %{world: world, body: body} do
    handle = probe(body)
    cast(body, :cast, handle)
    Body.command(body, Abilities.command("cancel_cast", %{}, :cancel, @spells))

    assert %{status: :done, data: data} = outcome(:cancel)
    assert data == %{}
    assert %{status: :rejected, reason: :interrupted_cancelled} = outcome(:cast)

    # 等过整段前摇：World 不在取消后结算。结算时 World 先发给 caster_recipient 的施法者状态会经 Observation 的
    # self.caster 出现（初值 nil，会话一直在；进入场景的报价校验不经 Body，不改它），它不出现才说明没有结算。
    refute_receive {:caster, _}, @windup_ms + 300
    refute_received {:outcome, %{id: :cast}}
    assert {:ok, %{energy_j: +0.0}} = World.caster_state(world, @npc)
    assert stored_j(world) == 1.0e7

    Body.command(body, %{id: :late, verb: :cancel_cast})
    assert %{status: :rejected, reason: :no_active_cast} = outcome(:late)
  end

  test "T4.3a 前摇中经 Player.stop/1 结束会话：恰好一个终态 cast_cancelled，能量不变",
       %{world: world, body: body} do
    handle = probe(body)

    # 会话结束后没有 Observation，改在 World 侧看：每笔施放结算 World 记一行 voxel_spell。
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    log =
      capture_log(fn ->
        cast(body, :cast, handle)
        blocked_by_cast(body, handle)

        # 角色 owner 已登记动作不等于 World 已开始前摇：prepare_cast 可能仍在等装页，此时取消会经 page_cancel
        # 撤回未接纳的请求、World 不开始前摇。本例要测的是前摇中结束会话，故先等 World 的待施放记录（live 1）出现。
        await(
          fn ->
            match?(
              %{live: 1},
              VoxelRegion.TestSupport.observe(world, [@npc], {{0, 0, 0}, {16, 16, 16}}).casts[
                @npc
              ]
            ) || nil
          end,
          5_000
        )

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

  # P10：会话就绪时逐个 action 0 报价。灯（〈握〉）可用；〈取〉需要目标，竖直向上的报价射线落空（:no_target），只校验到
  # World 的解码；t13_first_tick 的 rejects = [first_tick]、v1 JSON 是 :invalid_program，两者被剔除并各写一行
  # npc_spell_rejected。被拒程序的 cast_spell 由 Body 就地回 spell_rejected，不进 World。
  test "N-4 进入场景报价校验：被拒的法术就地回 spell_rejected 并写 npc_spell_rejected；可用与需目标的照常",
       %{body: body, body_opts: body_opts} do
    # setup 起的 Body 已在会话就绪时校验过、日志没被捕获：换一个同 cid 的新 Body（新 claim 顶替旧会话），在捕获内重来。
    :ok = stop_supervised(Body)
    refute Process.alive?(body)

    log =
      capture_log(fn ->
        body = start_supervised!({Body, body_opts}, restart: :temporary)

        # 校验结果只在 Body 的派生状态里（不是 Observation 字段）：读到 digest 即校验完成。
        checked =
          await(
            fn ->
              case spell_check(body) do
                %{digest: <<_::256>>} = checked -> checked
                _ -> nil
              end
            end,
            15_000
          )

        assert checked.digest == :crypto.hash(:sha256, File.read!(@magic))

        assert checked.rejected == %{
                 @spells.spells["faint_lamp"] => {:rejects, [:first_tick]},
                 @v1_ignite => :invalid_program
               }

        handle = probe(body)
        cast(body, :faint, handle, "faint_lamp")

        assert %{status: :rejected, reason: {:spell_rejected, {:rejects, [:first_tick]}}} =
                 outcome(:faint)

        cast(body, :old, handle, "v1_ignite")
        assert %{status: :rejected, reason: {:spell_rejected, :invalid_program}} = outcome(:old)

        # 可用的法术照常交给 World（〈取〉建成）。
        cast(body, :draw, handle, "draw")
        assert %{status: :done, data: %{outcome: nil}} = outcome(:draw)
      end)

    assert log =~
             ~r/npc_spell_rejected npc=#{@npc} name="faint_lamp" program_sha=[0-9a-f]{16} bytes=\d+ digest=[0-9a-f]{16} reason=\{:rejects, \[:first_tick\]\}/

    assert log =~ ~r/npc_spell_rejected npc=#{@npc} name="v1_ignite" .* reason=:invalid_program/
    refute log =~ ~r/npc_spell_rejected npc=#{@npc} name="(lamp|draw)"/
    refute log =~ ~r/npc_spell_unverified/
  end

  defp spell_check(body), do: :sys.get_state(body).spell_check
end
