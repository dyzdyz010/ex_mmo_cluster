Code.require_file("../support/reflection_fixtures.exs", __DIR__)

defmodule NpcServer.NpcLifeDayPlanRoundTest do
  @moduledoc """
  只测试：规划槽的流程 `NpcServer.Life.DayPlan.Round`（不起 Life、不起 World、不连库）与规划用户消息里“今天的意图”各行的渲染
  `Mind.plan_intent_line/2`。稿 A 批 0b：快照的 `vocabulary`（种类 + 展开后的对象）由 Round 渲染进系统提示词，
  有对象的种类在判据后接一句可选对象。任务层 T-1a 起日计划退化为每日回顾：系统提示词是 `Prompt.review_system_prompt/2`，
  检查是回顾的唯一校验点 `Tasks.check/3`（`{:review, now_minute, 开着的任务}`），结果多 `tasks`；用户消息可多开着的 / 关掉的任务两块。

  输入是真实导出：“此刻”取 S1-X2 第 4 轮那一刻的原始观察，召回回放那一轮两次召回的真实条目，“之前的想法”是那一轮之前的真实日记
  （`test/support/fixtures/reflection/`）；词表是 S1-R7 的候选（`fixtures/day_plan/activities.json`），写作接口回放 K-0 复测里回顾模型的
  真实应答（`fixtures/day_plan/review-R1-r*.json`；S1-R8 的应答没有 `tasks` 键，补一个空的才合格）或写作接口真实形状的失败
  （`Writer.write/3` 的 `:timeout`）。替身两处：Hindsight 适配器
  （召回回放真实条目，或返回适配器真实形状的失败）与写作函数（把系统提示词与用户消息交给测试进程）。
  证明：取材走“自己”一问的路径（两次召回、自己那条之前的日记、其它对象的日记）；提示词是 `Prompt` 的产物；只写一次、不重问；
  检查的此刻是快照里的 `now_minute`；三种结局与 usage；`wrote`（写作函数被调用过为真，含写作失败与被拒；在它之前失败为假）
  与 `end` 日志里的 `wrote=`；日志不带计划原文。
  不证明：Life 起槽、落栏与触发（`npc_life_day_plan_integration_test.exs`）；真实模型与真实 Hindsight。
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import NpcServer.ReflectionFixtures
  alias NpcServer.Life.{DayPlan, Tasks}
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
    test "写成：取材走“自己”一问，提示词是回顾模板，只写一次，检查通过给出意图、wants 与开的任务，usage 原样" do
      # K-0 复测 R1-r2（13:00）：四条意图、一条 cannot_yet、一个不点名的任务。
      sample = review_sample("R1-r2")
      usage = json("gateway-response.json")["usage"]
      snapshot = snapshot(sample, {:ok, %{text: sample["text"], usage: usage}})

      log = capture_log(fn -> send(self(), {:result, Round.write(snapshot)}) end)
      assert_received {:result, result}

      assert %{result: :ok, usage: ^usage, elapsed_ms: elapsed_ms, wrote: true} = result
      assert is_integer(elapsed_ms) and elapsed_ms >= 0

      assert {:ok, result.checked} ==
               Tasks.check(sample["text"], names(), {:review, sample["now_minute"], []})

      assert length(result.checked.intents) == 4 and length(result.checked.wants) == 1
      assert [%{"steps" => [_ | _]}] = result.checked.tasks.open

      assert_received {:write, system, user}
      refute_received {:write, _, _}
      assert system == Prompt.review_system_prompt(fixture("character.txt"), vocabulary())

      # “自己”一问：两路召回都不带 tags；之前的想法是自己那条与 Corvin 那条（此刻有关系的人）。
      assert_received {:recall, %{types: ["experience", "world"], tags: nil, tags_match: nil}}
      assert_received {:recall, %{types: ["observation"], tags: nil, tags_match: nil}}
      before = json("round4-before.json")

      assert user =~
               "\n\nWhat I thought before (my own earlier thoughts, not facts):\nAbout this: #{one_line(before["Q_self"])}\nAbout other things: #{one_line(before["Q_person"])}\n\nPlan the rest of today now."

      assert String.starts_with?(user, "Right now:\nIt is afternoon, 13:00. It is day 1346.\n")
      assert String.ends_with?(user, "\n\nPlan the rest of today now.")

      # 槽日志的输入数明确指普通输入；请求总量由模型用量事件记录。
      assert log =~ "npc_plan cid=#{snapshot.cid} event=start kind=day day=1346"

      assert log =~
               ~r/npc_plan cid=#{snapshot.cid} event=end kind=day day=1346 result=written intents=4 wants=1 tasks_open=1 tasks_drop=0 wrote=true .* uncached_input_tokens=2 output_tokens=747/

      for %{"why" => why} <- result.checked.intents, do: refute(log =~ why)
      for %{"goal" => goal} <- result.checked.tasks.open, do: refute(log =~ goal)
    end

    test "今天已有的意图、旧 wants、开着的与关掉的任务交进来：用户消息多四块" do
      sample = plan_sample("R2-r1")
      today = ["guard_hut: 1 of 1 done — finished", "visit_plaza: 0 of 1 done, by 23:30"]
      wants = ["Walk back past the hut"]
      open_tasks = ["- t1346:1: Rebuild my hut — next: gather_stone; nothing done yet"]
      closed_tasks = ["- t1345:1: Ask Corvin why — given up"]

      snapshot =
        %{
          snapshot(sample, {:ok, %{text: sample["text"], usage: nil}})
          | today: today,
            wants: wants,
            open_tasks: open_tasks,
            closed_tasks: closed_tasks
        }

      capture_log(fn -> Round.write(snapshot) end)
      assert_received {:write, _system, user}

      assert user =~
               "\n\nWhat I meant to do today, as it stands:\n#{Enum.join(today, "\n")}\n\nThings I wanted to do but could not yet:\nWalk back past the hut" <>
                 "\n\nMy open tasks (by id):\n#{hd(open_tasks)}\n\nTasks I closed recently:\n#{hd(closed_tasks)}\n\nPlan the rest of today now."
    end

    # 回顾里弃的 id 按快照里开着的任务核对（`Tasks.check/3` 的第三个参数取自快照的 `open`）。
    test "弃开着的任务：id 在快照的 open 里才合格" do
      sample = review_sample("R1-r2")

      text =
        sample["text"]
        |> Jason.decode!()
        |> put_in(["tasks", "drop"], ["t1345:1"])
        |> Jason.encode!()

      snapshot = snapshot(sample, {:ok, %{text: text, usage: nil}})
      open = [%{"id" => "t1345:1", "goal" => "Ask Corvin why", "steps" => []}]

      capture_log(fn -> send(self(), {:result, Round.write(%{snapshot | open: open})}) end)
      assert_received {:result, %{result: :ok, checked: %{tasks: %{drop: ["t1345:1"]}}}}

      capture_log(fn -> send(self(), {:result, Round.write(snapshot)}) end)
      assert_received {:result, %{result: {:rejected, {:unknown_task, "t1345:1"}}}}
    end

    # 稿 A 批 0b：词表里有对象的种类（说话，对象是人）渲染成系统提示词里的一行：判据后接
    # `Optionally add "object": exactly one of "<显示名>", ….`（显示名按字符串排序）；静态种类各行逐字节不变。
    # 两人取自 S1-X2 导出（`s1x2-moments.json` 的 names）。没有说话种类的真实模型应答，应答是按提示词格式写的一份
    # （批 0b 不调真实模型，离线重放另排）。
    test "有对象的种类：判据后接可选对象一句，其余逐字节不变；检查认得点名的人；没有可点名的人时不接这一句" do
      sample = plan_sample("R2-r1")
      %{"names" => names} = json("s1x2-moments.json")
      tobin_id = String.to_integer("1285994582019")
      corvin_id = String.to_integer("1011812929538")
      tobin = "#{names["1285994582019"]} (actor #{tobin_id})"
      corvin = "#{names["1011812929538"]} (actor #{corvin_id})"
      criterion = "Walk up to someone and say one thing to them."

      speak = %{
        kind: "speak_to",
        criterion: criterion,
        objects: %{tobin => %{"actor" => tobin_id}, corvin => %{"actor" => corvin_id}}
      }

      text =
        Jason.encode!(%{
          "intents" => [
            %{
              "activity" => "speak_to",
              "object" => tobin,
              "times" => 1,
              "by" => "23:00",
              "why" => "I want to answer Tobin about the hut."
            }
          ],
          "cannot_yet" => [],
          "tasks" => %{"open" => [], "drop" => []}
        })

      snapshot = %{
        snapshot(sample, {:ok, %{text: text, usage: nil}})
        | vocabulary: vocabulary() ++ [speak]
      }

      capture_log(fn -> send(self(), {:result, Round.write(snapshot)}) end)
      assert_received {:result, %{result: :ok, checked: %{intents: [intent], wants: []}}}
      assert intent["object"] == %{"actor" => tobin_id}

      assert_received {:write, system, _user}

      line =
        "\n- speak_to: #{criterion} " <>
          ~s|Optionally add "object": exactly one of "#{corvin}", "#{tobin}".|

      assert system =~ line <> "\n\nWrite down what you mean to do"

      assert String.replace(system, line, "") ==
               Prompt.review_system_prompt(fixture("character.txt"), vocabulary())

      # 此刻没有可点名的人：种类照列，判据后不接可选对象一句。
      empty = %{snapshot | vocabulary: vocabulary() ++ [%{speak | objects: %{}}]}
      capture_log(fn -> Round.write(empty) end)
      assert_received {:write, system, _user}

      assert system ==
               Prompt.review_system_prompt(
                 fixture("character.txt"),
                 vocabulary() ++ [%{speak | objects: %{}}]
               )

      refute system =~ "Optionally add"
    end

    test "检查不过（K-0 复测 R1-r3：意图 5 条加 cannot_yet 1 条）：被拒，checked 为 nil，usage 照给，不重问" do
      sample = review_sample("R1-r3")
      snapshot = snapshot(sample, {:ok, %{text: sample["text"], usage: %{"output_tokens" => 1}}})

      log = capture_log(fn -> send(self(), {:result, Round.write(snapshot)}) end)
      assert_received {:result, result}

      assert %{
               result: {:rejected, {:too_many_items, 6}},
               checked: nil,
               usage: %{"output_tokens" => 1},
               wrote: true
             } =
               result

      assert_received {:write, _, _}
      refute_received {:write, _, _}
      assert log =~ "result=rejected reason={:too_many_items, 6} wrote=true"
    end

    test "写作失败（写作函数被调用之后才失败）：失败、usage 为 nil，算发出了写作（wrote 为真），不重问" do
      sample = plan_sample("R2-r1")

      log =
        capture_log(fn ->
          send(self(), {:result, Round.write(snapshot(sample, {:error, :timeout}))})
        end)

      assert_received {:result,
                       %{result: {:failed, :timeout}, checked: nil, usage: nil, wrote: true}}

      assert_received {:write, _, _}
      refute_received {:write, _, _}
      assert log =~ "result=failed reason=:timeout wrote=true"
    end

    test "召回失败：失败，不发写作请求（wrote 为假）" do
      sample = plan_sample("R2-r1")
      snapshot = put_in(snapshot(sample, {:error, :timeout}).config.replay, :fail)

      log = capture_log(fn -> send(self(), {:result, Round.write(snapshot)}) end)

      assert_received {:result,
                       %{result: {:failed, {:http_status, 503}}, usage: nil, wrote: false}}

      refute_received {:write, _, _}
      assert log =~ "result=failed reason={:http_status, 503} wrote=false"
    end

    test "身体状态还没收到：失败（:no_body_state），不召回、不写（wrote 为假）" do
      sample = plan_sample("R2-r1")
      snapshot = snapshot(sample, {:error, :timeout})
      snapshot = put_in(snapshot.observation.self.body_state, nil)

      capture_log(fn -> send(self(), {:result, Round.write(snapshot)}) end)
      assert_received {:result, %{result: {:failed, :no_body_state}, wrote: false}}
      refute_received {:recall, _}
      refute_received {:write, _, _}
    end
  end

  describe "Mind.plan_intent_line/2" do
    test "三种状态的写法；by 写成两位的 HH:MM；没有对象时与批 0b 之前逐字相同" do
      assert Mind.plan_intent_line(
               %{
                 activity: "visit_plaza",
                 object: nil,
                 times: 2,
                 done: 1,
                 by: 18 * 60,
                 status: :open
               },
               %{}
             ) ==
               "visit_plaza: 1 of 2 done, by 18:00"

      assert Mind.plan_intent_line(
               %{
                 activity: "guard_hut",
                 object: nil,
                 times: 1,
                 done: 1,
                 by: 8 * 60 + 5,
                 status: :done
               },
               %{}
             ) ==
               "guard_hut: 1 of 1 done — finished"

      assert Mind.plan_intent_line(
               %{activity: "guard_hut", object: nil, times: 3, done: 0, by: 7, status: :missed},
               %{}
             ) ==
               "guard_hut: 0 of 3 done — not finished by 00:07"
    end

    # 稿 A 批 0b：点名的人按名字层 `Life.State.person/2` 写在种类之后（`names` 里有就是 `名字 (actor <cid>)`，没有就是
    # `actor <cid>`），其余写法不变。这行的写法是原创取值，没有离线测过。
    test "有对象：种类后接点名的人；names 里没有这个人时写 actor <cid>" do
      intent = %{
        activity: "speak_to",
        object: %{"actor" => 9},
        times: 1,
        done: 0,
        by: 15 * 60,
        status: :open
      }

      assert Mind.plan_intent_line(intent, %{9 => "Tobin"}) ==
               "speak_to Tobin (actor 9): 0 of 1 done, by 15:00"

      assert Mind.plan_intent_line(intent, %{}) == "speak_to actor 9: 0 of 1 done, by 15:00"

      assert Mind.plan_intent_line(%{intent | done: 1, status: :done}, %{9 => ""}) ==
               "speak_to someone unnamed (actor 9): 1 of 1 done — finished"
    end

    test "DayPlan.column/3 的产物逐条渲染（S1-R8 R3-r1 的计划）" do
      sample = plan_sample("R3-r1")

      {:ok, checked} =
        Tasks.check(review_text(sample["text"]), names(), {:review, sample["now_minute"], []})

      plan = DayPlan.adopt(DayPlan.new(), 9, sample["now_minute"], checked, :day, 0)
      plan = DayPlan.record_activity(plan, {"guard_hut", nil}, 9, 770)

      assert Enum.map(DayPlan.column(plan, 9, 1000).intents, &Mind.plan_intent_line(&1, %{})) == [
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
      vocabulary: vocabulary(),
      today: [],
      wants: [],
      open: [],
      open_tasks: [],
      closed_tasks: [],
      write: fn system, user ->
        send(test, {:write, system, user})
        reply
      end
    }
  end

  defp plan_sample(name),
    do: Path.join(@plan_fixtures, "s1r8-#{name}.json") |> File.read!() |> Jason.decode!()

  # K-0 复测里回顾模型的真实应答（`text`、此刻 `now_minute`）。
  defp review_sample(name),
    do: Path.join(@plan_fixtures, "review-#{name}.json") |> File.read!() |> Jason.decode!()

  # S1-R8 的真实正文没有 `tasks`（那时还没有任务层）：补一个空的（模型产得出的形状）。
  defp review_text(text),
    do:
      text
      |> Jason.decode!()
      |> Map.put("tasks", %{"open" => [], "drop" => []})
      |> Jason.encode!()

  # Life 起槽时交进快照的词表（稿 A 批 0b）：`Offers.plan_kinds/1` 的种类，对象已展开成 `%{显示名 => 对象}`、按种类次序。
  # S1-R7 的六个候选各是一个静态种类（没有对象）。
  defp vocabulary do
    for %{"name" => name, "criterion" => criterion} <-
          Path.join(@plan_fixtures, "activities.json") |> File.read!() |> Jason.decode!(),
        do: %{kind: name, criterion: criterion, objects: %{}}
  end

  # 检查用的词表：`%{种类 => %{显示名 => 对象}}`。
  defp names, do: Map.new(vocabulary(), &{&1.kind, &1.objects})

  # 用户消息里之前的日记各压成一行（同 `Reflection.materials_blocks/1`）。
  defp one_line(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()
end
