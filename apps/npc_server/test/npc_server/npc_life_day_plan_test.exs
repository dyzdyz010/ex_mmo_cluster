defmodule NpcServer.NpcLifeDayPlanTest do
  @moduledoc """
  只测试：日计划纯函数核心 `NpcServer.Life.DayPlan` 的契约——应答检查、持久行形状、调用额度与触发判定、采用计划、活动记账、给 Mind 的栏。

  `check/3` 的合格 / 不合格样例是 S1-R8 离线测量里规划模型的真实应答（取出的 `text` 块；来源见
  `test/support/fixtures/day_plan/README.md`），期望取自 S1-R8 `results.json` 里记的检查结果；其余失败原因用对这些真实正文
  删减 / 换写法得到的变体来测。要进持久行的数据每步过一遍 JSON，证明是能原样存取的普通 map。
  不证明：规划提示词、写作调用、Life 的接线与持久化（后续任务）。
  """
  use ExUnit.Case, async: true
  @moduletag :t0
  alias NpcServer.Life.DayPlan

  @fixtures Path.expand("../support/fixtures/day_plan", __DIR__)

  defp sample(name),
    do: Path.join(@fixtures, "s1r8-#{name}.json") |> File.read!() |> Jason.decode!()

  defp check_sample(name, now_minute \\ nil) do
    s = sample(name)
    DayPlan.check(s["text"], s["activity_names"], now_minute || s["now_minute"])
  end

  # 对真实正文做变体：解码 → 改 → 编码，再按同一份词表与此刻检查。
  defp check_variant(name, fun, now_minute \\ nil) do
    s = sample(name)
    text = s["text"] |> Jason.decode!() |> fun.() |> Jason.encode!()
    DayPlan.check(text, s["activity_names"], now_minute || s["now_minute"])
  end

  defp checked!(name) do
    assert {:ok, checked} = check_sample(name)
    checked
  end

  defp json(term), do: term |> Jason.encode!() |> Jason.decode!()

  defp minutes(hhmm) do
    [h, m] = String.split(hhmm, ":")
    String.to_integer(h) * 60 + String.to_integer(m)
  end

  describe "check/3：S1-R8 的真实应答" do
    test "整份合格的真实应答：意图与想做而写不出的事数量、by 换成日内分钟，与 S1-R8 记的一致" do
      for name <- ["R3-r1", "R2-r1", "R5-r1"] do
        s = sample(name)
        expected = s["s1r8_checks"]
        assert expected["all_pass"]

        assert {:ok, %{intents: intents, wants: wants}} = check_sample(name)
        assert length(intents) == expected["intents_n"]
        assert length(wants) == expected["cannot_n"]
        assert Enum.map(intents, & &1["by"]) == Enum.map(expected["by_values"], &minutes/1)
      end
    end

    test "合格结果的每条意图键恰为 activity / times / by / why，wants 键恰为 want / why，原文不改，且过 JSON 不变形" do
      {:ok, %{intents: intents, wants: wants} = checked} = check_sample("R3-r1")
      raw = sample("R3-r1")["text"] |> Jason.decode!()

      assert [first | _] = intents

      assert first == %{
               "activity" => "guard_hut",
               "times" => 1,
               "by" => 13 * 60,
               "why" => hd(raw["intents"])["why"]
             }

      assert wants == raw["cannot_yet"]
      assert json(checked.intents) == checked.intents
    end

    test "R1-r1 是 18 份里唯一不过 S1-R8 检查 5 的：五条意图加一条想做的事共 6 条，超过 5" do
      s = sample("R1-r1")
      assert s["s1r8_checks"]["check1"] and s["s1r8_checks"]["check4"]
      refute s["s1r8_checks"]["check5"]
      assert check_sample("R1-r1") == {:error, {:too_many_items, 6}}
    end

    test "R1-r1 去掉想做的事后恰为 5 条：合格（上限含 5）" do
      assert {:ok, %{intents: intents, wants: []}} =
               check_variant("R1-r1", &Map.put(&1, "cannot_yet", []))

      assert length(intents) == 5
    end

    test "R2 夜间的真实应答：此刻 22:26，22:50 与 23:30 都晚于此刻" do
      assert sample("R2-r1")["now_minute"] == 22 * 60 + 26
      assert {:ok, %{intents: [%{"by" => 1370}, %{"by" => 1410}]}} = check_sample("R2-r1")
    end

    test "此刻挪到某条 by 之后：该条 by_not_after_now，原因里是原文 HH:MM；by 恰等于此刻也不过（严格晚于）" do
      assert check_sample("R2-r1", 23 * 60) == {:error, {:by_not_after_now, "22:50"}}
      assert check_sample("R2-r1", 22 * 60 + 50) == {:error, {:by_not_after_now, "22:50"}}
      assert {:ok, _} = check_sample("R2-r1", 22 * 60 + 49)
    end

    test "至多一对围栏：带 json 标记、不带标记、前后有空白都能过，结果与不带围栏的一致" do
      s = sample("R3-r1")
      expected = check_sample("R3-r1")

      for wrapped <- [
            "```json\n" <> s["text"] <> "\n```",
            "```\n" <> s["text"] <> "\n```",
            "\n  ```json\n" <> s["text"] <> "\n```  \n"
          ] do
        assert DayPlan.check(wrapped, s["activity_names"], s["now_minute"]) == expected
      end
    end

    test "围栏之外还有文字、两对围栏、围栏没闭合：都是 :not_json" do
      s = sample("R3-r1")
      names = s["activity_names"]
      now = s["now_minute"]
      fenced = "```json\n" <> s["text"] <> "\n```"

      assert DayPlan.check("Here is my plan:\n" <> fenced, names, now) == {:error, :not_json}
      assert DayPlan.check(fenced <> "\nThat is all.", names, now) == {:error, :not_json}
      assert DayPlan.check(fenced <> "\n" <> fenced, names, now) == {:error, :not_json}
      assert DayPlan.check("```json\n" <> s["text"], names, now) == {:error, :not_json}
    end
  end

  describe "check/3：对真实正文做变体得到的失败原因" do
    test "不是 JSON：把正文截掉后半 → :not_json；正文前加一句话 → :not_json" do
      s = sample("R3-r1")
      names = s["activity_names"]
      now = s["now_minute"]
      half = binary_part(s["text"], 0, div(byte_size(s["text"]), 2))

      assert DayPlan.check(half, names, now) == {:error, :not_json}
      assert DayPlan.check("My plan: " <> s["text"], names, now) == {:error, :not_json}
      assert DayPlan.check("", names, now) == {:error, :not_json}
    end

    test "是 JSON 但不是对象：把正文里的 intents 列表单独当整段 → :not_object" do
      s = sample("R3-r1")
      list = s["text"] |> Jason.decode!() |> Map.fetch!("intents") |> Jason.encode!()
      assert DayPlan.check(list, s["activity_names"], s["now_minute"]) == {:error, :not_object}
    end

    test "顶层键：缺 cannot_yet、多出一个键、intents 不是列表" do
      assert check_variant("R3-r1", &Map.delete(&1, "cannot_yet")) ==
               {:error, {:missing_key, "cannot_yet"}}

      assert check_variant("R3-r1", &Map.delete(&1, "intents")) ==
               {:error, {:missing_key, "intents"}}

      assert check_variant("R3-r1", &Map.put(&1, "mood", "calm")) ==
               {:error, {:unknown_key, "mood"}}

      assert check_variant("R3-r1", &Map.put(&1, "intents", "guard the hut")) ==
               {:error, {:not_a_list, "intents"}}

      assert check_variant("R3-r1", &Map.put(&1, "cannot_yet", %{})) ==
               {:error, {:not_a_list, "cannot_yet"}}
    end

    test "意图不是对象，或键不齐 / 多出键" do
      assert check_variant(
               "R3-r1",
               &update_in(&1["intents"], fn [_ | rest] -> ["guard_hut" | rest] end)
             ) ==
               {:error, :intent_not_object}

      for key <- ["activity", "times", "by", "why"] do
        assert check_variant(
                 "R3-r1",
                 &update_in(&1["intents"], fn [i | rest] -> [Map.delete(i, key) | rest] end)
               ) ==
                 {:error, {:intent_missing_key, key}}
      end

      assert check_variant(
               "R3-r1",
               &update_in(&1["intents"], fn [i | rest] -> [Map.put(i, "priority", 1) | rest] end)
             ) ==
               {:error, {:intent_unknown_key, "priority"}}
    end

    test "活动名不在词表：换成词表外的名字、改大小写、改成 null，都是 :unknown_activity（逐字相等才算）" do
      put = fn value ->
        &update_in(&1["intents"], fn [i | rest] -> [Map.put(i, "activity", value) | rest] end)
      end

      assert check_variant("R3-r1", put.("patrol_hut")) ==
               {:error, {:unknown_activity, "patrol_hut"}}

      assert check_variant("R3-r1", put.("Guard_hut")) ==
               {:error, {:unknown_activity, "Guard_hut"}}

      assert check_variant("R3-r1", put.("guard_hut ")) ==
               {:error, {:unknown_activity, "guard_hut "}}

      assert check_variant("R3-r1", put.(nil)) == {:error, {:unknown_activity, nil}}
    end

    test "times 必须是 JSON 整数且 ≥ 1：0、负数、2.0、\"2\"、null 都不过" do
      put = fn value ->
        &update_in(&1["intents"], fn [i | rest] -> [Map.put(i, "times", value) | rest] end)
      end

      assert check_variant("R3-r1", put.(0)) == {:error, {:bad_times, 0}}
      assert check_variant("R3-r1", put.(-1)) == {:error, {:bad_times, -1}}
      assert check_variant("R3-r1", put.(2.0)) == {:error, {:bad_times, 2.0}}
      assert check_variant("R3-r1", put.("2")) == {:error, {:bad_times, "2"}}
      assert check_variant("R3-r1", put.(nil)) == {:error, {:bad_times, nil}}
      assert {:ok, %{intents: [%{"times" => 3} | _]}} = check_variant("R3-r1", put.(3))
    end

    test "by 严格匹配 HH:MM：缺前导 0、24:00、分钟 60、带秒、12 小时制、数字、null 都是 :bad_by" do
      put = fn value ->
        &update_in(&1["intents"], fn [i | rest] -> [Map.put(i, "by", value) | rest] end)
      end

      for bad <- [
            "9:30",
            "24:00",
            "13:60",
            "13:30:00",
            "1:30 pm",
            "13.30",
            " 13:30",
            "13:30 ",
            1330,
            nil
          ] do
        assert check_variant("R3-r1", put.(bad)) == {:error, {:bad_by, bad}}
      end

      # 23:59 是上限，合格；换成日内分钟。
      assert {:ok, %{intents: [%{"by" => 1439} | _]}} = check_variant("R3-r1", put.("23:59"))
    end

    test "by 不晚于此刻（含相等）：{:by_not_after_now, \"HH:MM\"}" do
      put = fn value ->
        &update_in(&1["intents"], fn [i | rest] -> [Map.put(i, "by", value) | rest] end)
      end

      # R3-r1 此刻 12:11（731）。
      assert check_variant("R3-r1", put.("12:11")) == {:error, {:by_not_after_now, "12:11"}}
      assert check_variant("R3-r1", put.("08:00")) == {:error, {:by_not_after_now, "08:00"}}
      assert {:ok, _} = check_variant("R3-r1", put.("12:12"))
    end

    test "why 必须是非空串：空串、只有空白、null、数字都是 :bad_why" do
      put = fn value ->
        &update_in(&1["intents"], fn [i | rest] -> [Map.put(i, "why", value) | rest] end)
      end

      for bad <- ["", "   ", nil, 7] do
        assert check_variant("R3-r1", put.(bad)) == {:error, :bad_why}
      end
    end

    test "想做而写不出的事：不是对象、键不齐、多出键、want / why 为空" do
      put = fn fun -> &update_in(&1["cannot_yet"], fn [w | rest] -> [fun.(w) | rest] end) end

      assert check_variant("R3-r1", put.(fn _ -> "ask Corvin" end)) == {:error, :want_not_object}

      assert check_variant("R3-r1", put.(&Map.delete(&1, "why"))) ==
               {:error, {:want_missing_key, "why"}}

      assert check_variant("R3-r1", put.(&Map.delete(&1, "want"))) ==
               {:error, {:want_missing_key, "want"}}

      assert check_variant("R3-r1", put.(&Map.put(&1, "by", "13:00"))) ==
               {:error, {:want_unknown_key, "by"}}

      assert check_variant("R3-r1", put.(&Map.put(&1, "want", ""))) == {:error, :bad_want}
      assert check_variant("R3-r1", put.(&Map.put(&1, "why", " "))) == {:error, :bad_want_why}
    end

    test "两张表合计超过 5 条：{:too_many_items, n}，n 是总条数（意图 3 + 想做 3）" do
      assert check_variant("R3-r1", fn plan ->
               Map.update!(plan, "cannot_yet", fn [w | _] -> [w, w, w] end)
             end) == {:error, {:too_many_items, 6}}
    end

    test "同一份里先报逐条的错、最后才数条数（与 S1-R8 检查 3、4 先于检查 5 的次序一致）" do
      assert check_variant("R1-r1", fn plan ->
               update_in(plan["intents"], fn [i | rest] -> [Map.put(i, "times", 0) | rest] end)
             end) == {:error, {:bad_times, 0}}
    end

    test "意图与想做的事都为空列表：合格（两张表都可以空）" do
      assert check_variant("R3-r1", &%{&1 | "intents" => [], "cannot_yet" => []}) ==
               {:ok, %{intents: [], wants: []}}
    end
  end

  describe "new/0 与持久行形状" do
    test "空的一份：形状与实现设计稿 §1 一致，过 JSON 后相等" do
      plan = DayPlan.new()

      assert plan == %{
               "day" => nil,
               "intents" => [],
               "wants" => [],
               "calls" => %{"day" => nil, "n" => 0},
               "event_waiting" => false,
               "last_at_ms" => nil,
               "last" => nil,
               "counts" => %{
                 "planned" => 0,
                 "replanned" => 0,
                 "failed" => 0,
                 "rejected" => 0,
                 "skipped" => 0
               }
             }

      assert json(plan) == plan
    end

    test "采用、记账、失败、跳过之后的行仍是字符串键的普通 map：过 JSON 后相等" do
      plan =
        DayPlan.new()
        |> adopt!("R3-r1", 4, 731, :day, 1_000)
        |> DayPlan.record_activity("guard_hut", 4, 740)
        |> DayPlan.note_event()
        |> DayPlan.fail(:event, :rejected, {:by_not_after_now, "12:11"}, 2_000)
        |> DayPlan.fail(:day, :failed, :timeout, 3_000)
        |> DayPlan.skip()

      assert json(plan) == plan
    end
  end

  defp adopt!(plan, name, day, now_minute, kind, at_ms) do
    DayPlan.adopt(plan, day, now_minute, checked!(name), kind, at_ms)
  end

  describe "admit/3：当日规划调用额度" do
    test "一个游戏日 5 次（规划加重排共计）：前 5 次记数通过，第 6 次 {:error, :day_budget_exhausted} 且行不变" do
      plan =
        Enum.reduce(1..5, DayPlan.new(), fn n, plan ->
          assert {:ok, plan} = DayPlan.admit(plan, 7, n)
          assert plan["calls"] == %{"day" => 7, "n" => n}
          plan
        end)

      assert DayPlan.admit(plan, 7, 6) == {:error, :day_budget_exhausted}
      assert plan["calls"] == %{"day" => 7, "n" => 5}
    end

    test "跨日清零：第二天从 1 起算；调用数只增不因采用计划而变" do
      {:ok, plan} = DayPlan.admit(DayPlan.new(), 7, 0)
      plan = Enum.reduce(1..4, plan, fn n, plan -> elem(DayPlan.admit(plan, 7, n), 1) end)
      assert DayPlan.admit(plan, 7, 5) == {:error, :day_budget_exhausted}

      assert {:ok, next} = DayPlan.admit(plan, 8, 6)
      assert next["calls"] == %{"day" => 8, "n" => 1}

      {:ok, again} = DayPlan.admit(DayPlan.new(), 7, 0)
      adopted = DayPlan.adopt(again, 7, 100, checked!("R3-r1"), :day, 1)
      assert adopted["calls"] == again["calls"]
    end

    test "放行时记 last_at_ms（起调用就记，最小间隔从它算）并清 event_waiting（这次调用的材料已含那条 event）" do
      plan = adopt!(DayPlan.new(), "R3-r1", 4, 731, :day, 1_000) |> DayPlan.note_event()
      assert {:ok, admitted} = DayPlan.admit(plan, 4, 500_000)
      assert admitted["last_at_ms"] == 500_000
      refute admitted["event_waiting"]
      assert DayPlan.due(admitted, 4, 500_000 + 3 * 60_000 - 1) == nil

      # 其余不动：意图、wants、last、计数。
      assert Map.drop(admitted, ["calls", "last_at_ms", "event_waiting"]) ==
               Map.drop(plan, ["calls", "last_at_ms", "event_waiting"])

      assert json(admitted) == admitted
    end
  end

  describe "due/3：此刻该不该起一次规划" do
    @gap 3 * 60_000

    test "本游戏日还没有采纳过计划 → :day；采纳之后同日无事 → nil；新的一天 → :day" do
      assert DayPlan.due(DayPlan.new(), 4, 0) == :day

      plan = adopt!(DayPlan.new(), "R3-r1", 4, 731, :day, 0)
      assert DayPlan.due(plan, 4, 10 * @gap) == nil
      assert DayPlan.due(plan, 5, 10 * @gap) == :day
    end

    test "有一条 event 经历在等（note_event）且计划是今天的 → :event；起调用（admit）清掉条件，采用之后不再触发" do
      plan = adopt!(DayPlan.new(), "R3-r1", 4, 731, :day, 0) |> DayPlan.note_event()
      assert plan["event_waiting"]
      assert DayPlan.due(plan, 4, 10 * @gap) == :event

      {:ok, admitted} = DayPlan.admit(plan, 4, 10 * @gap)
      replanned = adopt!(admitted, "R2-r1", 4, 731, :event, 10 * @gap)
      refute replanned["event_waiting"]
      assert DayPlan.due(replanned, 4, 20 * @gap) == nil
    end

    test "调用在途时又来一条 event（admit 之后、adopt 之前 note_event）：采用不清它，间隔过后再给 :event" do
      plan = adopt!(DayPlan.new(), "R3-r1", 4, 731, :day, 0) |> DayPlan.note_event()
      {:ok, admitted} = DayPlan.admit(plan, 4, 10 * @gap)

      replanned =
        admitted |> DayPlan.note_event() |> adopt!("R2-r1", 4, 731, :event, 10 * @gap)

      assert replanned["event_waiting"]
      assert DayPlan.due(replanned, 4, 11 * @gap - 1) == nil
      assert DayPlan.due(replanned, 4, 11 * @gap) == :event
    end

    test ":event 与 :day 同时成立时给 :day（新的一天里也有 event 在等）" do
      plan = adopt!(DayPlan.new(), "R3-r1", 4, 731, :day, 0) |> DayPlan.note_event()
      assert DayPlan.due(plan, 5, 10 * @gap) == :day
    end

    test "距上一次起调用不足最小间隔（3 分钟）一律 nil，满 3 分钟即可；条件不被清掉" do
      plan = adopt!(DayPlan.new(), "R3-r1", 4, 731, :day, 1_000) |> DayPlan.note_event()
      assert DayPlan.due(plan, 4, 1_000 + @gap - 1) == nil
      assert DayPlan.due(plan, 5, 1_000 + @gap - 1) == nil
      assert DayPlan.due(plan, 4, 1_000 + @gap) == :event
      assert plan["event_waiting"]
    end

    test "last_at_ms 为 nil 时不受最小间隔限制（没有起过调用）" do
      plan = DayPlan.new()
      assert plan["last_at_ms"] == nil
      assert DayPlan.due(plan, 4, 0) == :day
    end

    test "失败的调用也记 last_at_ms：失败后不立刻再起（防连发），日预算另由 admit/3 管" do
      plan = DayPlan.new() |> DayPlan.fail(:day, :failed, :timeout, 5_000)
      assert plan["last_at_ms"] == 5_000
      assert DayPlan.due(plan, 4, 5_000 + @gap - 1) == nil
      assert DayPlan.due(plan, 4, 5_000 + @gap) == :day
    end
  end

  describe "status/3" do
    setup do
      plan = adopt!(DayPlan.new(), "R5-r1", 4, 102, :day, 0)
      [plan: plan, plaza: Enum.find(plan["intents"], &(&1["activity"] == "visit_plaza"))]
    end

    test "done >= times → :done，不论时限与日号", %{plan: plan, plaza: plaza} do
      done = %{plaza | "done" => 2}
      assert DayPlan.status(plan, done, {4, 100}) == :done
      assert DayPlan.status(plan, done, {4, 1_200}) == :done
      assert DayPlan.status(plan, done, {5, 0}) == :done
    end

    test "没做够：此刻分钟 ≤ by → :open（恰在 by 那一分钟仍 open），> by → :missed，日号已过 → :missed", %{
      plan: plan,
      plaza: plaza
    } do
      assert plaza["by"] == 18 * 60
      assert DayPlan.status(plan, %{plaza | "done" => 1}, {4, 18 * 60}) == :open
      assert DayPlan.status(plan, plaza, {4, 18 * 60 + 1}) == :missed
      assert DayPlan.status(plan, plaza, {5, 0}) == :missed
    end
  end

  describe "adopt/6：采用一份检查合格的计划" do
    test "第一份（日计划）：记日号、意图 id 为 <日号>:<序号>、done 为 0、by 为分钟，wants 整份换，计数与 last 与 last_at_ms 更新" do
      plan = adopt!(DayPlan.new(), "R3-r1", 4, 731, :day, 42_000)
      %{intents: intents, wants: wants} = checked!("R3-r1")

      assert plan["day"] == 4
      assert Enum.map(plan["intents"], & &1["id"]) == ["4:1", "4:2", "4:3"]
      assert Enum.all?(plan["intents"], &(&1["done"] == 0))

      assert Enum.map(plan["intents"], &Map.take(&1, ["activity", "times", "by", "why"])) ==
               intents

      assert plan["wants"] == wants
      refute plan["event_waiting"]
      assert plan["last_at_ms"] == 42_000

      assert plan["last"] == %{
               "at_ms" => 42_000,
               "kind" => "day",
               "result" => "adopted",
               "reason" => nil
             }

      assert plan["counts"]["planned"] == 1
      assert plan["counts"]["replanned"] == 0
    end

    test "同日重排（event）：已 done 与已 missed 的旧意图保留（done 次数不变），open 的换成新的；wants 整份换；replanned + 1" do
      # R3-r1：guard_hut 13:00、visit_plaza 16:00、visit_plaza 21:00（此刻 12:11）。
      plan = adopt!(DayPlan.new(), "R3-r1", 4, 731, :day, 0)

      # 13:00 前做了一次守屋（done）；16:00 之后到 17:00 重排：第一条 visit_plaza（16:00）已 missed，21:00 那条仍 open。
      plan = DayPlan.record_activity(plan, "guard_hut", 4, 750)
      assert [%{"done" => 1}, %{"done" => 0}, %{"done" => 0}] = plan["intents"]

      replanned = adopt!(plan, "R2-r1", 4, 17 * 60, :event, 99)

      # R2-r1 的 by 是 22:50 / 23:30，晚于 17:00；这里只检查采用的行为（check 在此之前已做）。
      old = plan["intents"]

      assert [kept_done, kept_missed | new] = replanned["intents"]
      assert kept_done == Enum.at(old, 0)
      assert kept_missed == Enum.at(old, 1)
      assert Enum.map(new, & &1["activity"]) == ["guard_hut", "visit_plaza"]

      # 序号接着保留项里最大的往下排（4:1、4:2 保留，被换掉的 4:3 不再出现），同一份里 id 不重复。
      assert Enum.map(new, & &1["id"]) == ["4:3", "4:4"]
      assert Enum.all?(new, &(&1["done"] == 0))

      assert replanned["wants"] == checked!("R2-r1").wants
      assert replanned["counts"]["planned"] == 1
      assert replanned["counts"]["replanned"] == 1
      assert replanned["last"]["kind"] == "event"
      assert replanned["last_at_ms"] == 99
    end

    test "跨日：整份换，旧意图（含已 done 的）都不留，id 从新日号起，wants 换成新的" do
      plan =
        adopt!(DayPlan.new(), "R3-r1", 4, 731, :day, 0)
        |> DayPlan.record_activity("guard_hut", 4, 750)

      next = adopt!(plan, "R5-r1", 5, 102, :day, 10)

      assert next["day"] == 5
      assert Enum.map(next["intents"], & &1["id"]) == ["5:1", "5:2"]
      assert next["wants"] == checked!("R5-r1").wants
      assert next["counts"]["planned"] == 2
    end

    test "空的计划（意图与想做的事都为空）也是一次采用：旧的 open 意图被换掉，行里不留旧 wants" do
      plan = adopt!(DayPlan.new(), "R3-r1", 4, 731, :day, 0)
      {:ok, empty} = check_variant("R3-r1", &%{&1 | "intents" => [], "cannot_yet" => []})
      replanned = DayPlan.adopt(plan, 4, 740, empty, :event, 5)
      assert replanned["intents"] == []
      assert replanned["wants"] == []
    end

    test "条目上限 8：同日重排时先丢最旧的已结束项（done / missed）" do
      # 先采用 R1-r1 去掉想做的事后的 5 条（13:00 起的各条 by 13:30–19:00），到 20:00 全部已结束（其中两条做完）。
      {:ok, five} = check_variant("R1-r1", &Map.put(&1, "cannot_yet", []))
      plan = DayPlan.adopt(DayPlan.new(), 4, 780, five, :day, 0)

      plan =
        plan
        |> DayPlan.record_activity("gather_stone", 4, 800)
        |> DayPlan.record_activity("build_hut", 4, 900)

      assert Enum.map(plan["intents"], & &1["id"]) == ["4:1", "4:2", "4:3", "4:4", "4:5"]

      # 20:00 重排，又来 5 条新的（用同一份真实检查结果，by 取晚于 20:00 的）：5 条旧已结束 + 5 条新 = 10 > 8。
      {:ok, late} = check_variant("R1-r1", &late_plan/1, 20 * 60)
      replanned = DayPlan.adopt(plan, 4, 20 * 60, late, :event, 1)

      assert length(replanned["intents"]) == 8
      # 丢掉的是最旧的两条已结束项（4:1、4:2），新来的 5 条全留。
      assert Enum.map(replanned["intents"], & &1["id"]) == [
               "4:3",
               "4:4",
               "4:5",
               "4:6",
               "4:7",
               "4:8",
               "4:9",
               "4:10"
             ]

      assert Enum.take(replanned["intents"], -5) |> Enum.all?(&(&1["done"] == 0))
    end
  end

  # R1-r1 的真实意图把 by 整体后移到晚于 20:00（只改 by，其余原样），作“晚间重排”的合格正文变体。
  defp late_plan(plan) do
    bys = ["20:30", "21:00", "21:30", "22:00", "23:30"]

    plan
    |> Map.update!("intents", fn intents ->
      for {i, by} <- Enum.zip(intents, bys), do: %{i | "by" => by}
    end)
    |> Map.put("cannot_yet", [])
  end

  describe "record_activity/4：一项活动完成时记账" do
    test "给同名、今天、open 的意图里 by 最早的一条加一；其他意图不动" do
      plan = adopt!(DayPlan.new(), "R3-r1", 4, 731, :day, 0)
      # R3-r1：guard_hut 13:00、visit_plaza 16:00、visit_plaza 21:00。
      plan = DayPlan.record_activity(plan, "visit_plaza", 4, 800)
      assert Enum.map(plan["intents"], & &1["done"]) == [0, 1, 0]
    end

    test "最早那条已 done 就记到下一条；两条都 done 之后同名再完成不再加（找不到就原样返回）" do
      plan = adopt!(DayPlan.new(), "R3-r1", 4, 731, :day, 0)

      plan =
        plan
        |> DayPlan.record_activity("visit_plaza", 4, 800)
        |> DayPlan.record_activity("visit_plaza", 4, 810)

      assert Enum.map(plan["intents"], & &1["done"]) == [0, 1, 1]
      assert DayPlan.record_activity(plan, "visit_plaza", 4, 820) == plan
    end

    test "最早那条已 missed（此刻过了它的 by）就记到下一条仍 open 的" do
      plan = adopt!(DayPlan.new(), "R3-r1", 4, 731, :day, 0)
      # 16:00 之后（16:30）：第一条 visit_plaza 已 missed，记到 21:00 那条。
      plan = DayPlan.record_activity(plan, "visit_plaza", 4, 16 * 60 + 30)
      assert Enum.map(plan["intents"], & &1["done"]) == [0, 0, 1]
    end

    test "by 并列取列表里靠前的一条" do
      {:ok, tied} =
        check_variant("R3-r1", fn plan ->
          update_in(plan["intents"], fn [guard, plaza_a, plaza_b] ->
            [guard, %{plaza_a | "by" => "18:00"}, %{plaza_b | "by" => "18:00", "times" => 2}]
          end)
        end)

      plan = DayPlan.adopt(DayPlan.new(), 4, 731, tied, :day, 0)
      plan = DayPlan.record_activity(plan, "visit_plaza", 4, 800)
      assert Enum.map(plan["intents"], & &1["done"]) == [0, 1, 0]
    end

    test "by 恰等于此刻那一分钟仍算 open（minute <= by）" do
      plan = adopt!(DayPlan.new(), "R3-r1", 4, 731, :day, 0)
      plan = DayPlan.record_activity(plan, "guard_hut", 4, 13 * 60)
      assert hd(plan["intents"])["done"] == 1
    end

    test "没有同名意图、日号不是计划的那一天、活动名为空：原样返回，不报错" do
      plan = adopt!(DayPlan.new(), "R3-r1", 4, 731, :day, 0)
      assert DayPlan.record_activity(plan, "build_hut", 4, 800) == plan
      assert DayPlan.record_activity(plan, "visit_plaza", 5, 800) == plan
      assert DayPlan.record_activity(plan, nil, 4, 800) == plan
      assert DayPlan.record_activity(DayPlan.new(), "visit_plaza", 4, 800) == DayPlan.new()
    end

    test "一条意图的 times 为 2：记两次才 done，第三次不再加" do
      plan = adopt!(DayPlan.new(), "R5-r1", 4, 102, :day, 0)
      plan = plan |> DayPlan.record_activity("visit_plaza", 4, 200)
      assert [_, %{"times" => 2, "done" => 1}] = plan["intents"]
      plan = DayPlan.record_activity(plan, "visit_plaza", 4, 300)
      assert [_, %{"done" => 2}] = plan["intents"]
      assert DayPlan.record_activity(plan, "visit_plaza", 4, 400) == plan
    end
  end

  describe "note_event/1、fail/5、skip/1" do
    test "note_event 置 event_waiting，重复调用不变" do
      plan = DayPlan.note_event(DayPlan.new())
      assert plan["event_waiting"]
      assert DayPlan.note_event(plan) == plan
    end

    test "fail：失败 / 被检查拒绝各记计数与 last，意图与 wants 不动；:event 失败把 admit 清掉的 event_waiting 恢复（条件留到下次）" do
      {:ok, plan} =
        adopt!(DayPlan.new(), "R3-r1", 4, 731, :day, 0)
        |> DayPlan.note_event()
        |> DayPlan.admit(4, 6_000)

      refute plan["event_waiting"]

      failed = DayPlan.fail(plan, :event, :failed, :timeout, 7_000)
      assert failed["intents"] == plan["intents"] and failed["wants"] == plan["wants"]
      assert failed["event_waiting"]
      assert failed["counts"]["failed"] == 1

      assert failed["last"] == %{
               "at_ms" => 7_000,
               "kind" => "event",
               "result" => "failed",
               "reason" => ":timeout"
             }

      assert failed["last_at_ms"] == 7_000

      rejected = DayPlan.fail(failed, :event, :rejected, {:too_many_items, 6}, 9_000)
      assert rejected["counts"]["rejected"] == 1
      assert rejected["last"]["result"] == "rejected"
      assert rejected["last"]["reason"] == "{:too_many_items, 6}"
      assert rejected["event_waiting"]
    end

    test "fail：:day 失败不动 event_waiting（日号没采用过，due 本来就再给 :day）" do
      {:ok, plan} = DayPlan.admit(DayPlan.new(), 4, 1_000)
      failed = DayPlan.fail(plan, :day, :failed, :timeout, 1_000)
      refute failed["event_waiting"]
      assert DayPlan.due(failed, 4, 1_000 + @gap) == :day

      # :day 起调用时 admit 清掉了一条在等的 event；:day 失败后它不回来（那条 event 的材料已在这次调用里）。
      {:ok, plan} = DayPlan.new() |> DayPlan.note_event() |> DayPlan.admit(4, 1_000)
      refute DayPlan.fail(plan, :day, :rejected, {:too_many_items, 6}, 1_000)["event_waiting"]
    end

    test "refund：写作前失败的那次退回当日额度——n 减一，失败的记账（计数、last、last_at_ms、event_waiting）不动" do
      {:ok, plan} = DayPlan.admit(DayPlan.new(), 4, 1_000)
      {:ok, plan} = plan |> DayPlan.note_event() |> DayPlan.admit(4, 1_000 + @gap)
      assert plan["calls"] == %{"day" => 4, "n" => 2}

      failed = DayPlan.fail(plan, :event, :failed, :timeout, 1_000 + @gap)
      refunded = DayPlan.refund(failed)

      assert refunded["calls"] == %{"day" => 4, "n" => 1}
      assert %{refunded | "calls" => failed["calls"]} == failed
      assert json(refunded) == refunded

      # 退回后额度按退回后的数算：S1-R10 那样一半调用没问到模型，当日照样还剩额度。
      exhausted =
        Enum.reduce(1..5, DayPlan.new(), fn n, plan ->
          {:ok, plan} = DayPlan.admit(plan, 4, n)
          if rem(n, 2) == 0, do: DayPlan.refund(plan), else: plan
        end)

      assert exhausted["calls"] == %{"day" => 4, "n" => 3}
      assert {:ok, _} = DayPlan.admit(exhausted, 4, 6)
    end

    test "skip：只给 counts.skipped 加一（当日额度用完），其余不动" do
      plan = DayPlan.new()
      skipped = DayPlan.skip(plan)
      assert skipped["counts"]["skipped"] == 1
      assert %{skipped | "counts" => plan["counts"]} == plan
    end
  end

  describe "column/3：给 Mind 的数据" do
    test "没有意图也没有 wants → nil" do
      assert DayPlan.column(DayPlan.new(), 4, 100) == nil
    end

    test "今天的各条 activity / times / done / by / status 与 wants；status 随此刻推出，不存" do
      plan =
        adopt!(DayPlan.new(), "R3-r1", 4, 731, :day, 0)
        |> DayPlan.record_activity("guard_hut", 4, 750)

      %{wants: wants} = checked!("R3-r1")

      assert %{intents: intents, wants: ^wants} = DayPlan.column(plan, 4, 16 * 60 + 30)

      assert intents == [
               %{activity: "guard_hut", times: 1, done: 1, by: 13 * 60, status: :done},
               %{activity: "visit_plaza", times: 1, done: 0, by: 16 * 60, status: :missed},
               %{activity: "visit_plaza", times: 1, done: 0, by: 21 * 60, status: :open}
             ]

      # 更早的此刻（11:40）：做完的仍是 :done，没做的两条都还没到时限，是 :open。
      assert Enum.map(DayPlan.column(plan, 4, 700).intents, & &1.status) == [:done, :open, :open]
    end

    test "计划是前一天的：不出昨天的意图，wants 仍给（直到下一次规划换掉）" do
      plan = adopt!(DayPlan.new(), "R3-r1", 4, 731, :day, 0)
      assert %{intents: [], wants: wants} = DayPlan.column(plan, 5, 100)
      assert wants == plan["wants"]
    end

    test "只有意图没有 wants、或只有 wants 没有意图，都不是 nil" do
      {:ok, only_intents} = check_variant("R3-r1", &Map.put(&1, "cannot_yet", []))
      plan = DayPlan.adopt(DayPlan.new(), 4, 731, only_intents, :day, 0)
      assert %{wants: [], intents: [_ | _]} = DayPlan.column(plan, 4, 731)

      {:ok, only_wants} = check_variant("R3-r1", &Map.put(&1, "intents", []))
      plan = DayPlan.adopt(DayPlan.new(), 4, 731, only_wants, :day, 0)
      assert %{wants: [_ | _], intents: []} = DayPlan.column(plan, 4, 731)
    end
  end
end
