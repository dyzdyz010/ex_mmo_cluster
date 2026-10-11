defmodule SceneServer.Movement.DialogueSceneTest do
  use ExUnit.Case, async: false
  alias MmoContracts.{Session, Voxel}
  alias SceneServer.Movement.{Scene, Player}

  # 只测试：时钟、canonical输入和身体持久化依赖使用本次测试独占替身；Scene、Player和碰撞NIF为真实模块。
  defmodule Clock do
    def now(ref), do: :atomics.get(ref, 1)
    def schedule(_, _, _), do: :ok
  end

  defmodule Source do
    use GenServer
    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot)
    def init(snapshot), do: {:ok, snapshot}

    def canonical_snapshot_and_subscribe(pid, _, subscriber, ref, _),
      do: GenServer.call(pid, {:snapshot, subscriber, ref})

    def handle_call({:snapshot, subscriber, ref}, _, snapshot) do
      send(subscriber, {:canonical_snapshot, ref, snapshot})
      {:reply, :ok, snapshot}
    end
  end

  defp identity(epoch), do: %Session.Identity{session_epoch: epoch, scene_id: 1, scene_epoch: 7}

  defp request(identity, target \\ 0, conversation \\ 0),
    do: %Session.Say{
      identity: identity,
      request_id: 1,
      target_id: target,
      conversation_id: conversation,
      text: "你好，附近的朋友"
    }

  setup tags do
    profile =
      Path.expand("../../../../../../Voxim/Docs/M0/fixtures/suite.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("profile")
      |> Map.put("fixed_hz", 60)

    config = %{
      "schema" => "voxim-m1-demo-v1",
      "l0_min" => [-1, -1, -1],
      "l0_max_exclusive" => [1, 1, 1],
      "travel_min_m" => [-30.0, -30.0, -30.0],
      "travel_max_exclusive_m" => [30.0, 30.0, 30.0],
      "spawn_probes_m" => [[2.0, 10.0, 2.0], [3.0, 10.0, 2.0], [27.0, 10.0, 2.0]],
      "spawn_min_y_m" => -20.0,
      "profile" => profile
    }

    config =
      if tags[:transfer],
        do: %{
          config
          | "travel_max_exclusive_m" => [3.0, 30.0, 30.0],
            "spawn_probes_m" => [[2.0, 10.0, 2.0]]
        },
        else: config

    snapshot = %Voxel.CanonicalSnapshot{
      content_version: 9,
      transaction_seq: 0,
      l0_min: {-1, -1, -1},
      l0_max_exclusive: {1, 1, 1},
      chunks:
        for(
          x <- 0..1,
          do: %Voxel.ChunkOccupancy{
            coord: {x, 0, 0},
            n: 16,
            scale_m: 1.0,
            origin_m: {x * 16.0, 0.0, 0.0},
            cells:
              for(
                _z <- 0..15,
                y <- 0..15,
                _x <- 0..15,
                into: <<>>,
                do: <<if(y == 0, do: 1, else: 0)>>
              )
          }
        ),
      regions: for(x <- -1..0, y <- -1..0, z <- -1..0, do: {{x, y, z}, <<>>})
    }

    clock = :atomics.new(1, signed: true)
    source = start_supervised!({Source, snapshot})
    store = start_supervised!({MmoTest.BodyStore, []})

    scene =
      start_supervised!(
        {Scene,
         [
           scene_id: 1,
           scene_epoch: 7,
           world_ref: source,
           world_api: Source,
           config: config,
           clock: {Clock, clock},
           body_store: {MmoTest.BodyStore, store: store}
         ]}
      )

    await(fn -> Scene.observe(scene).initialized end)
    %{scene: scene, clock: clock, config: config, source: source, store: store}
  end

  test "真实join与Ready经唯一Scene广播，离场重连不重放旧身份", ctx do
    a = identity(1)
    b = identity(2)
    far = identity(3)
    {pa, sa} = join(ctx, a, 10, "玩家甲", "player")
    assert {:error, :not_ready} = Scene.say(ctx.scene, a, request(a))
    ready(ctx, a, pa, sa)
    {pb, sb} = join(ctx, b, 20, "NPC乙", "npc")
    ready(ctx, b, pb, sb)
    {pf, sf} = join(ctx, far, 30, "远方玩家", "player")
    ready(ctx, far, pf, sf)

    assert {:error, :invalid_session} = Scene.say(ctx.scene, a, request(b))
    accepted_request = %{request(a, 20) | request_id: 2}
    assert {:ok, speech} = Scene.say(ctx.scene, a, accepted_request)
    assert speech.speaker_name == "玩家甲"
    assert speech.speaker_kind == 0
    assert speech.turn == 1
    conversation = speech.conversation_id
    assert conversation > 0

    assert_receive {:mmo_reliable, ^a, 1,
                    %Session.Speech{
                      identity: ^a,
                      conversation_id: ^conversation,
                      turn: 1,
                      speaker_id: 10,
                      target_id: 20
                    }}

    assert_receive {:mmo_reliable, ^b, 1,
                    %Session.Speech{
                      identity: ^b,
                      conversation_id: ^conversation,
                      turn: 1,
                      speaker_id: 10,
                      target_id: 20
                    }}

    refute_receive {:mmo_reliable, ^far, 1, %Session.Speech{}}, 20

    assert {:ok, ^speech} = Scene.say(ctx.scene, a, accepted_request)
    refute_receive {:mmo_reliable, _, 1, %Session.Speech{}}, 20

    assert {:ok, %{turn: 2, speaker_kind: 1, speaker_name: "NPC乙"}} =
             Scene.say(ctx.scene, b, request(b, 10, conversation))

    assert_receive {:mmo_reliable, ^a, 1, %Session.Speech{turn: 2}}
    assert_receive {:mmo_reliable, ^b, 1, %Session.Speech{turn: 2}}

    :ok = Scene.leave(ctx.scene, b)
    assert {:error, :invalid_session} = Scene.say(ctx.scene, b, request(b, 10, conversation))
    next = identity(4)
    {pn, sn} = join(ctx, next, 20, "NPC乙", "npc")
    ready(ctx, next, pn, sn)

    assert {:error, :conversation_forbidden} =
             Scene.say(ctx.scene, next, request(next, 10, conversation))

    assert Scene.observe(ctx.scene).dialogue.accepted == 2
  end

  test "没有后续发言时，Scene自有到期消息退休会话", ctx do
    who = identity(1)
    {player, start} = join(ctx, who, 10, "玩家甲", "player")
    ready(ctx, who, player, start)
    assert {:ok, _} = Scene.say(ctx.scene, who, request(who))
    assert Scene.observe(ctx.scene).dialogue.active_conversations == 1

    # 只测试：读取实际已安装的计时器并提前交付其到期信号；不回填任何权威角色或对话状态。
    {timer, deadline} = :sys.get_state(ctx.scene).dialogue_timer
    assert is_integer(Process.read_timer(timer))
    :atomics.add_get(ctx.clock, 1, 2_000_000)
    assert {:ok, _} = Scene.say(ctx.scene, who, %{request(who) | request_id: 2})
    {next_timer, next_deadline} = :sys.get_state(ctx.scene).dialogue_timer
    :atomics.put(ctx.clock, 1, deadline * 1000)
    send(ctx.scene, {:timeout, timer, :dialogue_expire})
    assert Scene.observe(ctx.scene).dialogue.active_conversations == 2
    :atomics.put(ctx.clock, 1, next_deadline * 1000)
    send(ctx.scene, {:timeout, next_timer, :dialogue_expire})
    assert Scene.observe(ctx.scene).dialogue.active_conversations == 1
    {last_timer, last_deadline} = :sys.get_state(ctx.scene).dialogue_timer
    :atomics.put(ctx.clock, 1, last_deadline * 1000)
    send(ctx.scene, {:timeout, last_timer, :dialogue_expire})
    assert Scene.observe(ctx.scene).dialogue.active_conversations == 0
    assert Scene.observe(ctx.scene).dialogue.accepted == 2
  end

  @tag :transfer
  test "真实移动触发移交后，缓存权威观察明确拒绝新发言", ctx do
    config = %{
      ctx.config
      | "travel_min_m" => [3.0, -30.0, -30.0],
        "travel_max_exclusive_m" => [30.0, 30.0, 30.0],
        "spawn_probes_m" => [[5.0, 10.0, 2.0]]
    }

    other =
      start_supervised!(
        Supervisor.child_spec(
          {Scene,
           [
             scene_id: 2,
             scene_epoch: 7,
             world_ref: ctx.source,
             world_api: Source,
             config: config,
             clock: {Clock, ctx.clock},
             body_store: {MmoTest.BodyStore, store: ctx.store}
           ]},
          id: :other_scene
        )
      )

    await(fn -> Scene.observe(other).initialized end)
    {:ok, endpoint} = Scene.neighbour_endpoint(other)
    :ok = Scene.connect_neighbour(ctx.scene, endpoint.pid, 0, endpoint)
    who = identity(1)
    {player, start} = join(ctx, who, 10, "移动玩家", "player")
    ready(ctx, who, player, start)
    info = Player.observe(player)
    for _ <- (Scene.observe(ctx.scene).tick + 1)..(info.origin_tick - 1), do: tick(ctx)

    frames =
      for seq <- 1..60,
          do: %MmoContracts.Movement.InputFrame{
            input_seq: seq,
            axis_x: 32767,
            axis_z: 0,
            yaw: 0,
            jump_pressed: 0
          }

    for batch <- Enum.chunk_every(frames, 6),
        do:
          Player.input(player, who, %MmoContracts.Movement.InputBatch{
            identity: who,
            frames: batch
          })

    Player.observe(player)
    for _ <- 1..60, do: tick(ctx)
    assert_receive {:mmo_transfer_request, ^who, ^player, 2}, 2000

    await(fn ->
      Enum.any?(
        Scene.observe(ctx.scene).characters,
        &(&1.identity == who and not &1.dialogue_available)
      )
    end)

    assert {:error, :not_ready} = Scene.say(ctx.scene, who, request(who))
    assert Scene.observe(ctx.scene).dialogue.accepted == 0
  end

  test "两个玩家并发叫同一NPC，全部听众得到相同序号与归属", ctx do
    a = identity(1)
    b = identity(2)
    npc = identity(3)

    for {who, id, name, kind, spawn} <- [
          {a, 10, "玩家甲", "player", nil},
          {b, 20, "玩家乙", "player", nil},
          {npc, 30, "NPC丙", "npc", {4.0, 10.0, 2.0}}
        ] do
      {player, start} = join(ctx, who, id, name, kind, spawn)
      ready(ctx, who, player, start)
    end

    assert {:ok, %{conversation_id: conversation}} = Scene.say(ctx.scene, npc, request(npc))
    for who <- [a, b, npc], do: assert_receive({:mmo_reliable, ^who, 1, %Session.Speech{turn: 1}})

    tasks =
      for who <- [a, b],
          do: Task.async(fn -> Scene.say(ctx.scene, who, request(who, 30, conversation)) end)

    speeches =
      for task <- tasks,
          do:
            (
              assert {:ok, speech} = Task.await(task)
              speech
            )

    assert Enum.sort(Enum.map(speeches, & &1.turn)) == [2, 3]
    assert Enum.sort(Enum.map(speeches, & &1.speaker_id)) == [10, 20]

    for expected <- Enum.sort_by(speeches, & &1.turn), who <- [a, b, npc] do
      assert_receive {:mmo_reliable, ^who, 1, %Session.Speech{} = received}
      assert Map.delete(Map.from_struct(received), :identity) == expected
    end
  end

  defp join(ctx, who, id, name, kind, spawn \\ nil) do
    profile = %{MmoContracts.Relation.blank() | name: name}

    {:ok, player} =
      Scene.join(ctx.scene, who, %{id: id, kind: kind, profile: profile, spawn: spawn}, self())

    await(fn -> Scene.observe(ctx.scene).queue_length > 0 end)
    tick(ctx)
    assert_receive {:mmo_reliable, ^who, 1, %Session.SessionStart{} = start}, 2000
    {player, start}
  end

  defp ready(ctx, who, player, start) do
    Player.time_probe(player, who, %Session.TimeProbe{request_id: 1, client_send_us: 0})
    Player.ready(player, who, start.baseline_transaction_seq, start.collision_revision)
    Player.observe(player)
    tick(ctx)

    await(fn ->
      Enum.any?(
        Scene.observe(ctx.scene).characters,
        &(&1.identity == who and Map.get(&1, :dialogue_available, false))
      )
    end)
  end

  defp tick(ctx) do
    target = Scene.observe(ctx.scene).tick + 1
    :atomics.put(ctx.clock, 1, div(target * 1_000_000 + 59, 60))
    send(ctx.scene, :tick)
    await(fn -> Scene.observe(ctx.scene).tick == target end)
  end

  defp await(predicate, attempts \\ 1000) do
    if predicate.() do
      :ok
    else
      assert attempts > 0
      Process.sleep(1)
      await(predicate, attempts - 1)
    end
  end
end
