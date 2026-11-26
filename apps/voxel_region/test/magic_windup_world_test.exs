defmodule VoxelRegion.MagicWindupWorldTest do
  @moduledoc """
  只测试：施放前摇在真实 World 里的待施放、广播、取消与装页（魔法 v2 切片 3；决策稿
  `docs/10-active/magic/2026-11-19-slice3-protocol.md` §3.3、§9 W-7/W-8，现行施法分段合同 `cast-phases-2026-10-05.md`）。

  目录与场景同 `MagicWorldTest`：材料 `b1aca503…`，魔法 v5 发布物 `priv/magic/<sha256>.json`；地面石 11 铺 y = 0，
  施法者脚 (0.5, 1.0, 0.5)、眼 (0.5, 2.5, 0.5)，蓄能石 (2,1,0)（作者初态 10 MJ，经持久化边界安装一次），孤立叶 (0,2,3)。
  期望的前摇与各步时长只取自报价样本 `quote-v2-samples.json`。用例在待施放出现后直接投递授权，不等墙钟。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.{World, OverlayLog}
  alias VoxelRegion.TestSupport.{Actor, Log, Source}

  @properties "b1aca50376c972b4d40b75f19bc6fb36a535e897e0ae73223e8b0e52235aa3ec"
  @fixtures Path.expand("fixtures", __DIR__)
  @catalog Path.expand("../priv/magic", __DIR__)
           |> Path.join("*.json")
           |> Path.wildcard()
           |> then(fn [path] -> path end)
  @ir Path.join(@fixtures, "magic/ir-v2-samples.json") |> File.read!() |> Jason.decode!()
  @quotes Path.join(@fixtures, "magic/quote-v2-samples.json") |> File.read!() |> Jason.decode!()
  @external_resource @catalog
  @external_resource Path.join(@fixtures, "magic/ir-v2-samples.json")
  @external_resource Path.join(@fixtures, "magic/quote-v2-samples.json")
  @stone 11
  @leaf 28
  @battery 42
  @box {{-2, -2, -2}, {2, 2, 2}}
  @simulation_box {{-2, 0, -2}, {9, 3, 5}}
  @cid 1001
  @stone_micro {20, 12, 4}
  @leaf_micro {4, 20, 28}

  setup do
    root = Path.join(System.tmp_dir!(), "magic_windup_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.cp!(
      Path.join([@fixtures, "combustion", @properties <> ".json"]),
      Path.join(root, "properties.json")
    )

    File.cp!(
      Path.join([@fixtures, "combustion", "environment-radiation.json"]),
      Path.join(root, "environment.json")
    )

    File.cp!(@catalog, Path.join(root, "magic.json"))
    w = start(root)
    ground = for x <- -2..8, z <- -2..4, do: {{x, 0, z}, @stone}
    {:ok, _} = World.apply_edits(w, ground ++ [{{2, 1, 0}, @battery}, {{0, 2, 3}, @leaf}])
    a = actor()
    {:ok, row} = World.tool_intent(w, a, query(a, @stone_micro))
    seq = World.seq(w)
    :ok = stop_supervised(:world)

    OverlayLog.File.append(Path.join(root, "overlay.log"), %{
      seq: seq + 1,
      entries: [],
      coarse: [],
      property_states: [Map.merge(row, %{stored_j: 1.0e7, seq: seq + 1, request_id: 0})]
    })

    w = start(root)
    :ok = VoxelRegion.TestSupport.activate_simulation(w, @simulation_box)
    %{w: w, root: root, a: a, digest: :crypto.hash(:sha256, File.read!(@catalog))}
  end

  defmodule FailLog do
    @moduledoc "只测试：文件日志后端，`arm/0` 后读页抛错（模拟装页读库失败；故障只注入在装页边界）。"
    alias VoxelRegion.TestSupport.Log
    defdelegate open(path, cv), to: Log
    defdelegate replay(path), to: Log
    defdelegate append(path, txn), to: Log
    defdelegate checkpoint(path, txn), to: Log
    defdelegate prefix(path), to: Log
    defdelegate clear_unpublished(path, prefix), to: Log
    defdelegate write_pages(path, cut, rows), to: Log
    defdelegate publish(path, cut, rows, globals), to: Log
    defdelegate load(path), to: Log
    defdelegate load_head(path, code), to: Log
    defdelegate locate(path, ids), to: Log
    defdelegate page_keys(path), to: Log
    defdelegate collect(path, prefix, limit), to: Log
    def arm, do: :persistent_term.put(__MODULE__, true)
    def disarm, do: :persistent_term.erase(__MODULE__)

    def read_pages(path, keys, fragments) do
      if :persistent_term.get(__MODULE__, false), do: raise("test-only page read failure")
      Log.read_pages(path, keys, fragments)
    end
  end

  # Test-only: isolate World from background 500 ms thermal commits so post-edit /
  # post-settlement World.seq assertions cannot race an unrelated thermal tick.
  defmodule ManualClock do
    @behaviour VoxelRegion.World.Clock
    @impl true
    def now(_), do: 0
    @impl true
    def schedule(_, _, _, _), do: make_ref()
    @impl true
    def cancel(_, _), do: false
  end

  defp start(root, log \\ Log) do
    start_supervised!(
      {World,
       [
         source: Source,
         log: log,
         root: root,
         observer: self(),
         name: nil,
         clock: {ManualClock, nil},
         property_catalog_path: Path.join(root, "properties.json"),
         thermal_environment_path: Path.join(root, "environment.json"),
         magic_catalog_path: Path.join(root, "magic.json")
       ]},
      id: :world
    )
  end

  defp actor do
    a = %{
      cid: @cid,
      gate: self(),
      identity: make_ref(),
      refresh: &Actor.tool_context/2,
      eye: {0.5, 2.5, 0.5},
      feet: {0.5, 1.0, 0.5},
      tick_us: 16_667
    }

    Map.put(a, :player, start_supervised!({Actor, a}, id: make_ref()))
  end

  defp next, do: System.unique_integer([:positive, :monotonic])
  defp observe(w), do: VoxelRegion.TestSupport.observe(w, [@cid], @box)
  defp energy(c), do: elem(World.caster_state(c.w, @cid), 1).energy_j

  defp program(id),
    do:
      Enum.find(@ir["samples"], &(&1["id"] == id))["program_hex"] |> Base.decode16!(case: :lower)

  defp sample(id), do: Enum.find(@quotes["presets"], &(&1["id"] == id))["quote"]

  defp query(a, {x, y, z} = micro) do
    {ex, ey, ez} = a.eye
    {dx, dy, dz} = {(x + 0.5) / 8 - ex, (y + 0.5) / 8 - ey, (z + 0.5) / 8 - ez}
    n = :math.sqrt(dx * dx + dy * dy + dz * dz)
    seq = next()

    %{
      request_id: seq,
      client_intent_seq: seq,
      logical_scene_id: 1,
      action: 0,
      tool_id: 1,
      direction: {dx / n, dy / n, dz / n},
      micro: micro,
      granularity: 0,
      incarnation: 0,
      owner: {0, 0},
      material: 0
    }
  end

  # 施法意图（目标身份先经工具查询取得，与客户端命中同一射线）与带入口时钟的施法者。
  defp request(c, micro, program, at, action \\ 1) do
    {:ok, target} = World.tool_intent(c.w, c.a, query(c.a, micro))
    seq = next()

    request = %{
      request_id: seq,
      client_intent_seq: seq,
      logical_scene_id: 1,
      action: action,
      catalog_digest: c.digest,
      direction: query(c.a, micro).direction,
      program: program
    }

    {Map.merge(c.a, %{received_us: at, clock_node: node()}),
     Map.merge(request, Map.take(target, [:micro, :granularity, :incarnation, :owner, :material]))}
  end

  # 在调用方进程外发出施放（调用在结算后才返回），等到待施放出现在观察快照里再返回该记录。
  defp begin(c, micro, program, at) do
    {actor, request} = request(c, micro, program, at)
    task = Task.async(fn -> World.spell_intent(c.w, actor, request) end)
    record = Enum.find_value(1..2_000, fn _ -> observe(c.w).casts[@cid] end)
    assert record, "pending cast never appeared"
    {task, request, record}
  end

  defp settle(c, request) do
    {:ok, actor} = Actor.tool_context(c.a.player, c.a.identity)
    send(c.w, {:authorize_cast, {actor.identity, request.client_intent_seq}, actor, request})
  end

  # Player 发给 World 的角色快照（与真实 `Player.actor_context/1` 同形，含身体系数）。
  defp snapshot(c, actor) do
    {:ok, current} = Actor.tool_context(c.a.player, c.a.identity)
    Map.merge(current, Map.take(actor, [:received_us, :clock_node]))
  end

  defp funded(c) do
    {a, r} = request(c, @stone_micro, program("draw_1mj"), 1_000_000)
    assert {:ok, %{outcome: nil}} = VoxelRegion.TestSupport.spell(c.w, a, r)
    energy(c)
  end

  # W-8：若前摇或施放记录不是来自同一份报价（例如步序回到字节序、漏 part_index、出手前置没算进前摇），记录与样本对不上。
  test "W-8 前摇：施放记录的各步 {part_index, 调整, 注能} 与报价样本一致、出发点 = 手边、程序字节原样；授权后才结算", c do
    ref = make_ref()
    :ok = World.canonical_snapshot_and_subscribe(c.w, @box, self(), ref)
    assert_receive {:canonical_snapshot, ^ref, %{casts: casts}}, 5_000
    assert casts == %{}

    {actor, request} = request(c, @leaf_micro, program("lamp"), 1_000_000)
    seq0 = World.seq(c.w)
    before_us = MmoContracts.ServerTime.server_us()
    task = Task.async(fn -> World.spell_intent(c.w, actor, request) end)

    start_seq = seq0 + 1

    assert_receive {:canonical_delta,
                    %{transaction_seq: ^start_seq, transaction: %{casts: %{@cid => record}}}},
                   5_000

    assert record.live == 1
    assert record.program == request.program
    assert record.t0_us >= before_us and record.t0_us <= MmoContracts.ServerTime.server_us()
    {dx, dy, dz} = request.direction

    for {a, e} <-
          Enum.zip(Tuple.to_list(record.origin), [0.5 + 0.5 * dx, 2.5 + 0.5 * dy, 0.5 + 0.5 * dz]),
        do: assert_in_delta(a, e, 1.0e-12)

    expected =
      for s <- sample("lamp")["steps"], do: {s["part_index"], s["adjust_s"], s["inject_s"]}

    assert length(record.steps) == length(expected)

    for {step, {part, adjust, inject}} <- Enum.zip(record.steps, expected) do
      assert step.part_index == part
      assert_in_delta step.adjust_s, adjust, 1.0e-6
      assert_in_delta step.inject_s, inject, 1.0e-6
    end

    # 前摇 = Σ(调整 + 注能) + 出手前置（报价 windup_s）。
    assert_in_delta Enum.sum(Enum.map(record.steps, &(&1.adjust_s + &1.inject_s))) + 0.3,
                    sample("lamp")["windup_s"],
                    1.0e-5

    # 前摇中：观察快照与新订阅的完整快照都带这条记录；未扣能。
    assert observe(c.w).casts == %{@cid => record}
    ref2 = make_ref()
    :ok = World.canonical_snapshot_and_subscribe(c.w, @box, self(), ref2)
    assert_receive {:canonical_snapshot, ^ref2, %{casts: %{@cid => ^record}}}, 5_000
    assert Task.yield(task, 0) == nil

    # 余额 0 的灯在第 1 步余额不足：出手时结算第 1 步中断（扣 0），广播 outcome 1、fail_step 1。
    settle(c, request)

    assert {:ok, %{outcome: :interrupted_energy, seq: settled, caster: %{spent_j: +0.0}}} =
             Task.await(task, 10_000)

    assert_receive {:canonical_delta,
                    %{
                      transaction_seq: ^settled,
                      transaction: %{casts: %{@cid => %{live: 0, outcome: 1, fail_step: 1}}}
                    }},
                   5_000

    assert observe(c.w).casts == %{}
  end

  test "前摇中再施放：立即 cast_too_soon、不扣能、不提交；报价不受影响；结算后照常", c do
    balance = funded(c)
    {task, cast_request, record} = begin(c, @stone_micro, program("draw_1mj"), 2_000_000)
    seq = World.seq(c.w)

    # 入口时钟晚于间隔 500 ms（不是 GCRA 过快），仍因前摇中被拒；同一 World 进程立即回复，不等前摇结束。
    {actor, again} = request(c, @stone_micro, program("draw_1mj"), 9_000_000)
    assert {:error, :cast_too_soon} = World.spell_intent(c.w, actor, again)
    {actor, quote} = request(c, @stone_micro, program("draw_1mj"), 9_000_001, 0)
    assert {:ok, %{caster: q}} = World.spell_intent(c.w, actor, quote)
    assert_in_delta q.quote_j, sample("draw_1mj")["total_mj"] / 1000, 1.0e-9
    assert World.seq(c.w) == seq
    assert energy(c) == balance
    assert observe(c.w).casts == %{@cid => record}

    settle(c, cast_request)
    assert {:ok, %{outcome: nil, seq: settled}} = Task.await(task, 10_000)
    assert settled == seq + 1
    # 已结算的记录不再响应到期消息（旧授权稍后到达时忽略）。
    settle(c, cast_request)
    assert World.seq(c.w) == settled
  end

  test "结算时目标已失效：前摇中蓄能石被换成石 → stale_target、不扣能，广播 outcome 2", c do
    ref = make_ref()
    :ok = World.canonical_snapshot_and_subscribe(c.w, @box, self(), ref)
    assert_receive {:canonical_snapshot, ^ref, _}, 5_000
    {task, cast_request, _record} = begin(c, @stone_micro, program("draw_1mj"), 1_000_000)
    {:ok, _} = World.apply_edits(c.w, [{{2, 1, 0}, @stone}])
    seq = World.seq(c.w)

    settle(c, cast_request)
    assert {:error, :stale_target} = Task.await(task, 10_000)
    rejected = seq + 1
    assert World.seq(c.w) == rejected

    assert_receive {:canonical_delta,
                    %{
                      transaction_seq: ^rejected,
                      transaction: %{casts: %{@cid => %{live: 0, outcome: 2, fail_step: 0}}}
                    }},
                   5_000

    assert energy(c) == 0.0
    assert observe(c.w).casts == %{}
  end

  test "待施放不持久化：前摇中冷重启 → 记录丢失、未扣能；重启后可再施放", c do
    {actor, request} = request(c, @stone_micro, program("draw_1mj"), 1_000_000)

    # 调用方在独立进程里等待（World 停止时它随调用退出，不牵连测试进程）。
    spawn(fn -> World.spell_intent(c.w, actor, request) end)
    assert Enum.find_value(1..2_000, fn _ -> observe(c.w).casts[@cid] end)

    :ok = stop_supervised(:world)
    w = start(c.root)
    c = %{c | w: w}
    assert observe(w).casts == %{}
    assert energy(c) == 0.0
    :ok = VoxelRegion.TestSupport.activate_simulation(w, @simulation_box)
    {actor, request} = request(c, @stone_micro, program("draw_1mj"), 3_000_000)
    assert {:ok, %{outcome: nil}} = VoxelRegion.TestSupport.spell(w, actor, request)
    assert_in_delta energy(c), 900_000.0 - sample("draw_1mj")["total_mj"] / 1000, 1.0e-6
  end

  test "取消不扣能、不产生作用，旧授权无效且监视随动作退休", c do
    monitors = elem(Process.info(c.w, :monitors), 1)
    {task, request, _} = begin(c, @stone_micro, program("draw_1mj"), 1_000_000)
    key = {c.a.identity, request.client_intent_seq}
    send(c.w, {:cancel_cast, key, :cast_cancelled, 0})
    assert Task.await(task) == {:error, :cast_cancelled}
    seq = World.seq(c.w)
    assert energy(c) == 0.0
    assert observe(c.w).casts == %{}
    settle(c, request)
    assert World.seq(c.w) == seq
    assert elem(Process.info(c.w, :monitors), 1) == monitors
  end

  # W-7：施法读取闭包按目录 v5 的 `limits.range_m` 装射程区域。若闭包仍按 v4 扁平 `range_m` 匹配，会静默返回“不读页”，
  # 冷页不装、射线在缺页处当空气。
  test "W-7 冷页上施放：前摇准备先按射程装页（含 x = -2 的冷页），再开始前摇", c do
    {actor, request} = request(c, @stone_micro, program("draw_1mj"), 1_000_000)
    actor = snapshot(c, actor)
    :ok = World.compact(c.w)
    :ok = stop_supervised(:world)
    w = start(c.root)

    # 启动只装活动页（蓄能石所在页及其邻页 {-1..1}³）；施法闭包（眼周射程区域再扩邻页）伸到 x = -2 的冷页。
    refute VoxelRegion.World.Pages.resident?(:sys.get_state(w), {0, {-2, 0, 0}})

    key = {actor.identity, request.client_intent_seq}
    ref = make_ref()
    send(w, {:prepare_cast, key, Map.put(actor, :player, self()), request, {self(), ref}})
    assert_receive {:cast_prepared, ^key, %{windup_s: windup, checkpoint_s: nil}}, 10_000
    assert_in_delta windup, sample("draw_1mj")["windup_s"], 1.0e-6
    assert VoxelRegion.World.Pages.resident?(:sys.get_state(w), {0, {-2, 0, 0}})
    send(w, {:cancel_cast, key, :cast_cancelled, 0})
    assert_receive {^ref, {:error, :cast_cancelled}}, 5_000
  end

  # M2b 按需装页：Player 发来的前摇准备 `prepare_cast` 被挂起装页时，同一动作的取消必须排在它后面——先处理取消会落空，
  # 准备随后建起永远等不到授权的待施放。期望（取消不扣能、调用方收到 cast_cancelled、不留待施放）同上面的取消用例。
  test "冷页上前摇准备被挂起装页时，同一动作的取消排在其后：调用方收到取消，不留待施放", c do
    {actor, request} = request(c, @stone_micro, program("draw_1mj"), 1_000_000)
    actor = snapshot(c, actor)
    :ok = World.compact(c.w)
    :ok = stop_supervised(:world)
    w = start(c.root)
    refute VoxelRegion.World.Pages.resident?(:sys.get_state(w), {0, {-2, 0, 0}})

    key = {actor.identity, request.client_intent_seq}
    ref = make_ref()
    send(w, {:prepare_cast, key, actor, request, {self(), ref}})
    send(w, {:cancel_cast, key, :cast_cancelled, 0})
    assert_receive {^ref, {:error, :cast_cancelled}}, 10_000
    assert :sys.get_state(w).pending_casts == %{}
    assert energy(%{c | w: w}) == 0.0
  end

  # 评审 A5 / F3：挂起的施法准备装页失败时，按原业务收尾——调用方收到错误、Player 收到 cast_failed（清掉 :preparing），
  # 同序队列释放；不能只记日志丢弃，让调用方等满超时。
  test "冷页上前摇准备装页失败：调用方收到错误、Player 收到 cast_failed，同序队列释放", c do
    {actor, request} = request(c, @stone_micro, program("draw_1mj"), 1_000_000)
    actor = snapshot(c, actor)
    :ok = World.compact(c.w)
    :ok = stop_supervised(:world)
    w = start(c.root, FailLog)
    on_exit(fn -> FailLog.disarm() end)
    refute VoxelRegion.World.Pages.resident?(:sys.get_state(w), {0, {-2, 0, 0}})
    FailLog.arm()

    key = {actor.identity, request.client_intent_seq}
    ref = make_ref()
    send(w, {:prepare_cast, key, Map.put(actor, :player, self()), request, {self(), ref}})
    assert_receive {^ref, {:error, {:page_load_failed, _}}}, 10_000
    assert_receive {:cast_failed, ^key}, 1_000
    s = :sys.get_state(w)
    assert s.pending_casts == %{} and s.page_load.held == %{}
  end
end
