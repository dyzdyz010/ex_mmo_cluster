defmodule GateServer.NpcAppraisalTest do
  @moduledoc "只测试：手算输入验证情绪接纳、来源消费和时间，不启动世界或模型。"
  use ExUnit.Case, async: true
  alias GateServer.Npc.Life.{Appraisal, State}

  defp state do
    State.new(11, "world", 0, 0)
    |> Appraisal.enable()
    |> Appraisal.enqueue("speech", %{"text" => "谢谢你的帮助", "speaker_id" => 12}, [12], 0)
  end

  defp feeling(name \\ "joy") do
    %{
      "emotion" => name,
      "intensity" => 0.6,
      "source_seq" => 1,
      "target_id" => 12,
      "reason" => "邻居认可了我的帮助"
    }
  end

  test "非建设经历产生 OCC 情绪，混合情绪独立存在且半衰期不重置" do
    assert {:ok, next} = Appraisal.apply(state(), 1, [feeling(), feeling("gratification")], 0)
    assert State.view(next, 0)["emotions"]["joy"] == 0.6
    assert State.view(next, 0)["emotions"]["gratification"] == 0.6
    assert next["affect"]["cursor"] == 1
    assert next["affect"]["pending"] == []
    assert State.view(next, 120_000)["emotions"]["joy"] == 0.3
    assert {:error, :stale_appraisal} = Appraisal.apply(next, 1, [feeling()], 120_000)
    assert {:ok, ^next} = Appraisal.apply(next, 1, [], 120_000)
  end

  test "非法类别、强度、来源、对象以及重复条目在接纳边界拒绝" do
    for changed <- [
          Map.put(feeling(), "emotion", "curiosity"),
          Map.put(feeling(), "intensity", 1.1),
          Map.put(feeling(), "source_seq", 2),
          Map.put(feeling(), "target_id", 999),
          Map.put(feeling(), "reason", "")
        ] do
      assert {:error, :invalid_appraisal} = Appraisal.apply(state(), 1, [changed], 0)
    end

    assert {:error, :invalid_appraisal} = Appraisal.apply(state(), 1, [feeling(), feeling()], 0)
  end

  test "只消费本轮看到的经历，在途新来源留给下轮；空评价不激发情绪" do
    next = Appraisal.enqueue(state(), "outcome", %{"status" => "done"}, [], 10)
    assert {:ok, next} = Appraisal.apply(next, 1, [], 20)
    assert Enum.map(next["affect"]["pending"], & &1["seq"]) == [2]
    assert State.view(next, 20)["emotions"]["joy"] == 0.0
    assert {:error, :invalid_appraisal} = Appraisal.apply(next, 3, [], 20)
  end

  test "迁移保留已有情绪人格关系且可重复加载" do
    old = State.new(11, "world", 9, 100) |> put_in(["emotions", "anger"], 0.4)
    next = Appraisal.enable(old)
    assert State.view(next, 100)["emotions"]["anger"] == 0.4
    assert next["traits"] == old["traits"]
    assert next["relationships"] == old["relationships"]
    assert intensity(State.view(next, 100), "anger", "legacy", "anger") == 0.4
    assert Appraisal.enable(next) == next
  end

  test "未知词表显式拒绝，不重置其待评价经历" do
    unknown = put_in(state(), ["affect", "vocabulary"], "unknown-v2")
    assert {:error, {:unsupported_emotion_vocabulary, "unknown-v2"}} = Appraisal.enable(unknown)
  end

  test "弱刺激不能把强情绪归因给另一个人" do
    assert {:ok, first} = Appraisal.apply(state(), 1, [feeling("anger")], 0)
    next = Appraisal.enqueue(first, "speech", %{}, [13], 0)

    weak =
      Map.merge(feeling("anger"), %{"source_seq" => 2, "target_id" => 13, "intensity" => 0.1})

    assert {:ok, next} = Appraisal.apply(next, 2, [weak], 0)
    assert State.view(next, 0)["emotions"]["anger"] == 0.6
    assert State.view(next, 0)["evidence"]["anger"]["actor"] == 12
    assert next["affect"]["last"]["entries"] == [weak]
  end

  test "积压按有限前缀逐轮消费，批次不丢来源也不提前消费后缀" do
    backlog =
      Enum.reduce(2..40, state(), fn _, s -> Appraisal.enqueue(s, "speech", %{}, [], 0) end)

    first = Appraisal.context(backlog)
    assert length(first.sources) > 0 and length(first.sources) < 40
    assert first.through == List.last(first.sources)["seq"]
    assert {:ok, next} = Appraisal.apply(backlog, first.through, [], 0)
    second = Appraisal.context(next)
    assert hd(second.sources)["seq"] == first.through + 1
    assert length(next["affect"]["pending"]) + length(first.sources) == 40
  end

  test "同来源同类情绪可指向两人，后续新评价与衰减互不覆盖" do
    initial =
      Appraisal.enqueue(
        State.new(11, "world", 0, 0) |> Appraisal.enable(),
        "speech",
        %{},
        [12, 13],
        0
      )

    a = Map.put(feeling("anger"), "intensity", 0.8)
    b = Map.merge(a, %{"target_id" => 13, "intensity" => 0.2})
    assert {:ok, next} = Appraisal.apply(initial, 1, [a, b], 0)
    assert length(next["feelings"]) == 2
    refute Map.has_key?(next, "emotions")
    next = Appraisal.enqueue(next, "speech", %{}, [13], 120_000)

    assert {:ok, next} =
             Appraisal.apply(next, 2, [%{b | "source_seq" => 2, "intensity" => 0.3}], 120_000)

    view = State.view(next, 240_000)
    assert intensity(view, "anger", "actor", 12) == 0.2
    assert intensity(view, "anger", "actor", 13) == 0.15
    assert view["emotions"]["anger"] == 0.2
    assert view["evidence"]["anger"]["actor"] == 12
    assert Enum.find(next["feelings"], &(&1["object"]["id"] == 12))["at_ms"] == 0
  end

  test "无人物评价分别指向触发事件，事件与人物的相同数字不混淆" do
    initial =
      Appraisal.enqueue(
        State.new(11, "world", 0, 0) |> Appraisal.enable(),
        "outcome",
        %{},
        [1],
        0
      )

    event = %{feeling() | "target_id" => nil}
    actor = %{feeling() | "target_id" => 1}
    assert {:ok, next} = Appraisal.apply(initial, 1, [event, actor], 0)
    next = Appraisal.enqueue(next, "outcome", %{}, [], 0)
    assert {:ok, next} = Appraisal.apply(next, 2, [%{event | "source_seq" => 2}], 0)
    assert length(next["feelings"]) == 3
    assert intensity(State.view(next, 0), "joy", "event", 1) == 0.6
    assert intensity(State.view(next, 0), "joy", "event", 2) == 0.6
    assert intensity(State.view(next, 0), "joy", "actor", 1) == 0.6
  end

  test "旧模型状态迁移保存来源和待办，未知 schema 拒绝" do
    old =
      State.new(11, "world", 0, 100)
      |> put_in(["emotions", "anger"], 0.8)
      |> put_in(["evidence", "anger"], %{"actor" => 12, "seq" => 7})
      |> Map.put("affect", %{
        "vocabulary" => "occ22-v1",
        "cursor" => 7,
        "next_seq" => 8,
        "pending" => [%{"seq" => 8}],
        "last" => nil
      })

    migrated = Appraisal.enable(old)
    assert migrated["affect"]["schema"] == 2
    assert migrated["affect"]["pending"] == old["affect"]["pending"]
    assert intensity(State.view(migrated, 120_100), "anger", "actor", 12) == 0.4
    assert Appraisal.enable(migrated) == migrated

    assert {:error, {:unsupported_emotion_schema, 99}} =
             Appraisal.enable(put_in(migrated, ["affect", "schema"], 99))
  end

  defp intensity(view, emotion, kind, id) do
    Enum.find(
      view["feelings"],
      &(&1["emotion"] == emotion and &1["object"] == %{"kind" => kind, "id" => id})
    )["intensity"]
  end

  test "重复读取同一衰减视图不二次衰减，同对象弱刺激保留原来源" do
    assert {:ok, first} = Appraisal.apply(state(), 1, [feeling("anger")], 0)
    view = State.view(first, 120_000)
    assert State.view(view, 120_000) == view
    next = Appraisal.enqueue(first, "speech", %{}, [12], 120_000)
    weak = %{feeling("anger") | "source_seq" => 2, "intensity" => 0.1}
    assert {:ok, next} = Appraisal.apply(next, 2, [weak], 120_000)
    assert hd(next["feelings"])["evidence"]["seq"] == 1
    assert State.view(next, 240_000)["emotions"]["anger"] == 0.15
  end
end
