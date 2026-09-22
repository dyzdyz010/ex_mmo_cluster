defmodule GateServer.NpcSkillBrainTest do
  @moduledoc "只测试：主脑等待技能的一个结果；中断由独立 Jev 请求裁决，手排 Body 事件。"
  use ExUnit.Case, async: false
  alias GateServer.Npc.Brain.Llm

  defmodule Memory do
    def recent(_, _), do: []
    def recent_notes(_,_),do: []
    def search(_,_,_),do: []
    def journal(cid, text, position) do
      send(Process.whereis(__MODULE__),{:journal,cid,text,position})
      :ok
    end
  end

  setup do
    Process.register(self(),Memory)
    :ok
  end

  # 只测试：在技能自身调用的持久化接口内冻结退出，控制最后一个Body命令的先后。
  defmodule ExitGate do
    use Agent
    def start_link(owner),do: Agent.start_link(fn -> %{owner: owner,body: nil} end,name: __MODULE__)
    def body(body),do: Agent.update(__MODULE__,&%{&1 | body: body})
    def recent(_,_),do: []
    def recent_notes(_,_),do: []
    def search(_,_,_),do: []
    def journal(_,_,_),do: :ok
    def get(_,_,_) do
      %{owner: owner,body: body}=Agent.get(__MODULE__,& &1)
      Process.flag(:trap_exit,true)
      send(owner,{:trapping_worker,self()})
      receive do {:EXIT,_,:shutdown} -> send(owner,{:shutdown_received,self()}) end
      receive do :finish_shutdown -> :ok end
      GateServer.Npc.Body.command(body,%{id: {:skill,1,991},verb: :move_to,position: {5,6},tolerance: 0.5})
      exit(:shutdown)
    end
  end

  defmodule Body do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, Map.put(opts,:brain,Llm.init(opts.profile))}
    def handle_call(:brain, _, s), do: {:reply,s.brain,s}
    def handle_call(:skill_context, {worker, _}, s) do
      send(s.owner, {:skill_worker, worker})
      {:reply,{:ok,%{actor: %{cid: 7},world: :world,scene: :scene}},s}
    end
    def handle_cast({:command, c}, s) do
      send(s.owner,{:command,c})
      {:noreply,s}
    end
    def handle_cast({:event, event},s) do
      Llm.handle_event(event,s.brain)
      {:noreply,s}
    end
  end

  defp call(name,args), do: %{"output"=>[%{"type"=>"function_call","name"=>name,"call_id"=>"one","arguments"=>Jason.encode!(args)}]}
  defp observation, do: %{self: %{entity_id: 7,position: {1.0,2.0,3.0},tick: 1,grounded: true},pending: [],entities: [],balances: nil}
  defp profile(request) do
    %{goal: "放下已有定义",tools: %{1=>"镐"},memory: Memory,endpoint: %{model: "llm"},request: request,
      scheduler: %{model: "jev"},continue_activity: "continue_task",skills: %{build: %{}},
      activities: %{instructions: "Choose whether the current task should continue.",
        activities: %{"continue_task"=>"No interruption is needed.","stop_task"=>"A player needs attention now."}}}
  end

  test "a long tool suppresses repeated LLM requests and exposes exactly its final World outcome" do
    owner = self()
    request = fn _endpoint, request ->
      input = Jason.decode!(request.input)
      send(owner,{:asked,input})
      if input["outcomes"]==[],
        do: {:ok,call("build",%{definition: String.duplicate("11",32),anchor_micro: [8,8,8],orientation: 0})},
        else: {:ok,call("wait",%{seconds: 300})}
    end
    body = start_supervised!({Body,%{owner: owner,profile: profile(request)}})
    GenServer.cast(body,{:event,{:observation,observation()}})
    assert_receive {:asked,%{"outcomes"=>[]}}
    assert_receive {:command,%{id: {:skill,1,1},verb: :prefab_place}}
    GenServer.cast(body,{:event,{:observation,observation()}})
    refute_receive {:asked,_},1_200
    GenServer.cast(body,{:event,{:outcome,%{id: {:skill,1,1},verb: :prefab_place,status: :done,reason: nil,data: %{seq: 41}}}})
    assert_receive {:asked,%{"outcomes"=>[%{"verb"=>"build","status"=>"done","data"=>%{"seq"=>41},
      "command"=>%{"tool"=>"build"}}]}},2_000
    assert_receive {:journal,7,text,{1.0,2.0,3.0}}
    assert text =~ "status=done" and text =~ "anchor_micro" and text =~ "seq: 41"
  end

  test "Jev can interrupt while the skill is waiting; stopping Body precedes the final interrupted outcome" do
    owner = self()
    request = fn
      %{model: "jev"}, request ->
        send(owner,{:jev,request})
        {:ok,%{"answers"=>%{"activity"=>%{"choice"=>"stop_task","confidence"=>1.0}}}}
      %{model: "llm"}, request ->
        input = Jason.decode!(request.input)
        send(owner,{:asked,input})
        if input["outcomes"]==[],
          do: {:ok,call("build",%{definition: String.duplicate("11",32),anchor_micro: [8,8,8],orientation: 0})},
          else: {:ok,call("wait",%{seconds: 300})}
    end
    body = start_supervised!({Body,%{owner: owner,profile: profile(request)}})
    brain = GenServer.call(body,:brain)
    GenServer.cast(body,{:event,{:observation,observation()}})
    assert_receive {:asked,_}
    assert_receive {:command,%{id: {:skill,1,1}}}
    send(brain,{:skill_check,1})
    assert_receive {:jev,jev}
    refute String.contains?(jev.state,"放下")
    assert jev.questions.activity.criteria == profile(request).activities.activities
    assert_receive {:command,%{id: {:skill,1,:stop},verb: :stop}}
    refute_receive {:asked,_},1_200
    GenServer.cast(body,{:event,{:outcome,%{id: {:skill,1,:stop},verb: :stop,status: :done,reason: nil,data: %{}}}})
    assert_receive {:asked,%{"outcomes"=>[%{"verb"=>"build","status"=>"rejected","reason"=>["interrupted","stop_task"],
      "data"=>%{"metrics"=>%{"request_count"=>nil,"jev_request_count"=>nil,"parent_jev_request_count"=>1}}}]}},2_000
  end

  test "stopping Body also terminates its brain and waiting skill worker" do
    request = fn _, _ ->
      {:ok,call("build",%{definition: String.duplicate("11",32),anchor_micro: [8,8,8],orientation: 0})}
    end
    body = start_supervised!({Body,%{owner: self(),profile: profile(request)}})
    brain = GenServer.call(body,:brain)
    GenServer.cast(body,{:event,{:observation,observation()}})
    assert_receive {:skill_worker,worker}
    assert_receive {:command,%{id: {:skill,1,1}}}
    brain_ref = Process.monitor(brain)
    worker_ref = Process.monitor(worker)
    GenServer.stop(body, :normal)
    assert_receive {:DOWN,^brain_ref,:process,^brain,:shutdown}
    assert_receive {:DOWN,^worker_ref,:process,^worker,:shutdown}
  end

  test "interruption waits for worker DOWN before issuing stop after its last Body command" do
    owner=self()
    request=fn
      %{model: "jev"},_ -> {:ok,%{"answers"=>%{"activity"=>%{"choice"=>"stop_task","confidence"=>1.0}}}}
      %{model: "llm"},request ->
        input=Jason.decode!(request.input)
        send(owner,{:asked,input})
        if input["outcomes"]==[],do: {:ok,call("wilderness",%{goal: "Build a path",tool_id: 1})},
          else: {:ok,call("wait",%{seconds: 300})}
    end
    start_supervised!({ExitGate,owner})
    configured=%{profile(request) | memory: ExitGate,skills: %{wilderness: %{}}}
    body=start_supervised!({Body,%{owner: owner,profile: configured}})
    :ok=ExitGate.body(body)
    brain=GenServer.call(body,:brain)
    GenServer.cast(body,{:event,{:observation,observation()}})
    assert_receive {:asked,_}
    assert_receive {:trapping_worker,worker}
    on_exit(fn -> Process.exit(worker,:kill) end)
    send(brain,{:skill_check,1})
    assert_receive {:shutdown_received,^worker}
    refute_receive {:command,%{verb: :stop}},150
    send(worker,:finish_shutdown)
    assert_receive {:command,first}
    assert first.id=={:skill,1,991} and first.verb==:move_to
    assert_receive {:command,%{id: {:skill,1,:stop},verb: :stop}}
    GenServer.cast(body,{:event,{:outcome,%{id: {:skill,1,:stop},verb: :stop,status: :done,reason: nil,data: %{}}}})
    {:ok,timer}=:timer.send_interval(50,brain,{:observation,observation()})
    on_exit(fn -> :timer.cancel(timer) end)
    assert_receive {:asked,%{"outcomes"=>[%{"verb"=>"wilderness","reason"=>["interrupted","stop_task"]}]}},2_000
  end

  test "a superseded stop reports stop_failed rather than claiming the interruption stopped Body" do
    owner=self()
    request=fn
      %{model: "jev"},_ -> {:ok,%{"answers"=>%{"activity"=>%{"choice"=>"stop_task","confidence"=>1.0}}}}
      %{model: "llm"},request ->
        input=Jason.decode!(request.input)
        send(owner,{:asked,input})
        if input["outcomes"]==[],do: {:ok,call("build",%{definition: String.duplicate("11",32),anchor_micro: [8,8,8],orientation: 0})},
          else: {:ok,call("wait",%{seconds: 300})}
    end
    body=start_supervised!({Body,%{owner: owner,profile: profile(request)}})
    brain=GenServer.call(body,:brain)
    GenServer.cast(body,{:event,{:observation,observation()}})
    assert_receive {:asked,_}
    assert_receive {:command,%{id: {:skill,1,1}}}
    send(brain,{:skill_check,1})
    assert_receive {:command,%{id: {:skill,1,:stop},verb: :stop}}
    GenServer.cast(body,{:event,{:outcome,%{id: {:skill,1,:stop},verb: :stop,status: :superseded,reason: nil,data: nil}}})
    {:ok,timer}=:timer.send_interval(50,brain,{:observation,observation()})
    on_exit(fn -> :timer.cancel(timer) end)
    assert_receive {:asked,%{"outcomes"=>[%{"verb"=>"build","status"=>"rejected","reason"=>["stop_failed","superseded",nil]}]}},2_000
    refute_receive {:command,%{verb: :stop}},100
  end

  test "a crashed worker reports unknown child metrics and the known parent Jev count" do
    owner=self()
    request=fn _,request ->
      input=Jason.decode!(request.input)
      send(owner,{:asked,input})
      if input["outcomes"]==[],do: {:ok,call("build",%{definition: String.duplicate("11",32),anchor_micro: [8,8,8],orientation: 0})},
        else: {:ok,call("wait",%{seconds: 300})}
    end
    body=start_supervised!({Body,%{owner: owner,profile: profile(request)}})
    brain=GenServer.call(body,:brain)
    GenServer.cast(body,{:event,{:observation,observation()}})
    assert_receive {:asked,_}
    assert_receive {:skill_worker,worker}
    assert_receive {:command,%{id: {:skill,1,1}}}
    Process.exit(worker,:kill)
    {:ok,timer}=:timer.send_interval(50,brain,{:observation,observation()})
    on_exit(fn -> :timer.cancel(timer) end)
    assert_receive {:asked,%{"outcomes"=>[%{"reason"=>["skill_failed","killed"],
      "data"=>%{"metrics"=>%{"request_count"=>nil,"jev_request_count"=>nil,"parent_jev_request_count"=>0}}}]}},2_000
    assert_receive {:journal,7,text,_}
    assert text =~ "status=rejected" and text =~ "skill_failed" and text =~ "killed"
  end
end
