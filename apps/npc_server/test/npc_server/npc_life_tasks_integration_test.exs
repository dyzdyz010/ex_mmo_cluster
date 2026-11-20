Code.require_file("../support/life_fixtures.exs", __DIR__)
Code.require_file("../support/http_stub.exs", __DIR__)

defmodule NpcServer.NpcLifeTasksIntegrationTest do
  @moduledoc """
  只测试（真实模块集成，任务层决策稿 `docs/10-active/cross-cutting/2026-11-19-npc-long-task-loop-decision.md` §5 K-5）：
  任务接进 Life——每日回顾的真实应答开出带 id 的任务并落进持久行 `"tasks"`；活动结局按 K-3 表记账（前移 / 待推进 / 打断只记 log）；
  任务里的人对我说话（对别人说、我旁听的不算）、`kind:event` 落在任务里的人身上 → 待推进；`Life.mind/2` 给 Mind 的 `tasks`；重启读回；
  任务里点名过的人不在场、不在关系里时，回顾词表仍能点名他；过了到期日关为 expired；回顾的用户消息带开着的 / 最近关掉的任务两块（每行带 id）。
  T-1b（推进）：步骤失败 → 推进（真实被拒的应答只计数、等待留着；再推进采用新步骤，新当头步进 Mind 的任务栏）→ 步骤用完 → 推进 done
  关闭并写经历 → 重启读回；花费到线时推进在记调用之前被拒、等待留着、当头步照常给 Mind，恢复后起推进、写作失败照扣额度；
  回顾与推进经真实写作接口（`Reflection.Writer` → 本机 HTTP 替身）发出的请求 `max_tokens` 都是 4096（K-9）。
  T-1b 评审修正：推进写作在途时当头步经真实活动做完，落栏的旧应答不采用（stale，步骤不换回）；回顾与推进同时到点时回顾先起，
  回顾没起成（当日额度用完、`skipped`）时推进照常起（T-1b 偏差②）。

  层次与依赖（`../Voxim/Docs/Testing.md` §2.2）：真实 Life、真实 `DataService.NpcMemory`（本 VM 独占的 PostgreSQL）、真实 World
  （`NpcWorld.start/0`；`kind:event` 由 `LifeFixtures.damage/4` 经 World 正式入口做出）。替身三处，同 `npc_life_day_plan_integration_test`：
  Hindsight 适配器（召回回放真实条目）、写作（`profile.write_journal`：回顾的应答回放 K-0 复测里 DeepSeek 的真实应答
  `fixtures/day_plan/review-R1-r1.json`，推进的应答回放 K-0 / K-0 复测的真实推进应答 `fixtures/tasks/advance-*.json`，来源见该目录 README；
  反思写作一律给写作接口真实形状的失败）、Life 的时钟（Agent，测试拨动以跨过最小间隔）。K-9 一例不替写作函数，改由真实 `Writer` 发给
  `HttpStub`（本机 TCP），替身回放同几份应答的原始回执字节。花费结论由 `profile.life.spend` 注入（Agent，同 Registry 注入的函数形状）。
  活动经历经 Selector 的产品函数做出（`LifeFixtures.ended/3`；说话那一步的候选取自 `Offers.speak_to/2`）。

  **与决策稿 §5 K-5 的偏差**（统筹 2026-11-19 定）：稿件写真实 Registry / Body / Scene；这里与日计划集成测试同一组合，Life 直接起、
  测试自己发观察（`Life.observation/2`，Runtime 走的同一个入口）。原因：Runtime 写进观察的游戏钟取墙钟、没有可注入的缝，回放的
  真实应答里意图的时限（13:30 起）与开任务的日号要对得上那份材料的此刻（第 1418 日 13:00）。候选这一环 T-1 没有改动（K-6 不占位，
  候选与经历由 `npc_selector_test` / `npc_offers_integration_test` 已证），所以不需要 Runtime。

  前提：观察是 S1-X2 第 4 轮那一刻的真实原始观察（`ReflectionFixtures.rawobs/1`），游戏钟换成第 1418 日、附近站着 Corvin
  （cid `1906495721474`、8.9 米，同 K-0 复测 R1 的材料：回放的应答点名的就是这个显示名）。`event` 一条用例要 Corvin 恰是
  `damage/4` 的出手者（出手者固定是 NPC 的 cid + 10），所以那条用例 NPC 取 cid `1906495721464`（独占库里只有它用这个 cid）。
  `confront_wrecker` 沿用 K-0 复测当时的词表（`fixtures/day_plan/activities.json`），在这里是**静态种类**；部署里它已是可点名人的种类
  （对人的登记项由生成器按人展开），所以“没点名的当头步收到点名的经历”那条路径只由 `npc_life_tasks_test` 的单测覆盖。
  不证明：真实模型写什么（K-0）、Jev 会不会选任务步（实跑）、学习写作（T-3）。
  """
  use ExUnit.Case, async: false
  import NpcServer.LifeFixtures, only: [damage: 4, ended: 3, reflect_profile: 3]
  import NpcServer.ReflectionFixtures, only: [rawobs: 1]
  alias NpcServer.{HttpStub, Life, NpcWorld, Offers, Secret}
  alias NpcServer.Life.Tasks

  @plan_fixtures Path.expand("../support/fixtures/day_plan", __DIR__)
  @task_fixtures Path.expand("../support/fixtures/tasks", __DIR__)
  # 推进系统提示词的开头一句（`Tasks.Prompt`）与回顾的（`DayPlan.Prompt`）：分辨规划槽这一次写的是哪一种。
  @advance_marker "You are working on something that takes several steps"
  @review_marker "It is time to plan the rest of today."
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
    {worker, system, user} = await_write(@review_marker)
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
    {worker, system, _user} = await_write(@review_marker)

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
    {worker, _system, user} = await_write(@review_marker)

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
  test "kind:event 的出手者是任务里的人：待推进 event；事件重排的用户消息带开着的任务一块，每行带 id；" <>
         "回顾先起，回顾没起成（当日额度用完）时推进照常起" do
    %{cid: cid, life: life, clock: clock, fixture: fixture} = start(cid: @corvin - 10)

    frame(life, @day, @minute)
    {worker, _system, _user} = await_write(@review_marker)
    reply(worker, "R1-r1")
    await_tasks(cid, &(length(&1["open"]) == 2))

    # Corvin（cid + 10）打掉我放的一格：Life 接纳成 kind:event；任务 2 点名了他 → 待推进 event；日计划记下等着重排。
    damage(fixture.world, cid, 1, {5, 64, 8})
    tasks = await_tasks(cid, &(task(&1, "t1418:2")["waiting"] == "event"))
    assert task(tasks, "t1418:1")["waiting"] == nil

    # 回顾到点（event）与任务待推进同时成立：回顾先起（任务层规划 §2.2），推进这一帧不起。
    advance(clock, @gap_ms)
    frame(life, @day, @minute + 30)
    {worker, _system, user} = await_write(@review_marker)

    answer = fixture("review-R1-r1.json")["text"] |> Jason.decode!()
    [%{"goal" => goal1}, %{"goal" => goal2}] = answer["tasks"]["open"]

    assert user =~
             "\n\nMy open tasks (by id):\n" <>
               "- t1418:1: #{goal1} — next: gather_stone; nothing done yet\n" <>
               "- t1418:2: #{goal2} — next: confront_wrecker; nothing done yet\n\n" <>
               "Plan the rest of today now."

    send(worker, {:reply, {:error, :timeout}})

    NpcWorld.await(fn ->
      match?(
        {:ok,
         %{
           plan: %{
             running: false,
             row: %{"calls" => %{"n" => 2}, "last" => %{"result" => "failed"}}
           }
         }},
        Life.observe(cid)
      )
    end)

    # —— 锁定 T-1b 偏差②“回顾先起；回顾没起成时推进照常起”：当日 2 次回顾已用完，Corvin 再打一次（event_waiting 为真，
    # 回顾每帧都到点）。若写成“回顾到点就不查推进”，这里推进永远起不来。
    damage(fixture.world, cid, 2, {4, 64, 8})

    NpcWorld.await(fn ->
      match?({:ok, %{plan: %{row: %{"event_waiting" => true}}}}, Life.observe(cid))
    end)

    advance(clock, @gap_ms)
    frame(life, @day, @minute + 35)
    {worker, _system, user} = await_write(@advance_marker)
    assert user =~ "The task I am working on: #{goal2}\n"

    assert {:ok, %{plan: %{row: %{"counts" => %{"skipped" => 1}}}, tasks: %{running: true}}} =
             Life.observe(cid)

    send(worker, {:reply, {:error, :timeout}})
    await_tasks(cid, &(&1["counts"]["failed"] == 1))
  end

  @tag timeout: 120_000
  test "推进：失败 → 真实被拒的应答只计数、等待留着 → 采用新步骤，新当头步进 Mind 的任务栏；步骤用完 → done 关闭；重启读回" do
    %{cid: cid, life: life, clock: clock, profile: profile} = start()
    {goal1, goal2} = review_r1(life, cid)
    tasks = await_tasks(cid, &(length(&1["open"]) == 2))
    planned = task(tasks, "t1418:1")["steps"]

    # —— 重建任务的当头步 gather_stone 失败 `exhausted`（偏差）→ 待推进；过了最小间隔的下一帧起推进（回顾今天已采用、不到点）。
    Life.activity(life, finished(profile, "gather_stone", {:failed, "gather", "exhausted"}))
    await_tasks(cid, &(task(&1, "t1418:1")["waiting"] == "failed"))

    advance(clock, @gap_ms)
    frame(life, @day, @minute + 5)
    {worker, system, user} = await_write(@advance_marker)

    # 推进的系统提示词与回顾共用词表（说话一行点名在场的 Corvin）；用户消息是这个任务、失败的结局（直白英文）与为什么现在问。
    assert system =~ ~s|Optionally add "object": exactly one of "Corvin (actor #{@corvin})".|
    assert user =~ "The task I am working on: #{goal1}\n"

    assert user =~
             "What I have done for it so far:\n- gather_stone: failed (gather: there was nothing left there that I could cut"

    assert user =~ "\n\nMy other open tasks:\n#{goal2} — next: confront_wrecker\n\n"

    assert String.ends_with?(
             user,
             "Why I am thinking about it now: My last step did not work out.\n\n" <>
               "Decide what to do next for this task now."
           )

    assert {:ok, %{tasks: %{running: true, task: "t1418:1"}, plan: %{running: false}}} =
             Life.observe(cid)

    # —— K-0 里一份真实应答（`look_for` 此刻不在词表里）：不合格，任务不动、等待留着、连续不合格 1；调用照扣。
    advance_reply(worker, "A17")
    tasks = await_tasks(cid, &(&1["counts"]["rejected"] == 1))

    assert %{"waiting" => "failed", "rejected_in_row" => 1, "steps" => ^planned} =
             task(tasks, "t1418:1")

    assert tasks["calls"] == %{"day" => @day, "n" => 1}

    assert {:ok, %{tasks: %{running: false, error: {:rejected, {:unknown_activity, "look_for"}}}}} =
             Life.observe(cid)

    # —— 再过最小间隔：再推进，真实应答 A01（continue 三步，另写了 cannot）采用：待做步骤换成新的、等待清掉、note 存进任务。
    advance(clock, @gap_ms)
    frame(life, @day, @minute + 10)
    {worker, _system, _user} = await_write(@advance_marker)
    advance_reply(worker, "A01")
    tasks = await_tasks(cid, &(&1["counts"]["advanced"] == 1))

    a01 = advance_answer("A01")
    rebuild = task(tasks, "t1418:1")

    assert Enum.map(rebuild["steps"], &{&1["kind"], &1["object"], &1["why"]}) ==
             Enum.map(a01["steps"], &{&1["activity"], &1["object"], &1["why"]})

    assert %{"waiting" => nil, "rejected_in_row" => 0, "head_failures" => 0} = rebuild
    assert rebuild["note"] == a01["note"]
    assert %{"advanced" => 1, "rejected" => 1, "cannot" => 1} = tasks["counts"]
    assert tasks["calls"] == %{"day" => @day, "n" => 2}

    # 新当头步就是 Mind 的任务栏这一行的 next（应答写的那一步，带它自己的 why）。
    assert {:ok, %{tasks: [%{goal: ^goal1, next: next, completed: 0} | _]}} = Life.mind(cid, [])
    assert next == hd(rebuild["steps"])
    assert next["why"] == hd(a01["steps"])["why"]

    # —— 问 Corvin 的任务：confront_wrecker、对 Corvin 说话都完成 → 步骤用完；推进回放 A06（done）→ 关掉、写一句经历。
    Life.activity(life, finished(profile, "confront_wrecker", :completed))

    [speak] =
      Offers.speak_to(Offers.registered(profile.activities, []), observation(@day, @minute))

    Life.activity(life, ended(profile, speak, :completed))
    await_tasks(cid, &(task(&1, "t1418:2")["waiting"] == "steps_done"))

    advance(clock, @gap_ms)
    frame(life, @day, @minute + 15)
    {worker, _system, user} = await_write(@advance_marker)
    assert user =~ "The task I am working on: #{goal2}\n"
    assert user =~ "Why I am thinking about it now: I have taken every step I planned for it."
    advance_reply(worker, "A06")
    tasks = await_tasks(cid, &(task(&1, "t1418:2") == nil))

    note = advance_answer("A06")["note"]

    assert [%{"id" => "t1418:2", "result" => "done", "note" => ^note, "completed" => 2}] =
             tasks["closed"]

    assert ~s|I finished my task "#{goal2}". #{note}| in Enum.map(
             task_episodes(cid),
             & &1["text"]
           )

    assert {:ok, %{tasks: [%{goal: ^goal1}]}} = Life.mind(cid, [])
    assert tasks["calls"] == %{"day" => @day, "n" => 3}

    # —— 重启：持久行是权威，推进的结果原样读回。
    stop_supervised!({:life, cid})
    start_life(cid, profile)
    assert {:ok, %{tasks: %{row: ^tasks, running: false}}} = Life.observe(cid)
  end

  @tag timeout: 90_000
  test "推进在途时当头步经真实活动做完：落栏的旧应答（A01 从采石重来）不采用，步骤不换回，只计 stale" do
    %{cid: cid, life: life, clock: clock, profile: profile} = start()
    review_r1(life, cid)
    await_tasks(cid, &(length(&1["open"]) == 2))

    # 采石失败 `exhausted` → 待推进；推进写作被回环替身挡住（还没回复）。
    Life.activity(life, finished(profile, "gather_stone", {:failed, "gather", "exhausted"}))
    await_tasks(cid, &(task(&1, "t1418:1")["waiting"] == "failed"))
    advance(clock, @gap_ms)
    frame(life, @day, @minute + 5)
    {worker, _system, _user} = await_write(@advance_marker)

    # 写作在途：采石经真实活动经历做成 → 前移到 build_hut、完成 1 步、偏差已化解。
    Life.activity(life, finished(profile, "gather_stone", :completed))
    moved = await_tasks(cid, &(task(&1, "t1418:1")["completed"] == 1))

    assert %{"waiting" => nil, "steps" => steps} = task(moved, "t1418:1")
    assert Enum.map(steps, & &1["kind"]) == ~w(build_hut guard_hut)

    # 放行 A01（对起推进那一刻写的：continue gather_stone → build_hut → guard_hut）：stale，任务保持现状。
    advance_reply(worker, "A01")
    tasks = await_tasks(cid, &(&1["counts"]["stale"] == 1))

    assert task(tasks, "t1418:1") == task(moved, "t1418:1")
    assert %{"advanced" => 0, "rejected" => 0, "cannot" => 0} = tasks["counts"]
    # 写作已发出：调用照扣。
    assert tasks["calls"] == %{"day" => @day, "n" => 1}
    assert {:ok, %{tasks: %{running: false, error: nil}}} = Life.observe(cid)
    assert stored(cid)["tasks"] == tasks
  end

  @tag timeout: 90_000
  test "花费到线：推进在记调用之前被拒、等待留着、当头步照常给 Mind；恢复后下一帧起推进，写作失败照扣额度" do
    spend = start_supervised!(Supervisor.child_spec({Agent, fn -> :open end}, id: :spend))
    %{cid: cid, life: life, clock: clock, profile: profile} = start(spend: spend)
    review_r1(life, cid)
    await_tasks(cid, &(length(&1["open"]) == 2))

    Agent.update(spend, fn _ -> {:paused, %{day: ~D[2026-11-19], reason: :limit}} end)
    Life.activity(life, finished(profile, "gather_stone", {:failed, "gather", "exhausted"}))
    await_tasks(cid, &(task(&1, "t1418:1")["waiting"] == "failed"))

    advance(clock, @gap_ms)
    frame(life, @day, @minute + 5)
    {:ok, observed} = Life.observe(cid)
    refute_write(@advance_marker)

    assert observed.spend_refused == %{task: ~D[2026-11-19]}
    assert %{running: false, calls: %{"day" => nil, "n" => 0}} = observed.tasks
    assert task(observed.tasks.row, "t1418:1")["waiting"] == "failed"

    # 冻结推进、不冻结行动：已写好的当头步照常交给 Mind（任务栏的 next）。
    assert {:ok, %{tasks: [%{next: %{"kind" => "gather_stone"}} | _]}} = Life.mind(cid, [])

    # 恢复：下一帧起推进（最小间隔从没起过的那次算不上，间隔早已过）；写作失败 → failed，等待留着，调用照扣。
    Agent.update(spend, fn _ -> :open end)
    frame(life, @day, @minute + 6)
    {worker, _system, _user} = await_write(@advance_marker)
    send(worker, {:reply, {:error, :timeout}})
    tasks = await_tasks(cid, &(&1["counts"]["failed"] == 1))

    assert task(tasks, "t1418:1")["waiting"] == "failed"
    assert tasks["calls"] == %{"day" => @day, "n" => 1}
    assert {:ok, %{tasks: %{error: {:failed, :timeout}}}} = Life.observe(cid)
  end

  @tag timeout: 90_000
  test "K-9：回顾与推进经真实写作接口发出的请求 max_tokens 都是 4096" do
    review = File.read!(Path.join(@task_fixtures, "review-R1-r1-raw.json"))
    a01 = File.read!(Path.join(@task_fixtures, "advance-A01.json"))

    url =
      HttpStub.start(fn :post,
                        "/chat/completions",
                        %{"messages" => [%{"content" => system} | _]} ->
        cond do
          system =~ @review_marker -> {200, review}
          system =~ @advance_marker -> {200, a01}
          # 反思等其它写作：写作接口真实形状的失败（不在这里验证）。
          true -> {503, %{}}
        end
      end)

    %{cid: cid, life: life, clock: clock, profile: profile} = start(writer: url)

    frame(life, @day, @minute)
    assert %{body: %{"max_tokens" => 4096}} = await_request(@review_marker)
    await_tasks(cid, &(length(&1["open"]) == 2))

    Life.activity(life, finished(profile, "gather_stone", {:failed, "gather", "exhausted"}))
    await_tasks(cid, &(task(&1, "t1418:1")["waiting"] == "failed"))
    advance(clock, @gap_ms)
    frame(life, @day, @minute + 5)
    assert %{body: %{"max_tokens" => 4096}} = await_request(@advance_marker)
    await_tasks(cid, &(&1["counts"]["advanced"] == 1))
  end

  # —— 夹具 ——

  # 起一个开着规划、配了说话的 Life（同 `npc_life_day_plan_integration_test` 的 `planning/1`）：真实 World 与 NpcMemory，
  # 时钟是测试拨动的 Agent；起好之后先接纳一条活动经历（规划要求有过经历）。`cid:` 指定永久 cid；`spend:` 是花费结论的 Agent
  # （注入 `profile.life.spend`，同 Registry 注入 `&SpendBudget.background/0` 的形状）；`writer:` 是写作接口替身的根 URL——
  # 给了就不替写作函数，由真实 `Reflection.Writer` 发 `:openai` 请求过去。
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

    life_options =
      case Keyword.fetch(opts, :spend) do
        {:ok, spend} -> %{spend: fn -> Agent.get(spend, & &1) end}
        :error -> %{}
      end

    profile =
      test
      |> reflect_profile(
        Map.put(life_options, :clock, fn -> Agent.get(clock, & &1) end),
        DataService.NpcMemory
      )
      |> Map.merge(%{activities: activities(), skills: %{speak: %{}}})
      |> writer(opts[:writer])

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

  defp writer(profile, nil), do: profile

  defp writer(profile, url),
    do:
      profile
      |> Map.delete(:write_journal)
      |> Map.put(:reflect, %{
        api: :openai,
        url: url <> "/chat/completions",
        key: Secret.wrap("deepseek-test-key"),
        model: "deepseek-flash",
        timeout_ms: 5000
      })

  # 一帧观察：S1-X2 第 4 轮那一刻的真实原始观察，附近只有 Corvin（8.9 米，同 K-0 复测 R1 的材料），游戏钟换成给定的日号与分钟。
  # 给 `entities: []` 时附近没有人（Corvin 走开了）。
  defp frame(life, day, minute, entities \\ nil),
    do: Life.observation(life, observation(day, minute, entities))

  defp observation(day, minute, entities \\ nil) do
    observation = rawobs(4)
    {x, y, z} = observation.self.position

    corvin = %{
      entity_id: @corvin,
      entity_epoch: 1,
      kind: 1,
      name: "Corvin",
      position: {x + 8.9, y, z}
    }

    %{
      observation
      | entities: entities || [corvin],
        world_time: %{observation.world_time | day: day, minute_of_day: minute}
    }
  end

  # 第 1418 日 13:00、Corvin 在场的 :day 回顾，回放 K-0 复测 R1-r1 的真实应答（开两个任务：重建 t1418:1、问 Corvin t1418:2）。
  # 返回两个任务的 goal。
  defp review_r1(life, cid) do
    frame(life, @day, @minute)
    {worker, _system, _user} = await_write(@review_marker)
    reply(worker, "R1-r1")
    await_tasks(cid, &(length(&1["open"]) == 2))
    answer = fixture("review-R1-r1.json")["text"] |> Jason.decode!()
    [%{"goal" => goal1}, %{"goal" => goal2}] = answer["tasks"]["open"]
    {goal1, goal2}
  end

  # 等系统提示词含 `marker` 的下一次写作，返回 `{worker, 系统提示词, 用户消息}`；途中别的写作（反思）一律给写作接口真实形状的失败。
  defp await_write(marker) do
    receive do
      {:write, worker, system, user} ->
        if String.contains?(system, marker) do
          {worker, system, user}
        else
          send(worker, {:reply, {:error, :timeout}})
          await_write(marker)
        end
    after
      10_000 -> flunk("没有收到写作：#{marker}")
    end
  end

  # 一小段时间里没有系统提示词含 `marker` 的写作（别的写作照样给失败）。
  defp refute_write(marker) do
    receive do
      {:write, worker, system, _user} ->
        if String.contains?(system, marker), do: flunk("不该起的写作：#{marker}")
        send(worker, {:reply, {:error, :timeout}})
        refute_write(marker)
    after
      300 -> :ok
    end
  end

  # 写作接口替身收到的下一个系统提示词含 `marker` 的请求（`HttpStub` 的请求形状），其余请求跳过。
  defp await_request(marker) do
    receive do
      {:http_request, %{body: %{"messages" => [%{"content" => system} | _]}} = request} ->
        if String.contains?(system, marker), do: request, else: await_request(marker)
    after
      10_000 -> flunk("写作接口没有收到请求：#{marker}")
    end
  end

  # 推进的应答：回放 `fixtures/tasks/advance-<名>.json`（DeepSeek 原始回执）里 `choices[0].message.content` 的原文。
  defp advance_reply(worker, name),
    do:
      send(
        worker,
        {:reply, {:ok, %{text: advance_text(name), usage: advance_raw(name)["usage"]}}}
      )

  defp advance_raw(name),
    do: Path.join(@task_fixtures, "advance-#{name}.json") |> File.read!() |> Jason.decode!()

  defp advance_text(name), do: hd(advance_raw(name)["choices"])["message"]["content"]
  defp advance_answer(name), do: Jason.decode!(advance_text(name))

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
