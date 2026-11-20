Code.require_file("../support/life_fixtures.exs", __DIR__)

defmodule NpcServer.NpcLifeTasksIntegrationTest do
  @moduledoc """
  只测试（真实模块集成，任务层决策稿 `docs/10-active/cross-cutting/2026-11-19-npc-long-task-loop-decision.md` §5 K-5 的 T-1a 部分）：
  任务接进 Life——每日回顾的真实应答开出带 id 的任务并落进持久行 `"tasks"`；活动结局按 K-3 表记账（前移 / 待推进 / 打断只记 log）；
  任务里的人对我说话（对别人说、我旁听的不算）、`kind:event` 落在任务里的人身上 → 待推进；`Life.mind/2` 给 Mind 的 `tasks`；重启读回；
  任务里点名过的人不在场、不在关系里时，回顾词表仍能点名他；过了到期日关为 expired；回顾的用户消息带开着的 / 最近关掉的任务两块（每行带 id）。推进（写作、采用、额度、花费闸门）属 T-1b，不在这里。

  层次与依赖（`../Voxim/Docs/Testing.md` §2.2）：真实 Life、真实 `DataService.NpcMemory`（本 VM 独占的 PostgreSQL）、真实 World
  （`NpcWorld.start/0`；`kind:event` 由 `LifeFixtures.damage/4` 经 World 正式入口做出）。替身三处，同 `npc_life_day_plan_integration_test`：
  Hindsight 适配器（召回回放真实条目）、写作（`profile.write_journal`：回顾的应答回放 K-0 复测里 DeepSeek 的真实应答
  `fixtures/day_plan/review-R1-r1.json`，反思写作一律给写作接口真实形状的失败）、Life 的时钟（Agent，测试拨动以跨过最小间隔）。
  活动经历经 Selector 的产品函数做出（`LifeFixtures.ended/3`）。

  **与决策稿 §5 K-5 的偏差**（统筹 2026-11-19 定）：稿件写真实 Registry / Body / Scene；这里与日计划集成测试同一组合，Life 直接起、
  测试自己发观察（`Life.observation/2`，Runtime 走的同一个入口）。原因：Runtime 写进观察的游戏钟取墙钟、没有可注入的缝，回放的
  真实应答里意图的时限（13:30 起）与开任务的日号要对得上那份材料的此刻（第 1418 日 13:00）。候选这一环 T-1 没有改动（K-6 不占位，
  候选与经历由 `npc_selector_test` / `npc_offers_integration_test` 已证），所以不需要 Runtime。

  前提：观察是 S1-X2 第 4 轮那一刻的真实原始观察（`ReflectionFixtures.rawobs/1`），游戏钟换成第 1418 日、附近站着 Corvin
  （cid `1906495721474`、8.9 米，同 K-0 复测 R1 的材料：回放的应答点名的就是这个显示名）。`event` 一条用例要 Corvin 恰是
  `damage/4` 的出手者（出手者固定是 NPC 的 cid + 10），所以那条用例 NPC 取 cid `1906495721464`（独占库里只有它用这个 cid）。
  `confront_wrecker` 沿用 K-0 复测当时的词表（`fixtures/day_plan/activities.json`），在这里是**静态种类**；部署里它已是可点名人的种类
  （对人的登记项由生成器按人展开），所以“没点名的当头步收到点名的经历”那条路径只由 `npc_life_tasks_test` 的单测覆盖。
  不证明：真实模型写什么（K-0）、推进（T-1b）、Jev 会不会选任务步（实跑）。
  """
  use ExUnit.Case, async: false
  import NpcServer.LifeFixtures, only: [damage: 4, ended: 3, reflect_profile: 3]
  import NpcServer.ReflectionFixtures, only: [rawobs: 1]
  alias NpcServer.{Life, NpcWorld}
  alias NpcServer.Life.Tasks

  @plan_fixtures Path.expand("../support/fixtures/day_plan", __DIR__)
  # 两次规划调用的最小间隔（3 分钟）再多 1 毫秒。
  @gap_ms 3 * 60_000 + 1
  # K-0 复测 R1 的此刻：第 1418 日 13:00。
  @day 1418
  @minute 780
  @corvin 1_906_495_721_474
  # Corvin 旁听那句话的对象：另一个人（不是我）。
  @bystander 1_906_495_721_480

  setup_all do
    MmoTest.Database.start!()
    :ok
  end

  @tag timeout: 60_000
  test "新行带空的 tasks；旧行（没有 tasks 键）加载时补成空的一份，随下一次保存落库" do
    %{cid: cid, profile: profile} = start()

    assert {:ok, %{tasks: %{row: row}}} = Life.observe(cid)
    assert row == Tasks.new()
    assert stored(cid)["tasks"] == Tasks.new()

    stop_supervised!({:life, cid})
    old = Map.delete(stored(cid), "tasks")
    :ok = DataService.NpcMemory.put(cid, "life", "state", old)
    life = start_life(cid, profile)

    assert {:ok, %{tasks: %{row: row}}} = Life.observe(cid)
    assert row == Tasks.new()

    # 下一次保存（一条活动经历）把补齐的键落库，其余不变。
    Life.activity(life, finished(profile, "visit_plaza", :completed))
    NpcWorld.await(fn -> stored(cid)["tasks"] != nil end)
    assert stored(cid)["tasks"] == Tasks.new()
  end

  @tag timeout: 90_000
  test "回顾的真实应答开出两个任务；结局按 K-3 记账；Corvin 来话待推进；重启读回；过了到期日关为 expired，下一次回顾带关掉的一块" do
    %{cid: cid, life: life, clock: clock, profile: profile} = start()

    # —— 第 1418 日 13:00，Corvin 在场：起 :day 回顾。系统提示词与 K-0 复测 R1 真实发出的逐字节相同（同一人格卡、同一词表：
    # 六个静态种类、点名 Corvin 的说话、进食、合成），用户消息没有任务块。
    frame(life, @day, @minute)
    {worker, system, user} = await_review_write()
    assert system == fixture("review-request-R1.json")["system"]
    refute user =~ "My open tasks"
    refute user =~ "Tasks I closed recently"
    assert String.ends_with?(user, "\n\nPlan the rest of today now.")

    reply(worker, "R1-r1")
    tasks = await_tasks(cid, &(length(&1["open"]) == 2))

    answer = fixture("review-R1-r1.json")["text"] |> Jason.decode!()
    [rebuild, ask] = answer["tasks"]["open"]

    assert [
             %{"id" => "t1418:1", "goal" => goal1, "steps" => steps1, "expires_day" => 1420},
             %{"id" => "t1418:2", "goal" => goal2, "steps" => steps2}
           ] = tasks["open"]

    assert goal1 == rebuild["goal"] and goal2 == ask["goal"]
    assert Enum.map(steps1, & &1["kind"]) == ~w(gather_stone build_hut guard_hut)

    assert Enum.map(steps2, &{&1["kind"], &1["object"]}) ==
             [{"confront_wrecker", nil}, {"speak_to", %{"actor" => @corvin}}]

    # 意图照日计划落行；开任务各写一句经历进未封存的尾部（带任务里的人）。
    assert {:ok, %{plan: %{row: %{"intents" => intents}}}} = Life.observe(cid)
    assert length(intents) == 5

    assert [
             %{"text" => ~s|I set myself a task: "#{goal1}".|, "tags" => ["kind:task"]},
             %{
               "text" => ~s|I set myself a task: "#{goal2}".|,
               "tags" => ["kind:task", "actor:#{@corvin}"]
             }
           ] == Enum.map(task_episodes(cid), &Map.take(&1, ["text", "tags"]))

    # 给 Mind 的栏（心智快照的 Plans and promises 用它）。
    assert {:ok, %{tasks: column}} = Life.mind(cid, [])
    assert column == Tasks.column(tasks)

    assert [%{next: %{"kind" => "gather_stone"}}, %{next: %{"kind" => "confront_wrecker"}}] =
             column

    # —— 活动结局（Selector 的产品函数做出的经历）：confront_wrecker 完成 → 任务 2 前移、不待推进；
    # gather_stone 被打断 → 只记 log；再失败 `exhausted` → 任务 1 待推进 failed，log 带动作与原因。
    Life.activity(life, finished(profile, "confront_wrecker", :completed))
    Life.activity(life, finished(profile, "gather_stone", {:interrupted, "to talk with Corvin"}))
    Life.activity(life, finished(profile, "gather_stone", {:failed, "gather", "exhausted"}))

    tasks = await_tasks(cid, &(length(task(&1, "t1418:1")["log"]) == 2))
    first = task(tasks, "t1418:1")
    second = task(tasks, "t1418:2")

    assert %{"waiting" => "failed", "head_failures" => 1, "completed" => 0} = first

    assert Enum.map(first["log"], &Map.take(&1, ~w(kind outcome act reason))) == [
             %{
               "kind" => "gather_stone",
               "outcome" => "interrupted",
               "act" => nil,
               "reason" => "to talk with Corvin"
             },
             %{
               "kind" => "gather_stone",
               "outcome" => "failed",
               "act" => "gather",
               "reason" => "exhausted"
             }
           ]

    assert %{"waiting" => nil, "completed" => 1} = second
    assert [%{"kind" => "speak_to"}] = second["steps"]

    # —— Corvin 对别人说话（我只是旁听）：经历照常接纳，任务不待推进（K-3 原文“对我说话”，同 `Dialogue.direct?/2`）。
    Life.speech(life, speech(80, @bystander, "Stay away from my stones."))
    NpcWorld.await(fn -> "speech:80:1" in Enum.map(episodes(cid), & &1["id"]) end)
    assert task(stored(cid)["tasks"], "t1418:2")["waiting"] == nil

    # —— Corvin 对我说话（任务 2 点名的人）：待推进 heard。
    Life.speech(life, speech(81, cid, "I had my reasons for the hut."))
    tasks = await_tasks(cid, &(task(&1, "t1418:2")["waiting"] == "heard"))
    assert stored(cid)["tasks"] == tasks

    # —— 重启：持久行是权威，任务原样读回。
    stop_supervised!({:life, cid})
    life = start_life(cid, profile)
    assert {:ok, %{tasks: %{row: ^tasks}}} = Life.observe(cid)

    # —— 第 1419 日的 :day 回顾：任务未到期，帧里没有 Corvin，他也不在关系里；说话一行仍能点名他（开着的任务里点名过的人，
    # K-0 评审第 8 条），观察里没有名字，显示名写 `actor <cid>`。
    assert stored(cid)["state"]["relationships"] == %{}
    advance(clock, @gap_ms)
    frame(life, @day + 1, 600, [])
    {worker, system, _user} = await_review_write()

    assert system =~
             "\n- speak_to: Walk up to someone and say one thing to them. " <>
               ~s|Optionally add "object": exactly one of "actor #{@corvin}".\n|

    send(worker, {:reply, {:error, :timeout}})

    NpcWorld.await(fn ->
      match?(
        {:ok, %{plan: %{running: false, row: %{"last" => %{"result" => "failed"}}}}},
        Life.observe(cid)
      )
    end)

    # —— 过了到期日（第 1421 日）：两个任务都关为 expired，各写一句经历；当日的回顾随之起，用户消息带“最近关掉的任务”。
    advance(clock, @gap_ms)
    frame(life, @day + 3, 600)
    {worker, _system, user} = await_review_write()

    tasks = await_tasks(cid, &(&1["open"] == []))

    assert Enum.map(tasks["closed"], &{&1["id"], &1["result"]}) ==
             [{"t1418:1", "expired"}, {"t1418:2", "expired"}]

    assert ~s|I did not finish my task "#{goal1}" in time, so I let it go.| in Enum.map(
             task_episodes(cid),
             & &1["text"]
           )

    assert user =~
             "\n\nTasks I closed recently:\n- t1418:1: #{goal1} — ran out of time\n" <>
               "- t1418:2: #{goal2} — ran out of time\n\nPlan the rest of today now."

    refute user =~ "My open tasks"
    send(worker, {:reply, {:error, :timeout}})
  end

  @tag timeout: 90_000
  test "kind:event 的出手者是任务里的人：待推进 event；事件重排的用户消息带开着的任务一块，每行带 id" do
    %{cid: cid, life: life, clock: clock, fixture: fixture} = start(cid: @corvin - 10)

    frame(life, @day, @minute)
    {worker, _system, _user} = await_review_write()
    reply(worker, "R1-r1")
    await_tasks(cid, &(length(&1["open"]) == 2))

    # Corvin（cid + 10）打掉我放的一格：Life 接纳成 kind:event；任务 2 点名了他 → 待推进 event；日计划记下等着重排。
    damage(fixture.world, cid, 1, {5, 64, 8})
    tasks = await_tasks(cid, &(task(&1, "t1418:2")["waiting"] == "event"))
    assert task(tasks, "t1418:1")["waiting"] == nil

    advance(clock, @gap_ms)
    frame(life, @day, @minute + 30)
    {worker, _system, user} = await_review_write()

    answer = fixture("review-R1-r1.json")["text"] |> Jason.decode!()
    [%{"goal" => goal1}, %{"goal" => goal2}] = answer["tasks"]["open"]

    assert user =~
             "\n\nMy open tasks (by id):\n" <>
               "- t1418:1: #{goal1} — next: gather_stone; nothing done yet\n" <>
               "- t1418:2: #{goal2} — next: confront_wrecker; nothing done yet\n\n" <>
               "Plan the rest of today now."

    send(worker, {:reply, {:error, :timeout}})
    assert {:ok, %{plan: %{row: %{"calls" => %{"n" => 2}}}}} = Life.observe(cid)
  end

  # —— 夹具 ——

  # 起一个开着规划、配了说话的 Life（同 `npc_life_day_plan_integration_test` 的 `planning/1`）：真实 World 与 NpcMemory，
  # 时钟是测试拨动的 Agent；起好之后先接纳一条活动经历（规划要求有过经历）。`cid:` 指定永久 cid。
  defp start(opts \\ []) do
    test = self()
    fixture = NpcWorld.start()
    cid = Keyword.get_lazy(opts, :cid, fn -> System.unique_integer([:positive]) + 100_000 end)

    clock =
      start_supervised!(
        Supervisor.child_spec({Agent, fn -> System.system_time(:millisecond) end},
          id: {:clock, cid}
        )
      )

    profile =
      test
      |> reflect_profile(%{clock: fn -> Agent.get(clock, & &1) end}, DataService.NpcMemory)
      |> Map.merge(%{activities: activities(), skills: %{speak: %{}}})

    life = start_life(cid, profile)
    Life.activity(life, finished(profile, "visit_plaza", :completed))
    assert {:ok, %{pending_episodes: 1}} = Life.observe(cid)
    %{fixture: fixture, cid: cid, clock: clock, profile: profile, life: life}
  end

  defp start_life(cid, profile) do
    context = %{cid: cid, name: nil, scene_id: 1, router: NpcWorld.Route}

    life =
      start_supervised!(%{
        id: {:life, cid},
        start: {Life, :start_link, [self(), context, profile]}
      })

    NpcWorld.await(fn -> match?({:ok, %{cache: %{}, job: nil}}, Life.observe(cid)) end)
    life
  end

  # 一帧观察：S1-X2 第 4 轮那一刻的真实原始观察，附近只有 Corvin（8.9 米，同 K-0 复测 R1 的材料），游戏钟换成给定的日号与分钟。
  # 给 `entities: []` 时附近没有人（Corvin 走开了）。
  defp frame(life, day, minute, entities \\ nil) do
    observation = rawobs(4)
    {x, y, z} = observation.self.position

    corvin = %{
      entity_id: @corvin,
      entity_epoch: 1,
      kind: 1,
      name: "Corvin",
      position: {x + 8.9, y, z}
    }

    Life.observation(life, %{
      observation
      | entities: entities || [corvin],
        world_time: %{observation.world_time | day: day, minute_of_day: minute}
    })
  end

  # Corvin 在会话 `conversation` 里对 `target` 说的一句话（Scene 交给 Life 的说话消息的形状，同 `npc_dialogue_life_test`；
  # Scene 把附近的公开说话也交给旁听者，`target` 不是我时我只是旁听）。
  defp speech(conversation, target, text),
    do: %{
      conversation_id: conversation,
      turn: 1,
      speaker_id: @corvin,
      speaker_epoch: 1,
      speaker_kind: 1,
      speaker_name: "Corvin",
      target_id: target,
      at_ms: System.system_time(:millisecond),
      text: text
    }

  # 等下一次回顾写作，返回 `{worker, 系统提示词, 用户消息}`；途中到来的反思写作一律给写作接口真实形状的失败。
  defp await_review_write do
    receive do
      {:write, worker, system, user} ->
        if String.contains?(system, "It is time to plan the rest of today.") do
          {worker, system, user}
        else
          send(worker, {:reply, {:error, :timeout}})
          await_review_write()
        end
    after
      10_000 -> flunk("没有收到回顾写作")
    end
  end

  defp reply(worker, name),
    do: send(worker, {:reply, {:ok, %{text: fixture("review-#{name}.json")["text"], usage: %{}}}})

  defp await_tasks(cid, ready) do
    NpcWorld.await(
      fn ->
        case Life.observe(cid) do
          {:ok, %{tasks: %{row: row}}} -> ready.(row) && row
          _ -> false
        end
      end,
      15_000
    )
  end

  defp task(tasks, id), do: Enum.find(tasks["open"], &(&1["id"] == id))
  defp stored(cid), do: DataService.NpcMemory.get(cid, "life", "state")

  # 持久行里还没写进 Hindsight 的经历（已封存待写的片段与未封存的尾部），旧在前。
  defp episodes(cid) do
    row = stored(cid)
    Enum.flat_map(row["fragments"], & &1["episodes"]) ++ row["pending"]
  end

  defp task_episodes(cid), do: Enum.filter(episodes(cid), &("kind:task" in &1["tags"]))

  defp finished(profile, name, result),
    do:
      ended(
        profile,
        Enum.find(NpcServer.Offers.registered(profile.activities, []), &(&1.name == name)),
        result
      )

  defp advance(clock, ms), do: Agent.update(clock, &(&1 + ms))
  defp fixture(name), do: Path.join(@plan_fixtures, name) |> File.read!() |> Jason.decode!()

  # 候选表：S1-R7 的候选（`fixtures/day_plan/activities.json`），形状同注册表构造的候选。
  defp activities do
    for %{"name" => name, "criterion" => criterion} <- fixture("activities.json"),
        do: %{name: name, criterion: criterion, place_name: nil}
  end
end
