defmodule DataService.NpcMemoryTest do
  @moduledoc "全局系统功能的存储层测试：NPC 长期记忆 round-trip。DB-backed。"
  use ExUnit.Case, async: false
  alias DataService.NpcMemory

  setup_all do
    MmoTest.Database.start!()
    :ok
  end

  setup do
    DataService.Repo.delete_all("npc_memories")
    :ok
  end

  test "content retrieval finds old Chinese and English notes without keys and isolates cid" do
    :ok =
      NpcMemory.put(7, "note", "entrance", %{"text" => "西门有障碍，先检查头顶净空", "position" => [-2, 3, 4]})

    :ok = NpcMemory.journal(7, "Doorway headroom blocked by a beam", {1, 2, 3})
    for n <- 1..8, do: :ok = NpcMemory.put(7, "note", "noise#{n}", %{"text" => "无关记录#{n}"})
    :ok = NpcMemory.put(8, "note", "entrance", %{"text" => "西门净空 headroom private"})

    assert [%{key: "entrance", body: %{"text" => "西门有障碍，先检查头顶净空"}, position: [-2, 3, 4]}] =
             NpcMemory.search(7, "检查西门净空", 5)

    assert [%{kind: "event", body: %{"text" => "Doorway headroom blocked by a beam"}}] =
             NpcMemory.search(7, "HEADROOM", 5)

    assert [] == NpcMemory.search(9, "西门 headroom", 5)
    assert [] == NpcMemory.search(7, "%_", 5)
    assert [] == NpcMemory.search(7, "head", 5)
    assert length(NpcMemory.recent_notes(7, 5)) == 5
  end

  test "working memory is one overwritable row per {cid, kind, key}, separate per NPC" do
    assert nil == NpcMemory.get(7, "plan", "current")
    :ok = NpcMemory.put(7, "plan", "current", %{"ops" => [%{"op" => "fill", "min" => [0, 0, 0]}]})
    :ok = NpcMemory.put(8, "plan", "current", %{"ops" => []})
    :ok = NpcMemory.put(7, "plan", "current", %{"ops" => [], "goal" => "hut"})

    assert %{"ops" => [], "goal" => "hut"} == NpcMemory.get(7, "plan", "current")
    assert %{"ops" => []} == NpcMemory.get(8, "plan", "current")
    assert 2 == DataService.Repo.aggregate("npc_memories", :count)

    :ok = NpcMemory.delete(7, "plan", "current")
    assert nil == NpcMemory.get(7, "plan", "current")
    assert %{"ops" => []} == NpcMemory.get(8, "plan", "current")
  end

  test "the journal only appends; recent returns the newest first with the place, per NPC" do
    for {text, x} <- [{"first", 1}, {"second", 2}, {"third", 3}],
        do: :ok = NpcMemory.journal(7, text, {x, 519.0, 60})

    :ok = NpcMemory.journal(8, "someone else's", {0, 0, 0})

    assert [%{text: "third", place: {3.0, 519.0, 60.0}, at: %DateTime{}}, %{text: "second"}] =
             NpcMemory.recent(7, 2)

    assert ["third", "second", "first"] == Enum.map(NpcMemory.recent(7, 10), & &1.text)
    assert ["someone else's"] == Enum.map(NpcMemory.recent(8, 10), & &1.text)
  end

  # 长期运行的 NPC 每轮都检索记忆：行数必须有界。上限由存储层唯一拥有（limits/0）。
  test "retention keeps the newest notes and events per NPC and drops only the oldest" do
    require Ecto.Query
    %{notes: notes, events: events} = NpcMemory.limits()
    assert {200, 1000} == {notes, events}

    for n <- 1..(notes + 1), do: :ok = NpcMemory.put(7, "note", "k#{n}", %{"text" => "note #{n}"})
    :ok = NpcMemory.put(8, "note", "k1", %{"text" => "other npc"})
    # 覆盖算一次写入：k2 被刷新后不再是最旧的。
    :ok = NpcMemory.put(7, "note", "k2", %{"text" => "note 2 again"})
    :ok = NpcMemory.put(7, "note", "k#{notes + 2}", %{"text" => "newest"})

    assert nil == NpcMemory.get(7, "note", "k1")
    assert nil == NpcMemory.get(7, "note", "k3")
    assert %{"text" => "note 2 again"} == NpcMemory.get(7, "note", "k2")
    assert %{"text" => "other npc"} == NpcMemory.get(8, "note", "k1")

    count = fn cid, kind ->
      DataService.Repo.aggregate(
        Ecto.Query.from(m in "npc_memories", where: m.cid == ^cid and m.kind == ^kind),
        :count
      )
    end

    assert notes == count.(7, "note")

    # 工作记忆（plan）不受笔记上限影响。
    :ok = NpcMemory.put(7, "plan", "current", %{"ops" => []})
    assert %{"ops" => []} == NpcMemory.get(7, "plan", "current")

    for n <- 1..(events + 1), do: :ok = NpcMemory.journal(7, "event #{n}", {n, 0, 0})
    assert events == count.(7, "event")
    assert "event #{events + 1}" == hd(NpcMemory.recent(7, 1)).text
    assert "event 2" == List.last(NpcMemory.recent(7, events)).text
  end
end
