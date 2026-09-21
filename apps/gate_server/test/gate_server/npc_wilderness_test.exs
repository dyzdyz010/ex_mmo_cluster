defmodule GateServer.NpcWildernessTest do
  @moduledoc "只测试：手排 Body 事件，快照替身仅验证技能终态读取边界；真实 World 另有集成用例。"
  use ExUnit.Case, async: true
  alias GateServer.Npc.Brain.Builder
  alias GateServer.Npc.Skills.Wilderness

  @ops [%{"op" => "fill", "min" => [0, 0, 0], "max" => [1, 0, 0], "material" => 11}]
  @observation %{self: %{position: {5.0, 0.9, 5.0}}, balances: nil}

  defmodule Memory do
    def get(_, _, _), do: Process.get(:plan)
    def put(_, _, _, plan), do: Process.put(:plan, plan)
    def delete(_, _, _), do: Process.delete(:plan)
    def journal(_, text, _), do: send(Process.get(:test), {:journal, text})
  end

  defmodule Snapshot do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}
    def handle_call({:prepare, _}, _, state), do: {:reply, {nil, nil, []}, state}
    def handle_call({:adopt_liquid, _}, _, state), do: {:reply, :ok, state}
    def handle_call({:material_snapshot, [91], cells}, _, {test, materials} = state) do
      send(test, {:authority_read, Enum.sort(cells)})
      {:reply, %{probe_occupancy: for({x,y,z} = cell <- cells,
        do: %{cell: [x,y,z], material: Map.fetch!(materials, cell)})}, state}
    end
  end

  defp start_run(opts \\ []) do
    test = self()
    world = start_supervised!({Snapshot, {test, Keyword.get(opts, :world, %{{0,0,0} => 11, {1,0,0} => 11})}})
    request = Keyword.get(opts, :request) || fn _, body ->
      if is_map_key(body, :questions) do
        send(test, :jev_request)
        {:ok, %{"answers" => %{"activity" => %{"choice" => "fetch_material", "confidence" => 0.99}}}}
      else
        send(test, :planner_request)
        {:ok, %{"output" => [%{"type" => "function_call", "name" => "submit_blueprint",
          "arguments" => Jason.encode!(%{ops: @ops})}]}}
      end
    end
    profile = %{cid: 91, tool_id: 1, memory: Memory, planner: %{model: "m"}, scheduler: %{model: "j"},
      activities: Builder.activity_profile()}
    Task.async(fn ->
      Process.put(:test, test)
      Process.put(:plan, Keyword.get(opts, :remembered))
      result = Wilderness.run(%{body: test, call_id: "call-77", profile: profile, request: request,
        observation: @observation, world: world}, Keyword.get(opts, :args, %{goal: "two stones", ops: @ops}))
      {result, Process.get(:plan)}
    end)
  end

  defp reply(task, id, verb, data \\ nil, reason \\ nil) do
    assert_receive {:"$gen_cast", {:command, %{id: {:skill, "call-77", ^id}, verb: ^verb}}}
    send(task.pid, {:outcome, %{id: id, verb: verb, status: if(reason, do: :rejected, else: :done), reason: reason, data: data}})
  end
  defp look(a,b), do: %{probe_occupancy: [%{cell: [0,0,0], material: a}, %{cell: [1,0,0], material: b}]}

  defp build(task) do
    reply(task, 1, :query_balances)
    reply(task, 2, :move_to)
    reply(task, 3, :look, look(0,0))
    reply(task, 4, :place)
    reply(task, 5, :place)
    reply(task, 6, :look, look(11,11))
  end

  test "one call scopes all command ids and finishes only after an authority snapshot agrees" do
    task = start_run()
    build(task)
    assert {{:ok, %{status: :completed, cells: 2, remaining: %{todo: [], wrong: []},
      metrics: %{request_count: 0, jev_request_count: 0}}}, nil} = Task.await(task)
    assert_received {:authority_read, [{0,0,0}, {1,0,0}]}
    refute_received :planner_request
    refute_received :jev_request
  end

  test "a different goal does not resume the previous plan and counts its one planner request" do
    task = start_run(args: %{goal: "two stones"}, remembered: %{"goal" => "old unrelated goal", "ops" => @ops})
    build(task)
    assert {{:ok, %{metrics: %{request_count: 1, jev_request_count: 0}}}, nil} = Task.await(task)
    assert_received :planner_request
  end

  test "the same goal resumes from memory by looking, with no planner or placement" do
    task = start_run(args: %{goal: "two stones"}, remembered: %{"goal" => "two stones", "ops" => @ops})
    reply(task, 1, :query_balances)
    reply(task, 2, :move_to)
    reply(task, 3, :look, look(11,11))
    assert {{:ok, %{metrics: %{request_count: 0, jev_request_count: 0}}}, nil} = Task.await(task)
    refute_received {:"$gen_cast", {:command, %{verb: :place}}}
  end

  test "material shortage is blocked, keeps the plan, and counts one Jev request" do
    task = start_run(args: %{goal: "two stones"}, world: %{{0,0,0} => 0, {1,0,0} => 0})
    reply(task, 1, :query_balances)
    reply(task, 2, :move_to)
    reply(task, 3, :look, look(0,0))
    reply(task, 4, :place, nil, :insufficient_material)
    assert {{:error, %{status: :blocked, reason: reason, remaining: %{todo: [{{0,0,0},11}, {{1,0,0},11}], wrong: []}},
      %{request_count: 1, jev_request_count: 1}}, %{"goal" => "two stones", "ops" => @ops}} = Task.await(task)
    assert reason =~ "not enough material"
  end

  test "a successful old look cannot override a changed World or erase the resumable plan" do
    task = start_run(args: %{goal: "two stones"}, world: %{{0,0,0} => 11, {1,0,0} => 0})
    build(task)
    assert {{:error, %{status: :blocked, reason: :world_changed,
      remaining: %{todo: [{{1,0,0},11}], wrong: []}}, %{request_count: 1, jev_request_count: 0}},
      %{"goal" => "two stones", "ops" => @ops}} = Task.await(task)
  end

  test "three failed plans stop without inventing an empty completed target" do
    task = start_run(args: %{goal: "two stones"}, request: fn _, _ -> {:error, :timeout} end)
    reply(task, 1, :query_balances)
    assert {{:error, %{status: :blocked, reason: reason, remaining: :unknown},
      %{request_count: 3, jev_request_count: 0}}, nil} = Task.await(task)
    assert reason =~ "no usable blueprint after 3 planning attempts"
    refute_received {:authority_read, _}
  end
end
