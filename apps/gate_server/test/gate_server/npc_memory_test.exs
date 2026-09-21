defmodule GateServer.NpcMemoryTest do
  @moduledoc "只测试：模型记忆工具边界与真实 npc_memories 持久化；不调用模型或在线 Body。"
  use ExUnit.Case, async: false
  alias GateServer.Npc.Memory
  alias DataService.NpcMemory

  setup_all do
    MmoTest.Database.start!()
    :ok
  end

  setup do
    DataService.Repo.delete_all("npc_memories")
    :ok
  end

  defmodule FailedStore do
    def put(_,_,_,_),do: {:error,:write_denied}
    def get(_,_,_),do: raise DBConnection.ConnectionError,message: "read unavailable"
    def recent(_,_),do: exit(:database_down)
  end

  defmodule BuggyStore do
    def get(_,_,_),do: raise ArgumentError,"program defect"
  end

  test "tool schemas require every declared argument and commands retain explicit identity" do
    [remember,recall]=Memory.tools()
    assert remember.type=="function" and remember.name=="remember"
    assert remember.parameters.required==["key","text"]
    assert remember.parameters.additionalProperties==false
    assert remember.parameters.properties.key.maxLength==128
    assert remember.parameters.properties.text.maxLength==1500
    assert recall.name=="recall" and recall.parameters.required==["key"]
    assert Memory.command("remember",%{"key"=>"route","text"=>"Use the west door"},41)==
      %{id: 41,verb: :remember,key: "route",text: "Use the west door"}
    assert Memory.command("recall",%{"key"=>"route"},42)==%{id: 42,verb: :recall,key: "route"}
  end

  test "remember and recall use one durable note per cid and key without process caches" do
    a=Memory.command("remember",%{"key"=>"plan","text"=>"Build west"},1)
    assert Memory.execute(NpcMemory,701,{-3,5,7},a)==%{id: 1,verb: :remember,status: :done,reason: nil,
      data: %{key: "plan",body: %{"text"=>"Build west","position"=>[-3,5,7]}}}
    assert %{"text"=>"Build west","position"=>[-3,5,7]}==NpcMemory.get(701,"note","plan")
    assert %{status: :done}=Memory.execute(NpcMemory,702,{8,9,10},%{a | text: "Keep east"})
    assert %{status: :done}=Memory.execute(NpcMemory,701,{-1,2,3},%{a | text: "West complete"})
    assert DataService.Repo.aggregate("npc_memories",:count)==2
    recall=Memory.command("recall",%{"key"=>"plan"},2)
    # 新进程读取同一数据库；停止写入者不能丢失或串用角色记忆。
    outcome=Task.async(fn -> Memory.execute(NpcMemory,701,{0,0,0},recall) end) |> Task.await()
    assert outcome==%{id: 2,verb: :recall,status: :done,reason: nil,
      data: %{key: "plan",body: %{"text"=>"West complete","position"=>[-1,2,3]}}}
    assert %{data: %{body: %{"text"=>"Keep east"}}}=Memory.execute(NpcMemory,702,{0,0,0},recall)
    :ok=NpcMemory.put(701,"note","plan",%{"text"=>"Storage changed","position"=>[11,12,13]})
    assert %{data: %{body: %{"text"=>"Storage changed"}}}=Memory.execute(NpcMemory,701,{0,0,0},recall)
    assert Memory.execute(NpcMemory,703,{0,0,0},recall)==%{id: 2,verb: :recall,status: :done,reason: nil,
      data: %{key: "plan",missing: true}}
  end

  test "model length and type errors are rejected before any database write" do
    valid=%{id: 7,verb: :remember,key: String.duplicate("键",128),text: String.duplicate("记",1500)}
    assert %{status: :done}=Memory.execute(NpcMemory,701,{0,0,0},valid)
    for command <- [%{valid | key: String.duplicate("a",129)},%{valid | text: String.duplicate("a",1501)},
      %{valid | key: ""},%{valid | text: ""},%{valid | key: 123},%{valid | text: nil},Memory.command("remember",%{},8),
      Memory.command("recall",%{"key"=>nil},9),Memory.command("remember",[],10)] do
      assert %{status: :rejected,reason: :invalid_memory_arguments,data: nil}=Memory.execute(NpcMemory,701,{0,0,0},command)
    end
    assert DataService.Repo.aggregate("npc_memories",:count)==1
  end

  test "recent injects five dated events from the correct cid and respects explicit limit" do
    for n<-1..6,do: :ok=NpcMemory.journal(701,"event #{n}",{n,-2,3})
    :ok=NpcMemory.journal(702,"other npc",{0,0,0})
    assert {:ok,events}=Memory.recent(NpcMemory,701)
    assert Enum.map(events,& &1.text)==["event 6","event 5","event 4","event 3","event 2"]
    assert hd(events).position==[6.0,-2.0,3.0]
    assert {:ok,%DateTime{},0}=DateTime.from_iso8601(hd(events).at)
    assert {:ok,[%{text: "event 6"}]}=Memory.recent(NpcMemory,701,1)
    assert {:ok,[]}=Memory.recent(NpcMemory,703)
  end

  test "storage errors remain explicit outcomes and recent failures do not masquerade as empty history" do
    remember=Memory.command("remember",%{"key"=>"plan","text"=>"later"},1)
    assert %{status: :rejected,reason: {:memory_unavailable,:write_denied}}=Memory.execute(FailedStore,701,{0,0,0},remember)
    recall=Memory.command("recall",%{"key"=>"plan"},2)
    assert %{status: :rejected,reason: {:memory_unavailable,DBConnection.ConnectionError}}=Memory.execute(FailedStore,701,{0,0,0},recall)
    assert {:error,{:memory_unavailable,:process_exit}}=Memory.recent(FailedStore,701)
    assert_raise ArgumentError,"program defect",fn -> Memory.execute(BuggyStore,701,{0,0,0},recall) end
  end
end
