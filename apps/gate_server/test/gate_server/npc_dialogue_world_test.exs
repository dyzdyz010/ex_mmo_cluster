Code.require_file("../support/npc_world.exs", __DIR__)

defmodule GateServer.NpcDialogueWorldTest do
  @moduledoc "只测试：真实 Scene/Body/Runtime/Life 与独占 PostgreSQL；Hindsight 替身控制批写，使用公共 say 与 claim/Ready。"
  use ExUnit.Case, async: false
  alias GateServer.Npc.{Body, Life, Memory}
  alias GateServer.NpcWorld

  defmodule Spy do
    def init(profile), do: profile

    def handle_event(event, profile) do
      if elem(event, 0) != :observation, do: send(profile.owner, {:brain, profile.cid, event})
      {[], profile}
    end
  end

  defmodule Hindsight do
    def ensure(_, _), do: {:ok, %{}}
    def models(_), do: {:ok, %{models: %{"self" => "a resident"}, metadata: %{}}}
    def refresh(config), do: models(config)
    def status(_), do: {:ok, %{stats: %{}, usage: %{}}}

    def retain(config, fragments) do
      send(config.owner, {:retain, self(), fragments})

      receive do
        :complete -> {:ok, %{retained: length(fragments)}}
        :fail -> {:error, :service_failed}
      end
    end
  end

  defmodule MissingSpeechReply do
    @moduledoc "只测试：真实 Scene 先接纳发言，传输替身随后扣住回复，让 GenServer.call 真实超时。"
    use GenServer
    alias SceneServer.Movement.Scene
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    def init(opts), do: {:ok, opts}
    defdelegate join(scene, identity, character, gate), to: Scene
    defdelegate leave(scene, identity, reason), to: Scene

    def say(scene, identity, request),
      do: GenServer.call(__MODULE__, {:say, scene, identity, request}, 100)

    def handle_call({:say, scene, identity, request}, _from, opts) do
      {:ok, speech} = Scene.say(scene, identity, request)
      if opts.leave, do: :ok = Scene.leave(scene, identity, 1)
      send(opts.owner, {:accepted_before_timeout, speech})
      {:noreply, opts}
    end
  end

  setup_all do
    MmoTest.Database.start!()
    :ok
  end

  for leave <- [false, true] do
    @leave leave
    @tag :delivery_unknown
    test "accepted speech with a lost reply is unknown and keeps Body alive; player left=#{leave}" do
      fixture = NpcWorld.start()
      cid = System.unique_integer([:positive]) + 500_000
      start_supervised!({MissingSpeechReply, %{owner: self(), leave: @leave}})

      body =
        start_supervised!(
          {Body,
           [
             cid: cid,
             scene_id: 1,
             spawn: {4.0, 66.0, 10.0},
             claims: fixture.claims,
             route_module: NpcWorld.Route,
             scene_module: MissingSpeechReply,
             brain: {Spy, %{owner: self(), cid: cid}}
           ]}
        )

      NpcWorld.await(fn -> Body.observe(body).position != nil end)
      monitor = Process.monitor(body)

      Body.command(body, %{
        id: :lost_reply,
        verb: :say,
        text: "这句话已经发生",
        target_id: 0,
        conversation_id: 0
      })

      assert_receive {:accepted_before_timeout, speech}, 2000

      assert_receive {:brain, ^cid,
                      {:outcome, %{id: :lost_reply, status: :rejected, reason: :delivery_unknown}}},
                     2000

      refute_received {:DOWN, ^monitor, :process, ^body, _}
      assert Process.alive?(body)
      assert [received] = Body.observe(body).dialogue
      assert {received.conversation_id, received.turn} == {speech.conversation_id, speech.turn}
      assert [%{id: :lost_reply, reason: :delivery_unknown}] = Body.observe(body).outcomes
      refute_receive {:accepted_before_timeout, _}, 150
    end
  end

  test "Routine bodies receive real Speech and own echo without crashing or restarting" do
    fixture = NpcWorld.start()
    cid = System.unique_integer([:positive]) + 400_000

    %{body: body, sup: sup} =
      NpcWorld.body(fixture, {GateServer.Npc.Brain.Routine, %{steps: []}}, cid: cid)

    {:ok, other} =
      DynamicSupervisor.start_child(
        sup,
        {Body,
         [
           cid: cid + 1,
           scene_id: 1,
           spawn: {6.0, 66.0, 10.0},
           claims: fixture.claims,
           route_module: NpcWorld.Route,
           brain: {GateServer.Npc.Brain.Routine, %{steps: []}}
         ]}
      )

    NpcWorld.await(fn ->
      Body.observe(body).position != nil and Body.observe(other).position != nil
    end)

    ref = Process.monitor(other)

    Body.command(body, %{
      id: :greeting,
      verb: :say,
      text: "早上好",
      target_id: cid + 1,
      conversation_id: 0
    })

    refute_receive {:DOWN, ^ref, :process, ^other, _}, 300
    assert Process.alive?(body) and Process.alive?(other)
    NpcWorld.await(fn -> length(Body.observe(other).dialogue) == 1 end)
    assert [%{speaker_id: ^cid}] = Body.observe(body).dialogue
    assert Enum.any?(Body.observe(body).outcomes, &match?(%{id: :greeting, status: :done}, &1))
  end

  test "Body says through Scene; accepted echoes persist, failed requests do not, restart preserves source and cursor" do
    fixture = NpcWorld.start()
    cid = System.unique_integer([:positive]) + 300_000
    peer = cid + 1

    profile = %{
      owner: self(),
      cid: cid,
      life: %{hindsight: Hindsight, owner: self(), poll_ms: 30, url: "http://memory.test.invalid"}
    }

    %{body: body, sup: sup} = NpcWorld.body(fixture, {Spy, profile}, cid: cid)

    {:ok, other} =
      DynamicSupervisor.start_child(
        sup,
        {Body,
         [
           cid: peer,
           scene_id: 1,
           spawn: {6.0, 66.0, 10.0},
           claims: fixture.claims,
           route_module: NpcWorld.Route,
           brain: {Spy, %{owner: self(), cid: peer}}
         ]}
      )

    NpcWorld.await(fn ->
      Body.observe(body).position != nil and Body.observe(other).position != nil
    end)

    NpcWorld.await(fn -> match?({:ok, %{cache: %{} = _}}, Life.observe(cid)) end)
    {:ok, before} = Life.observe(cid)

    Body.command(body, %{
      id: {:hello, make_ref()},
      verb: :say,
      text: "我声称房子已经修好",
      target_id: peer,
      conversation_id: 0
    })

    assert_receive {:brain, ^cid, {:outcome, %{verb: :say, status: :done, data: speech}}}, 5000
    assert speech.speaker_id == cid and speech.target_id == peer
    assert_receive {:brain, ^peer, {:heard, heard}}, 5000
    assert heard.conversation_id == speech.conversation_id and heard.turn == speech.turn
    refute_receive {:brain, ^cid, {:heard, _}}, 50
    NpcWorld.await(fn -> match?({:ok, %{pending_episodes: 1}}, Life.observe(cid)) end)
    assert [own] = Body.observe(body).dialogue
    assert own.text == "我声称房子已经修好"

    Body.command(body, %{
      id: :too_soon,
      verb: :say,
      text: "不应留下",
      target_id: peer,
      conversation_id: speech.conversation_id
    })

    assert_receive {:brain, ^cid,
                    {:outcome, %{id: :too_soon, status: :rejected, reason: :rate_limited}}},
                   5000

    {:ok, after_speech} = Life.observe(cid)
    assert after_speech.state == before.state
    assert after_speech.pending_episodes == 1

    assert {:ok, %{status: :started}} = Life.flush(cid)
    assert_receive {:retain, worker, [fragment]}, 5000
    assert fragment["text"] =~ "I said"
    assert fragment["text"] =~ "not verified world facts"
    assert fragment["id"] =~ "speech:#{speech.conversation_id}:#{speech.turn}"
    refute fragment["id"] =~ "fragment:0-0"

    Body.command(other, %{
      id: :reply,
      verb: :say,
      text: "我只是听到了这项声明",
      target_id: cid,
      conversation_id: speech.conversation_id
    })

    assert_receive {:brain, ^peer, {:outcome, %{id: :reply, status: :done}}}, 5000
    assert_receive {:brain, ^cid, {:heard, %{turn: 2}}}, 5000

    NpcWorld.await(fn ->
      match?({:ok, %{pending_episodes: 1, pending_fragments: 1}}, Life.observe(cid))
    end)

    send(worker, :fail)
    NpcWorld.await(fn -> match?({:ok, %{error: :service_failed}}, Life.observe(cid)) end)

    # 真正关闭并重建 Body/Runtime/Life，保留同一持久 cid；失败 outbox 必须仍在。
    :ok = DynamicSupervisor.terminate_child(sup, body)

    {:ok, restored} =
      DynamicSupervisor.start_child(
        sup,
        {Body,
         [
           cid: cid,
           scene_id: 1,
           spawn: {4.0, 66.0, 10.0},
           claims: fixture.claims,
           route_module: NpcWorld.Route,
           brain: {Spy, profile}
         ]}
      )

    assert_receive {:retain, retry, [^fragment]}, 5000
    send(retry, :complete)

    NpcWorld.await(fn ->
      match?({:ok, %{retained: 1, pending_fragments: 0}}, Life.observe(cid))
    end)

    {:ok, recovered} = Life.observe(cid)
    assert recovered.state == before.state
    assert recovered.pending_episodes == 1
    assert Process.alive?(restored)
    assert {:ok, stored} = Memory.life_load(DataService.NpcMemory, cid)
    assert [episode] = stored["pending"]
    assert episode["id"] == "speech:#{speech.conversation_id}:2"
    assert episode["speech"]["speaker_id"] == peer
    assert episode["text"] =~ "I heard"
  end
end
