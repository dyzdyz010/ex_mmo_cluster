Code.require_file("../support/reflection_fixtures.exs", __DIR__)

defmodule NpcServer.NpcLifeDayPlanRoundTest do
  @moduledoc """
  只测试：规划槽的流程 `NpcServer.Life.DayPlan.Round`（不起 Life、不起 World、不连库）与规划用户消息里“今天的意图”各行的渲染
  `Mind.plan_intent_line/1`。

  输入是真实导出：“此刻”取 S1-X2 第 4 轮那一刻的原始观察，召回回放那一轮两次召回的真实条目，“之前的想法”是那一轮之前的真实日记
  （`test/support/fixtures/reflection/`）；词表是 S1-R7 的候选（`fixtures/day_plan/activities.json`），写作接口回放 S1-R8 规划模型的
  真实应答（`fixtures/day_plan/s1r8-*.json`）或写作接口真实形状的失败（`Writer.write/3` 的 `:timeout`）。替身两处：Hindsight 适配器
  （召回回放真实条目，或返回适配器真实形状的失败）与写作函数（把系统提示词与用户消息交给测试进程）。
  证明：取材走“自己”一问的路径（两次召回、自己那条之前的日记、其它对象的日记）；提示词是 `Prompt` 的产物；只写一次、不重问；
  检查的此刻是快照里的 `now_minute`；三种结局与 usage；日志不带计划原文。
  不证明：Life 起槽、落栏与触发（`npc_life_day_plan_integration_test.exs`）；真实模型与真实 Hindsight。
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import NpcServer.ReflectionFixtures
  alias NpcServer.Life.DayPlan
  alias NpcServer.Life.DayPlan.{Prompt, Round}
  alias NpcServer.Mind

  @plan_fixtures Path.expand("../support/fixtures/day_plan", __DIR__)

  defmodule Hindsight do
    @moduledoc "只测试：召回按这一路的 types 回放第 4 轮 Q_place 那一次召回的真实条目；`config.replay` 为 `:fail` 时返回适配器真实形状的失败。"
    alias NpcServer.ReflectionFixtures

    def recall(config, description, _now_ms) do
      send(config.owner, {:recall, description})

      case config.replay do
        :fail ->
          {:error, {:http_status, 503}}

        :by_types ->
          kind = if description.types == ["observation"], do: "observation", else: "raw"
          {:ok, %{results: ReflectionFixtures.recalled(kind), latency_ms: 1}}
      end
    end
  end

  # 用例断言规划槽的 info 日志；全局日志级别会被别的用例改成 :warning，这里只放开本模块。
  setup_all do
    Logger.put_module_level(Round, :info)
    on_exit(fn -> Logger.delete_module_level(Round) end)
  end

  describe "write/1" do
    test "写成：取材走“自己”一问，提示词是 Prompt 的产物，只写一次，检查通过给出意图与 wants，usage 原样" do
      sample = plan_sample("R2-r1")
      usage = json("gateway-response.json")["usage"]
      snapshot = snapshot(sample, {:ok, %{text: sample["text"], usage: usage}})

      log = capture_log(fn -> send(self(), {:result, Round.write(snapshot)}) end)
      assert_received {:result, result}

      assert %{result: :ok, usage: ^usage, elapsed_ms: elapsed_ms} = result
      assert is_integer(elapsed_ms) and elapsed_ms >= 0
      assert {:ok, result.checked} == DayPlan.check(sample["text"], names(), sample["now_minute"])
      assert length(result.checked.intents) == 2 and length(result.checked.wants) == 1

      assert_received {:write, system, user}
      refute_received {:write, _, _}
      assert system == Prompt.system_prompt(fixture("character.txt"), activities())

      # “自己”一问：两路召回都不带 tags；之前的想法是自己那条与 Corvin 那条（此刻有关系的人）。
      assert_received {:recall, %{types: ["experience", "world"], tags: nil, tags_match: nil}}
      assert_received {:recall, %{types: ["observation"], tags: nil, tags_match: nil}}
      before = json("round4-before.json")

      assert user =~
               "\n\nWhat I thought before (my own earlier thoughts, not facts):\nAbout this: #{one_line(before["Q_self"])}\nAbout other things: #{one_line(before["Q_person"])}\n\nPlan the rest of today now."

      assert String.starts_with?(user, "Right now:\nIt is night, 22:26. It is day 1346.\n")
      assert String.ends_with?(user, "\n\nPlan the rest of today now.")

      # 日志：起止各一行，带 kind、day、结局、耗时与 token；计划原文（why）不进日志。
      assert log =~ "npc_plan cid=#{snapshot.cid} event=start kind=day day=1346"

      assert log =~
               ~r/npc_plan cid=#{snapshot.cid} event=end kind=day day=1346 result=written .*input_tokens=2 output_tokens=747/

      for %{"why" => why} <- result.checked.intents, do: refute(log =~ why)
    end

    test "今天已有的意图与旧 wants 交进来：用户消息多两块" do
      sample = plan_sample("R2-r1")
      today = ["guard_hut: 1 of 1 done — finished", "visit_plaza: 0 of 1 done, by 23:30"]
      wants = ["Walk back past the hut"]

      snapshot =
        %{
          snapshot(sample, {:ok, %{text: sample["text"], usage: nil}})
          | today: today,
            wants: wants
        }

      capture_log(fn -> Round.write(snapshot) end)
      assert_received {:write, _system, user}

      assert user =~
               "\n\nWhat I meant to do today, as it stands:\n#{Enum.join(today, "\n")}\n\nThings I wanted to do but could not yet:\nWalk back past the hut\n\nPlan the rest of today now."
    end

    test "检查不过（S1-R8 R1-r1：6 条）：被拒，checked 为 nil，usage 照给，不重问" do
      sample = plan_sample("R1-r1")
      snapshot = snapshot(sample, {:ok, %{text: sample["text"], usage: %{"output_tokens" => 1}}})

      log = capture_log(fn -> send(self(), {:result, Round.write(snapshot)}) end)
      assert_received {:result, result}

      assert %{
               result: {:rejected, {:too_many_items, 6}},
               checked: nil,
               usage: %{"output_tokens" => 1}
             } =
               result

      assert_received {:write, _, _}
      refute_received {:write, _, _}
      assert log =~ "result=rejected reason={:too_many_items, 6}"
    end

    test "写作失败：失败、usage 为 nil，不重问" do
      sample = plan_sample("R2-r1")

      log =
        capture_log(fn ->
          send(self(), {:result, Round.write(snapshot(sample, {:error, :timeout}))})
        end)

      assert_received {:result, %{result: {:failed, :timeout}, checked: nil, usage: nil}}
      assert_received {:write, _, _}
      refute_received {:write, _, _}
      assert log =~ "result=failed reason=:timeout"
    end

    test "召回失败：失败，不发写作请求" do
      sample = plan_sample("R2-r1")
      snapshot = put_in(snapshot(sample, {:error, :timeout}).config.replay, :fail)

      capture_log(fn -> send(self(), {:result, Round.write(snapshot)}) end)
      assert_received {:result, %{result: {:failed, {:http_status, 503}}, usage: nil}}
      refute_received {:write, _, _}
    end

    test "身体状态还没收到：失败（:no_body_state），不召回、不写" do
      sample = plan_sample("R2-r1")
      snapshot = snapshot(sample, {:error, :timeout})
      snapshot = put_in(snapshot.observation.self.body_state, nil)

      capture_log(fn -> send(self(), {:result, Round.write(snapshot)}) end)
      assert_received {:result, %{result: {:failed, :no_body_state}}}
      refute_received {:recall, _}
      refute_received {:write, _, _}
    end
  end

  describe "Mind.plan_intent_line/1" do
    test "三种状态的写法；by 写成两位的 HH:MM" do
      assert Mind.plan_intent_line(%{
               activity: "visit_plaza",
               times: 2,
               done: 1,
               by: 18 * 60,
               status: :open
             }) ==
               "visit_plaza: 1 of 2 done, by 18:00"

      assert Mind.plan_intent_line(%{
               activity: "guard_hut",
               times: 1,
               done: 1,
               by: 8 * 60 + 5,
               status: :done
             }) ==
               "guard_hut: 1 of 1 done — finished"

      assert Mind.plan_intent_line(%{
               activity: "guard_hut",
               times: 3,
               done: 0,
               by: 7,
               status: :missed
             }) ==
               "guard_hut: 0 of 3 done — not finished by 00:07"
    end

    test "DayPlan.column/3 的产物逐条渲染（S1-R8 R3-r1 的计划）" do
      sample = plan_sample("R3-r1")
      {:ok, checked} = DayPlan.check(sample["text"], names(), sample["now_minute"])
      plan = DayPlan.adopt(DayPlan.new(), 9, sample["now_minute"], checked, :day, 0)
      plan = DayPlan.record_activity(plan, "guard_hut", 9, 770)

      assert Enum.map(DayPlan.column(plan, 9, 1000).intents, &Mind.plan_intent_line/1) == [
               "guard_hut: 1 of 1 done — finished",
               "visit_plaza: 0 of 1 done — not finished by 16:00",
               "visit_plaza: 0 of 1 done, by 21:00"
             ]
    end
  end

  # 规划槽的快照（Life 起槽时取齐的那一份）：此刻是 S1-X2 第 4 轮那一刻的原始观察（第 1346 日），有关系的人是 Corvin，
  # 之前的日记是那一轮之前的三条；日内分钟取这份规划应答在 S1-R8 里的此刻（检查 `by` 严格晚于它）。
  defp snapshot(sample, reply) do
    test = self()
    %{"wrecker" => corvin, "names" => names, "self_cid" => cid} = json("s1x2-moments.json")
    before = json("round4-before.json")

    # 游戏钟的分钟换成这份应答在 S1-R8 里的此刻，此刻一块与检查用的是同一个时刻。
    observation = put_in(rawobs(4).world_time.minute_of_day, sample["now_minute"])

    %{
      cid: cid,
      kind: :day,
      day: observation.world_time.day,
      now_minute: sample["now_minute"],
      now_ms: iso_ms(Enum.at(json("s1x2-moments.json")["rounds"], 3)["now"]),
      observation: observation,
      recent: [],
      buildings: [],
      people: [corvin],
      names: names,
      latest: %{
        "place:small hut" => %{"journal" => before["Q_place"]},
        "person:#{corvin}" => %{"journal" => before["Q_person"]},
        "self" => %{"journal" => before["Q_self"]}
      },
      adapter: Hindsight,
      config: %{owner: test, replay: :by_types},
      context: %{cid: cid},
      character: fixture("character.txt"),
      activities: activities(),
      today: [],
      wants: [],
      write: fn system, user ->
        send(test, {:write, system, user})
        reply
      end
    }
  end

  defp plan_sample(name),
    do: Path.join(@plan_fixtures, "s1r8-#{name}.json") |> File.read!() |> Jason.decode!()

  defp activities do
    for %{"name" => name, "criterion" => criterion} <-
          Path.join(@plan_fixtures, "activities.json") |> File.read!() |> Jason.decode!(),
        do: %{name: name, criterion: criterion}
  end

  defp names, do: Enum.map(activities(), & &1.name)

  # 用户消息里之前的日记各压成一行（同 `Reflection.materials_blocks/1`）。
  defp one_line(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()
end
