Code.require_file("../support/life_fixtures.exs", __DIR__)
Code.require_file("../support/http_stub.exs", __DIR__)

defmodule NpcServer.NpcLifeDayPlanIntegrationTest do
  @moduledoc """
  只测试：Life 的日计划接线——持久行 `"plan"`、规划槽、触发、活动记账、`mind/2` 与 `observe/1` 的 `plan`。

  范围：真实 Life、真实 NpcMemory（PostgreSQL）、真实 World（`NpcWorld.start/0`；Life 照常每 30 ms 读 World 事件，
  `kind:event` 经历由 `LifeFixtures.damage/4` 经 World 正式入口做出）。Life 直接起在测试的监督下、不起 Body：
  Runtime 每帧写进观察的游戏钟取自墙钟，测试控制不了日号与日内分钟；这里由测试自己发观察（`Life.observation/2`，
  Runtime 走的同一个入口），观察是 S1-X2 第 4 轮那一刻的真实原始观察（`ReflectionFixtures.rawobs/1`），只把 `world_time`
  的日号与分钟换成用例要的值。

  替身三处，同 `npc_life_test.exs` 的反思用例（`LifeFixtures`）：Hindsight 适配器（召回回放真实条目）、写日记的函数
  （`profile.write_journal`：系统提示词与用户消息交给测试进程，由测试给出 S1-R8 规划模型的真实应答或写作接口真实形状的失败）、
  Life 的时钟（Agent，测试拨动以跨过两次规划调用的最小间隔）。活动的经历由 `Selector` 的产品函数做出（`chose/4` → `ended/2`
  → `experience/2`）。词表是 S1-R7 的候选（`fixtures/day_plan/activities.json`，只有 `name` 与 `criterion`；Life 与 Selector
  只读这两个键与 `place_name`）。

  `kind:event` 经历同时触发反思，反思的写作请求一律给写作接口真实形状的失败（`await_plan_write/0`），不影响规划。
  保存失败的用例换用 `RefusingStore`（真实 NpcMemory 之上由测试控制的一次 `:write_denied`，同 `npc_life_test.exs` 的
  `ControlledStore`）；召回失败的用例由 `LifeFixtures.ReflectHindsight` 的同名 ETS 表让经历库的下一次召回返回 `:timeout`。
  规划要求有过经历，所以 `planning/1` 起好 Life 后先经 `Life.activity/2` 接纳一条活动经历（出生不触发的用例不给）。
  不证明：真实模型写什么；Mind 的计划栏（T4）；墙钟驱动的游戏钟与 Runtime 的接线（`npc_runtime_world_time_test.exs`）；
  规划在途时 Life 重启（槽随进程没了的边界只写在 Life moduledoc 的“已知”清单里）。
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import NpcServer.LifeFixtures, only: [damage: 4, reflect_profile: 3]
  import NpcServer.ReflectionFixtures, only: [rawobs: 1]
  alias NpcServer.{HttpStub, Life, NpcWorld, Selector}
  alias NpcServer.Life.DayPlan
  alias NpcServer.LifeFixtures.ReflectHindsight

  defmodule RefusingStore do
    @moduledoc """
    只测试：真实 NpcMemory 之上由测试进程控制的保存失败。ETS 里的 `{cid, 测试进程}` 拒绝下一次保存，
    `{{:activity, cid}, 测试进程, 经历原文}` 在测试放行前持续拒绝含该活动的行。其余读写照常。
    """
    defdelegate get(cid, kind, key), to: DataService.NpcMemory

    def put(cid, "life", "state", row) do
      case :ets.whereis(__MODULE__) != :undefined and :ets.take(__MODULE__, cid) do
        [{^cid, test}] ->
          send(test, {:save_refused, row})
          {:error, :write_denied}

        [] ->
          put_activity(cid, row)

        false ->
          DataService.NpcMemory.put(cid, "life", "state", row)
      end
    end

    def put(cid, kind, key, value), do: DataService.NpcMemory.put(cid, kind, key, value)

    defp put_activity(cid, row) do
      with [{_, test, text}] <- :ets.lookup(__MODULE__, {:activity, cid}),
           true <- Enum.any?(row["pending"], &(&1["text"] == text)) do
        send(test, :activity_write_refused)
        {:error, :write_denied}
      else
        _ -> DataService.NpcMemory.put(cid, "life", "state", row)
      end
    end
  end

  @plan_fixtures Path.expand("../support/fixtures/day_plan", __DIR__)
  # 两次规划调用的最小间隔（`DayPlan` 的 3 分钟）再多 1 毫秒。
  @gap_ms 3 * 60_000 + 1
  @day 1500

  setup_all do
    MmoTest.Database.start!()
    :ok
  end

  # 用例断言 Life 与规划槽的 info 日志（`npc_plan … event=skipped|landed|end`）；全局日志级别会被别的用例改成 :warning，
  # 这里只放开这两个模块。
  setup do
    Logger.put_module_level(Life, :info)
    Logger.put_module_level(DayPlan.Round, :info)

    on_exit(fn ->
      Logger.delete_module_level(Life)
      Logger.delete_module_level(DayPlan.Round)
    end)
  end

  @tag timeout: 60_000
  test "新行带空的 plan；旧行（没有 plan 键）加载时补成空的一份，随下一次保存落库" do
    %{cid: cid, profile: profile} = planning()

    assert {:ok, %{plan: plan}} = Life.observe(cid)

    assert plan == %{
             enabled: true,
             running: false,
             waiting_for_activity: false,
             row: DayPlan.new(),
             column: nil,
             error: nil
           }

    assert DataService.NpcMemory.get(cid, "life", "state")["plan"] == DayPlan.new()

    # 真实代码路径存下的行删掉 "plan"，再起 Life。
    stop_supervised!({:life, cid})
    old = Map.delete(DataService.NpcMemory.get(cid, "life", "state"), "plan")
    :ok = DataService.NpcMemory.put(cid, "life", "state", old)
    start_life(cid, profile)

    assert {:ok, %{plan: %{row: row}}} = Life.observe(cid)
    assert row == DayPlan.new()

    NpcWorld.await(fn -> DataService.NpcMemory.get(cid, "life", "state")["plan"] != nil end)
    stored = DataService.NpcMemory.get(cid, "life", "state")
    assert stored["plan"] == DayPlan.new() and Map.delete(stored, "plan") == old
  end

  @tag timeout: 60_000
  test "有过一条经历后首帧带游戏钟：触发 :day，写作收到 Prompt 的产物，真实应答落进持久行；mind/2 与 observe/1 的 plan；重启后还在" do
    %{cid: cid, life: life, profile: profile} = planning()
    sample = plan_sample("R3-r1")
    minute = sample["now_minute"]

    frame(life, @day, minute)
    {worker, user} = await_plan_write()

    # 系统提示词与 S1-R8 真实发出的逐字节相同（同一人格卡、同一词表）；用户消息是三块材料加末行，“自己”之前没写过。
    assert_received {:plan_system_checked, true}

    assert user =~
             ~r/\ARight now:\nIt is afternoon, 12:11\. It is day #{@day}\.\n.+\n\nWhat happened:\n\[1\] /s

    assert String.ends_with?(
             user,
             "\n\nWhat I thought before (my own earlier thoughts, not facts):\nAbout this: nothing yet\n" <>
               "About other things: nothing yet\n\nPlan the rest of today now."
           )

    assert {:ok, %{plan: %{running: true}}} = Life.observe(cid)
    reply(worker, "R3-r1")

    plan = await_plan(cid, &(&1.row["counts"]["planned"] == 1 and not &1.running))
    {:ok, checked} = DayPlan.check(sample["text"], names(), minute)

    assert plan.row["day"] == @day

    assert Enum.map(plan.row["intents"], &Map.take(&1, ~w(activity times by why))) ==
             checked.intents

    assert Enum.map(plan.row["intents"], & &1["done"]) == [0, 0, 0]
    assert plan.row["wants"] == checked.wants
    assert plan.row["calls"] == %{"day" => @day, "n" => 1}
    assert %{"kind" => "day", "result" => "adopted"} = plan.row["last"]
    assert plan.error == nil

    # 给选择的栏就是 `DayPlan.column/3` 对持久行与此刻的结果；observe 与 mind/2 同一份。
    assert plan.column == DayPlan.column(plan.row, @day, minute) and plan.column != nil
    assert {:ok, %{plan: column}} = Life.mind(cid, [])
    assert column == plan.column

    # 同一日再来一帧：今天已有计划，不再触发。
    frame(life, @day, minute + 1)
    refute_receive {:write, _, _, _}, 300

    # 重启：持久行是权威，意图与调用数都还在；同一日的帧照样不触发。
    stop_supervised!({:life, cid})
    life = start_life(cid, profile)
    assert {:ok, %{plan: %{row: row}}} = Life.observe(cid)
    assert row == plan.row
    frame(life, @day, minute + 2)
    refute_receive {:write, _, _, _}, 300
  end

  @tag timeout: 60_000
  test "活动记账：同名活动完成给 by 最早的 open 意图 done 加一；失败的不计；by 已过的不计" do
    %{cid: cid, life: life, profile: profile} = context = planning()
    # 12:11 的计划：guard_hut 13:00 前一次、visit_plaza 16:00 与 21:00 前各一次。
    plan_today(context, @day, "R3-r1")

    frame(life, @day, 740)
    Life.activity(life, finished(profile, "guard_hut", :completed))
    Life.activity(life, finished(profile, "visit_plaza", {:failed, "travel", "no_path"}))

    # 观察读到已入账的活动。
    assert {:ok, %{plan: plan}} = Life.observe(cid)
    assert dones(plan) == [1, 0, 0]

    # 16:40：第一条 visit_plaza 的时限（16:00）已过，完成记给 21:00 那条。
    frame(life, @day, 1000)
    Life.activity(life, finished(profile, "visit_plaza", :completed))
    assert {:ok, %{plan: plan}} = Life.observe(cid)
    assert dones(plan) == [1, 0, 1]
    assert Enum.map(plan.column.intents, & &1.status) == [:done, :missed, :done]

    # 21:40：再完成一次 visit_plaza，没有 open 的同名意图，什么也不记。
    frame(life, @day, 1300)
    Life.activity(life, finished(profile, "visit_plaza", :completed))
    assert {:ok, %{plan: after_all}} = Life.observe(cid)
    assert after_all.row["intents"] == plan.row["intents"]

    # 四项活动都照常成了经历（失败的那项也是），加上起 Life 后的第一条经历（`planning/1`）。
    assert {:ok, %{pending_episodes: 5}} = Life.observe(cid)
    assert DataService.NpcMemory.get(cid, "life", "state")["plan"] == after_all.row
  end

  @tag timeout: 60_000
  test "活动经历写盘失败可恢复，按完成时刻记一次计划进度" do
    :ets.new(RefusingStore, [:named_table, :public])

    %{cid: cid, life: life, clock: clock, profile: profile} =
      context =
      planning(memory: RefusingStore)

    plan_today(context, @day, "R3-r1")
    frame(life, @day, 740)

    at_ms = now(clock)
    experience = finished(profile, "guard_hut", :completed)
    :ets.insert(RefusingStore, {{:activity, cid}, self(), experience.text})

    assert {:error, {:memory_unavailable, :write_denied}} = Life.activity(life, experience)
    assert_receive :activity_write_refused
    assert {:ok, %{activity_pending: true, plan: plan}} = Life.observe(cid)
    assert dones(plan) == [0, 0, 0]
    assert {:error, :activity_pending} = Life.mind(cid, [])

    # 放行时守屋的时限已经过去。活动经历和进度仍应以完成时刻为准。
    advance(clock, 60_000)
    frame(life, @day, 800)
    assert {:ok, _} = Life.observe(cid)
    :ets.delete(RefusingStore, {:activity, cid})

    saved =
      NpcWorld.await(fn ->
        row = DataService.NpcMemory.get(cid, "life", "state")
        Enum.any?(row["pending"], &(&1["text"] == experience.text)) && row
      end)

    assert [%{"at_ms" => ^at_ms}] =
             Enum.filter(saved["pending"], &(&1["text"] == experience.text))

    assert Enum.map(saved["plan"]["intents"], & &1["done"]) == [1, 0, 0]
    assert {:ok, %{activity_pending: false, pending_episodes: 2}} = Life.observe(cid)
  end

  @tag timeout: 90_000
  test "在途重排先等已结束的活动落盘，再换掉旧计划的开放意图" do
    :ets.new(RefusingStore, [:named_table, :public])

    %{fixture: fixture, cid: cid, life: life, clock: clock, profile: profile} =
      context = planning(memory: RefusingStore)

    plan_today(context, @day, "R3-r1")
    damage(fixture.world, cid, 1, {5, 64, 8})
    await_plan(cid, & &1.row["event_waiting"])
    advance(clock, @gap_ms)
    frame(life, @day, 740)
    {worker, _user} = await_plan_write()

    experience = finished(profile, "guard_hut", :completed)
    :ets.insert(RefusingStore, {{:activity, cid}, self(), experience.text})
    assert {:error, {:memory_unavailable, :write_denied}} = Life.activity(life, experience)

    reply(worker, "R2-r1")

    before_recovery =
      await_plan(cid, fn plan ->
        Map.get(plan, :waiting_for_activity) || plan.row["counts"]["replanned"] == 1
      end)

    assert before_recovery.row["counts"]["replanned"] == 0
    assert dones(before_recovery) == [0, 0, 0]
    :ets.delete(RefusingStore, {:activity, cid})

    after_recovery = await_plan(cid, &(&1.row["counts"]["replanned"] == 1 and not &1.running))

    assert [%{"activity" => "guard_hut", "done" => 1, "id" => id} | _] =
             after_recovery.row["intents"]

    assert id == "#{@day}:1"
  end

  @tag timeout: 90_000
  test "额度：最小间隔内不起第二次；同一游戏日第 6 次到点被拒，skipped 只加一、不随帧数增长；跨日恢复" do
    %{cid: cid, life: life, clock: clock} = planning()

    for n <- 1..5 do
      frame(life, @day, 600)
      {worker, _user} = await_plan_write()
      send(worker, {:reply, {:error, :timeout}})
      await_plan(cid, &(&1.row["counts"]["failed"] == n and not &1.running))

      # 间隔不足 3 分钟：不起第二次（触发条件留着）。
      if n == 1 do
        frame(life, @day, 601)
        refute_receive {:write, _, _, _}, 300
      end

      advance(clock, @gap_ms)
    end

    log =
      capture_log(fn ->
        for minute <- 602..606, do: frame(life, @day, minute)
        advance(clock, @gap_ms)
        for minute <- 607..609, do: frame(life, @day, minute)
        assert {:ok, %{plan: plan}} = Life.observe(cid)
        send(self(), {:plan, plan})
      end)

    refute_receive {:write, _, _, _}, 300
    assert_received {:plan, plan}
    assert plan.row["calls"] == %{"day" => @day, "n" => 5}
    assert %{"failed" => 5, "skipped" => 1} = plan.row["counts"]
    assert length(String.split(log, "event=skipped")) == 2
    assert log =~ "reason=day_budget_exhausted"

    # 跨日：额度清零，到点就起。
    frame(life, @day + 1, 10)
    {worker, _user} = await_plan_write()
    assert {:ok, %{plan: %{running: true, row: %{"calls" => calls}}}} = Life.observe(cid)
    assert calls == %{"day" => @day + 1, "n" => 1}
    send(worker, {:reply, {:error, :timeout}})
    await_plan(cid, &(&1.row["counts"]["failed"] == 6 and not &1.running))
  end

  @tag timeout: 90_000
  test "重排：kind:event 经历到来 → :event 触发，保留已完成的旧意图、换掉 open 的；wants 整份换成新的" do
    %{fixture: fixture, cid: cid, life: life, clock: clock, profile: profile} =
      context = planning()

    first = plan_today(context, @day, "R3-r1")
    [%{"want" => old_want}] = first.row["wants"]

    frame(life, @day, 740)
    Life.activity(life, finished(profile, "guard_hut", :completed))

    # 别人打掉我放的一格（World 正式入口）：Life 读到它，接纳成 kind:event 经历，记下等着重排。
    damage(fixture.world, cid, 1, {5, 64, 8})
    await_plan(cid, & &1.row["event_waiting"])

    advance(clock, @gap_ms)
    frame(life, @day, 800)
    {worker, user} = await_plan_write()

    assert user =~
             "\n\nWhat I meant to do today, as it stands:\nguard_hut: 1 of 1 done — finished\n" <>
               "visit_plaza: 0 of 1 done, by 16:00\nvisit_plaza: 0 of 1 done, by 21:00\n\n" <>
               "Things I wanted to do but could not yet:\n#{old_want}\n\nPlan the rest of today now."

    reply(worker, "R2-r1")
    plan = await_plan(cid, &(&1.row["counts"]["replanned"] == 1 and not &1.running))
    {:ok, checked} = DayPlan.check(plan_sample("R2-r1")["text"], names(), 800)

    [kept | fresh] = plan.row["intents"]

    assert Map.take(kept, ~w(id activity done)) ==
             %{"id" => "#{@day}:1", "activity" => "guard_hut", "done" => 1}

    assert Enum.map(fresh, &Map.take(&1, ~w(activity times by why))) == checked.intents
    assert Enum.map(fresh, & &1["id"]) == ["#{@day}:2", "#{@day}:3"]
    assert plan.row["wants"] == checked.wants
    refute plan.row["event_waiting"]
    assert plan.row["calls"] == %{"day" => @day, "n" => 2}
    assert %{"kind" => "event", "result" => "adopted"} = plan.row["last"]
    assert %{"planned" => 1, "replanned" => 1} = plan.row["counts"]
  end

  @tag timeout: 90_000
  test "检查不过（R1-r1：6 条）/ 写作失败：counts.rejected / failed，意图不动；选择照常读得到视图" do
    %{cid: cid, life: life, clock: clock} = context = planning()
    before = plan_today(context, @day, "R3-r1").row

    # 新的一日 13:00：本日还没有计划，到点 :day。
    advance(clock, @gap_ms)
    frame(life, @day + 1, 780)
    {worker, _user} = await_plan_write()
    reply(worker, "R1-r1")

    plan = await_plan(cid, &(&1.row["counts"]["rejected"] == 1 and not &1.running))
    assert Map.take(plan.row, ~w(day intents wants)) == Map.take(before, ~w(day intents wants))

    assert %{"kind" => "day", "result" => "rejected", "reason" => "{:too_many_items, 6}"} =
             plan.row["last"]

    assert plan.error == {:too_many_items, 6}

    # 选择照常：视图读得到；昨天的意图不进今天的栏，旧 wants 还在（直到下一次规划换掉）。
    assert {:ok, %{plan: %{intents: [], wants: wants}}} = Life.mind(cid, [])
    assert wants == before["wants"]

    advance(clock, @gap_ms)
    frame(life, @day + 1, 790)
    {worker, _user} = await_plan_write()
    send(worker, {:reply, {:error, :timeout}})

    plan = await_plan(cid, &(&1.row["counts"]["failed"] == 1 and not &1.running))
    assert Map.take(plan.row, ~w(day intents wants)) == Map.take(before, ~w(day intents wants))
    # 写作失败与检查不过都发出了写作请求，各扣一次当日额度。
    assert plan.row["calls"] == %{"day" => @day + 1, "n" => 2}
    assert plan.error == :timeout
  end

  @tag timeout: 60_000
  test "出生（真实首帧观察、还没有任何经历）不起规划、不计调用；接纳第一条活动经历之后的下一帧起 :day" do
    %{cid: cid, life: life, profile: profile} = planning(experienced: false)

    frame(life, @day, 600)
    refute_plan_write(500)

    assert {:ok, %{plan: %{running: false, row: row}, pending_episodes: 0, retained: 0}} =
             Life.observe(cid)

    assert row == DayPlan.new()
    assert row["calls"]["n"] == 0 and Enum.all?(Map.values(row["counts"]), &(&1 == 0))

    Life.activity(life, finished(profile, "guard_hut", :completed))
    frame(life, @day, 601)
    {worker, _user} = await_plan_write()
    assert {:ok, %{plan: %{running: true, row: %{"calls" => calls}}}} = Life.observe(cid)
    assert calls == %{"day" => @day, "n" => 1}

    send(worker, {:reply, {:error, :timeout}})
    plan = await_plan(cid, &(&1.row["counts"]["failed"] == 1 and not &1.running))
    assert %{"kind" => "day"} = plan.row["last"]
  end

  @tag timeout: 60_000
  test "经历都已写进 Hindsight 的老 NPC（未写的经历为空、retained 大于 0）：重启后照样触发 :day" do
    %{cid: cid, profile: profile} = planning()

    # 产品路径把那条经历封存并写进 Hindsight（`flush/1` → retain），再重启：未写的经历为空。
    assert {:ok, %{status: :started}} = Life.flush(cid)

    NpcWorld.await(fn ->
      match?(
        {:ok, %{retained: 1, pending_episodes: 0, pending_fragments: 0, job: nil}},
        Life.observe(cid)
      )
    end)

    stop_supervised!({:life, cid})
    life = start_life(cid, profile)
    assert {:ok, %{retained: 1, pending_episodes: 0, pending_fragments: 0}} = Life.observe(cid)

    frame(life, @day, 600)
    {worker, _user} = await_plan_write()
    send(worker, {:reply, {:error, :timeout}})
    plan = await_plan(cid, &(&1.row["counts"]["failed"] == 1 and not &1.running))
    assert %{"kind" => "day"} = plan.row["last"]
  end

  @tag timeout: 60_000
  test "召回失败（写作之前就失败）：照记失败，不扣当日额度，最小间隔照算；写作函数被调用之后的失败（连接被拒）照扣" do
    :ets.new(ReflectHindsight, [:named_table, :public])
    %{cid: cid, life: life, clock: clock} = planning()
    started_at = now(clock)
    :ets.insert(ReflectHindsight, {"npc-life-#{cid}", self()})

    log =
      capture_log(fn ->
        frame(life, @day, 600)
        assert_receive {:recall_refused, _bank}, 5_000
        plan = await_plan(cid, &(&1.row["counts"]["failed"] == 1 and not &1.running))
        send(self(), {:plan, plan})
      end)

    assert_received {:plan, plan}
    refute_received {:write, _, _, _}
    assert plan.row["calls"] == %{"day" => @day, "n" => 0}

    assert %{
             "at_ms" => ^started_at,
             "kind" => "day",
             "result" => "failed",
             "reason" => ":timeout"
           } =
             plan.row["last"]

    assert plan.row["last_at_ms"] == started_at
    assert plan.error == :timeout
    assert DataService.NpcMemory.get(cid, "life", "state")["plan"] == plan.row

    assert log =~
             "npc_plan cid=#{cid} event=end kind=day day=#{@day} result=failed reason=:timeout wrote=false"

    assert log =~
             ~r/npc_plan cid=#{cid} event=landed kind=day day=#{@day} result=failed .*wrote=false/

    # 最小间隔从起调用那一刻算：不足 3 分钟不起，过了再起。
    frame(life, @day, 601)
    refute_plan_write(300)
    advance(clock, @gap_ms)
    frame(life, @day, 602)
    {worker, _user} = await_plan_write()
    assert {:ok, %{plan: %{row: %{"calls" => calls}}}} = Life.observe(cid)
    assert calls == %{"day" => @day, "n" => 1}

    # 写作接口连接被拒（`Writer.write/3` 的真实形状，S1-R10 的 econnrefused）：写作函数已被调用，算发出了写作，照扣。
    refused =
      {:transport,
       {:failed_connect, [{:to_address, {~c"127.0.0.1", 9}}, {:inet, [:inet], :econnrefused}]}}

    log =
      capture_log(fn ->
        send(worker, {:reply, {:error, refused}})
        plan = await_plan(cid, &(&1.row["counts"]["failed"] == 2 and not &1.running))
        send(self(), {:plan, plan})
      end)

    assert_received {:plan, plan}
    assert plan.row["calls"] == %{"day" => @day, "n" => 1}
    assert plan.error == refused

    assert log =~
             ~r/npc_plan cid=#{cid} event=landed kind=day day=#{@day} result=failed .*wrote=true/
  end

  @tag timeout: 60_000
  test "没有写日记接口的 Life 不规划；有接口但观察里没有游戏钟也不规划" do
    %{fixture: fixture, cid: cid, life: life} = planning(journaling: false)
    frame(life, @day, 600)
    assert {:ok, %{plan: nil}} = Life.observe(cid)
    assert {:ok, %{plan: nil}} = Life.mind(cid, [])
    # 持久行照样带空的一份（形状与开不开规划无关）。
    assert DataService.NpcMemory.get(cid, "life", "state")["plan"] == DayPlan.new()

    %{cid: cid, life: life} = planning(fixture: fixture)
    Life.observation(life, Map.delete(rawobs(4), :world_time))
    refute_receive {:write, _, _, _}, 500
    assert {:ok, %{plan: %{running: false, column: nil, row: row}}} = Life.observe(cid)
    assert row == DayPlan.new()
    assert {:ok, %{plan: nil}} = Life.mind(cid, [])
  end

  @tag timeout: 60_000
  test "规划槽 worker 崩溃：记一次失败，Life 不死，槽清空" do
    %{cid: cid, life: life} = planning()

    log =
      capture_log(fn ->
        frame(life, @day, 600)
        {worker, _user} = await_plan_write()
        send(worker, {:exit, :plan_writer_crashed})

        plan = await_plan(cid, &(&1.row["counts"]["failed"] == 1 and not &1.running))
        assert {:plan_worker_crashed, detail} = plan.error
        assert detail =~ "plan_writer_crashed"
        assert %{"result" => "failed", "reason" => reason} = plan.row["last"]
        assert reason =~ "plan_worker_crashed"
        assert plan.row["intents"] == [] and plan.row["calls"]["n"] == 1
      end)

    assert Process.alive?(life) and :global.whereis_name({Life, node(), cid}) == life
    assert log =~ "npc_plan cid=#{cid} event=crashed"
  end

  @tag timeout: 90_000
  test "规划在途时到来的 event：起调用即清标记并记 last_at_ms；落栏后标记仍在，间隔过后触发 :event；:event 失败恢复标记" do
    %{fixture: fixture, cid: cid, life: life, clock: clock} = context = planning()
    plan_today(context, @day, "R3-r1")

    damage(fixture.world, cid, 1, {5, 64, 8})
    await_plan(cid, & &1.row["event_waiting"])
    advance(clock, @gap_ms)
    started_at = now(clock)
    frame(life, @day, 800)
    {worker, _user} = await_plan_write()

    # 起调用那次保存已落库：调用数、起调用的时刻、清掉的标记（这次调用的材料里已有那条 event）。
    stored = DataService.NpcMemory.get(cid, "life", "state")["plan"]
    assert stored["calls"] == %{"day" => @day, "n" => 2}
    assert stored["last_at_ms"] == started_at
    refute stored["event_waiting"]

    # 调用在途时又来一条 event：这次规划的材料里没有它。
    damage(fixture.world, cid, 2, {4, 64, 8})
    await_plan(cid, &(&1.row["event_waiting"] and &1.running))

    reply(worker, "R2-r1")
    plan = await_plan(cid, &(&1.row["counts"]["replanned"] == 1 and not &1.running))
    assert plan.row["event_waiting"]
    assert plan.row["last_at_ms"] == started_at

    # 间隔不足：不起；间隔过后：:event 触发。
    frame(life, @day, 801)
    refute_plan_write(300)
    advance(clock, @gap_ms)
    frame(life, @day, 802)
    {worker, _user} = await_plan_write()
    assert {:ok, %{plan: %{row: %{"event_waiting" => false}}}} = Life.observe(cid)

    # 这次重排失败：条件恢复，留到下次。
    send(worker, {:reply, {:error, :timeout}})
    plan = await_plan(cid, &(&1.row["counts"]["failed"] == 1 and not &1.running))
    assert %{"kind" => "event", "result" => "failed"} = plan.row["last"]
    assert plan.row["event_waiting"]
  end

  @tag timeout: 60_000
  test "身体状态还没到（body_state 为 nil）不起规划、不计调用；身体状态到了就触发" do
    %{cid: cid, life: life} = planning()
    observation = rawobs(4)
    no_body = put_in(observation.self.body_state, nil)

    Life.observation(
      life,
      %{no_body | world_time: %{observation.world_time | day: @day, minute_of_day: 600}}
    )

    refute_plan_write(500)
    assert {:ok, %{plan: %{running: false, row: row}}} = Life.observe(cid)
    assert row == DayPlan.new()

    frame(life, @day, 601)
    {worker, _user} = await_plan_write()
    send(worker, {:reply, {:error, :timeout}})
    await_plan(cid, &(&1.row["counts"]["failed"] == 1 and not &1.running))
  end

  @tag timeout: 60_000
  test "有写日记接口但候选表为空（不规划的形态）：收到 kind:event 后持久行的 plan 仍是空的一份" do
    %{fixture: fixture, cid: cid} = planning(activities: [], experienced: false)
    damage(fixture.world, cid, 1, {5, 64, 8})

    NpcWorld.await(fn -> match?({:ok, %{pending_episodes: n}} when n >= 1, Life.observe(cid)) end)
    assert {:ok, %{plan: nil}} = Life.observe(cid)
    assert DataService.NpcMemory.get(cid, "life", "state")["plan"] == DayPlan.new()
  end

  @tag timeout: 60_000
  test "起调用那次保存失败：行不变、不起槽，一秒之内不再试；之后恢复" do
    :ets.new(RefusingStore, [:named_table, :public])
    %{cid: cid, life: life, clock: clock} = planning(memory: RefusingStore)
    :ets.insert(RefusingStore, {cid, self()})

    frame(life, @day, 600)
    assert_receive {:save_refused, refused}, 5_000
    assert refused["plan"]["calls"] == %{"day" => @day, "n" => 1}

    assert {:ok, %{plan: %{running: false, row: row}}} = Life.observe(cid)
    assert row == DayPlan.new()
    assert DataService.NpcMemory.get(cid, "life", "state")["plan"] == DayPlan.new()

    # 防抖期内：下一帧不再写库（保存放行也不起槽）。
    frame(life, @day, 601)
    refute_plan_write(300)
    refute_received {:save_refused, _}

    advance(clock, 1_001)
    frame(life, @day, 602)
    {worker, _user} = await_plan_write()
    assert DataService.NpcMemory.get(cid, "life", "state")["plan"]["calls"]["n"] == 1
    send(worker, {:reply, {:error, :timeout}})
    await_plan(cid, &(&1.row["counts"]["failed"] == 1 and not &1.running))
  end

  @tag timeout: 60_000
  test "落栏那次保存失败：意图没落，起调用时记下的 last_at_ms 照算，最小间隔内不再调用；间隔过后再起 :day" do
    :ets.new(RefusingStore, [:named_table, :public])
    %{cid: cid, life: life, clock: clock} = planning(memory: RefusingStore)
    started_at = now(clock)

    log =
      capture_log(fn ->
        frame(life, @day, plan_sample("R3-r1")["now_minute"])
        {worker, _user} = await_plan_write()
        :ets.insert(RefusingStore, {cid, self()})
        reply(worker, "R3-r1")

        assert_receive {:save_refused, refused}, 5_000
        assert length(refused["plan"]["intents"]) == 3
        await_plan(cid, &(not &1.running))
      end)

    assert log =~ "npc_plan cid=#{cid} event=persist_failed"
    assert {:ok, %{plan: %{row: row}}} = Life.observe(cid)
    assert row["intents"] == [] and row["day"] == nil
    assert row["calls"] == %{"day" => @day, "n" => 1}
    assert row["last_at_ms"] == started_at
    assert DataService.NpcMemory.get(cid, "life", "state")["plan"] == row

    frame(life, @day, 740)
    refute_plan_write(300)

    advance(clock, @gap_ms)
    frame(life, @day, 741)
    {worker, _user} = await_plan_write()
    send(worker, {:reply, {:error, :timeout}})
    plan = await_plan(cid, &(&1.row["counts"]["failed"] == 1 and not &1.running))
    assert %{"kind" => "day"} = plan.row["last"]
    assert plan.row["calls"]["n"] == 2
  end

  @tag timeout: 60_000
  test "规划槽 worker 崩溃且记失败的那次保存也失败：行不变，Life 不死，槽清空" do
    :ets.new(RefusingStore, [:named_table, :public])
    %{cid: cid, life: life} = planning(memory: RefusingStore)

    capture_log(fn ->
      frame(life, @day, 600)
      {worker, _user} = await_plan_write()
      before = DataService.NpcMemory.get(cid, "life", "state")["plan"]
      :ets.insert(RefusingStore, {cid, self()})
      send(worker, {:exit, :plan_writer_crashed})

      assert_receive {:save_refused, refused}, 5_000
      assert refused["plan"]["counts"]["failed"] == 1

      plan = await_plan(cid, &(not &1.running))
      assert plan.row == before
      assert plan.row["counts"]["failed"] == 0 and plan.row["calls"]["n"] == 1
      assert {:plan_worker_crashed, _} = plan.error
    end)

    assert Process.alive?(life) and :global.whereis_name({Life, node(), cid}) == life
  end

  @tag timeout: 60_000
  test "调用期间越过日界：按起槽那天的日号落栏，下一帧观察按新日触发 :day（间隔过后）" do
    %{cid: cid, life: life, clock: clock} = planning()
    minute = plan_sample("R3-r1")["now_minute"]

    frame(life, @day, minute)
    {worker, _user} = await_plan_write()
    # 调用在途时游戏钟进入下一日（槽在途，这一帧不触发）。
    frame(life, @day + 1, 5)
    reply(worker, "R3-r1")

    plan = await_plan(cid, &(&1.row["counts"]["planned"] == 1 and not &1.running))
    assert plan.row["day"] == @day
    assert Enum.map(plan.row["intents"], & &1["id"]) == ["#{@day}:1", "#{@day}:2", "#{@day}:3"]
    # 栏按此刻（新日）给：昨天的意图不进，wants 仍给。
    assert %{intents: [], wants: [_]} = plan.column

    advance(clock, @gap_ms)
    frame(life, @day + 1, 6)
    {worker, _user} = await_plan_write()
    assert {:ok, %{plan: %{row: %{"calls" => calls}}}} = Life.observe(cid)
    assert calls == %{"day" => @day + 1, "n" => 1}
    send(worker, {:reply, {:error, :timeout}})
    plan = await_plan(cid, &(&1.row["counts"]["failed"] == 1 and not &1.running))
    assert %{"kind" => "day"} = plan.row["last"]
  end

  @tag :model_usage
  @tag timeout: 60_000
  test "规划和反思通过真实 Writer 按同一角色分别记录模型请求" do
    Logger.put_module_level(NpcServer.ModelUsage, :info)
    on_exit(fn -> Logger.delete_module_level(NpcServer.ModelUsage) end)
    sample = plan_sample("R3-r1")
    plan_system = plan_request()["system"]

    url =
      HttpStub.start(fn
        :post, "/v1/messages", %{"system" => ^plan_system} ->
          {200,
           %{
             "stop_reason" => "end_turn",
             "content" => [%{"type" => "text", "text" => sample["text"]}]
           }}

        :post, "/v1/messages", _ ->
          {429, %{"type" => "error", "error" => %{"type" => "rate_limit_error"}}}
      end)

    endpoint = %{url: url <> "/v1/messages", key: "test-key", model: "reflect-test"}
    %{fixture: fixture, cid: cid, life: life} = planning(writer_endpoint: endpoint)

    log =
      capture_log(fn ->
        frame(life, @day, sample["now_minute"])
        await_plan(cid, &(&1.row["counts"]["planned"] == 1 and not &1.running))

        damage(fixture.world, cid, 1, {5, 64, 8})

        NpcWorld.await(fn ->
          match?(
            {:ok, %{reflection: %{running: false, error: error}}} when error != nil,
            Life.observe(cid)
          )
        end)
      end)

    finished =
      for [_, payload] <- Regex.scan(~r/npc_model_request (\{[^\n]+\})/, log),
          %{"cid" => ^cid, "event" => "finished"} = event <- [Jason.decode!(payload)],
          do: {event["operation"], event["status"], event["lane"]}

    # 日计划与反思的写作没人在等：走出站的后台车道（Finch 决策稿 D-2）。
    assert {"day_plan", "response", "background"} in finished
    assert {"reflection", "http_error", "background"} in finished
  end

  # 起一个开着规划的 Life（`journaling: false` 时不带写日记接口）：真实 World 与 NpcMemory，Life 的时钟是测试拨动的 Agent。
  # `memory:` 换存储（保存失败的用例用 `RefusingStore`），`activities:` 换候选表（空表即不规划的形态）。
  # 同一用例里起第二个 Life 时用 `fixture:` 共用同一个世界（世界进程是具名的，一个用例只起一个）。
  # 规划要求 NPC 有过至少一条经历，所以起好之后先接纳一条活动经历（还没有观察，不记账，“出生”的样子只差这一条）；
  # `experienced: false` 时不给（出生不触发的用例、要数经历条数的用例）。
  defp planning(opts \\ []) do
    test = self()
    fixture = Keyword.get_lazy(opts, :fixture, &NpcWorld.start/0)
    cid = System.unique_integer([:positive]) + 100_000

    clock =
      start_supervised!(
        Supervisor.child_spec({Agent, fn -> System.system_time(:millisecond) end},
          id: {:clock, cid}
        )
      )

    profile =
      test
      |> reflect_profile(
        %{clock: fn -> Agent.get(clock, & &1) end},
        Keyword.get(opts, :memory, DataService.NpcMemory)
      )
      |> Map.put(:activities, Keyword.get_lazy(opts, :activities, &activities/0))

    profile =
      if Keyword.get(opts, :journaling, true),
        do: profile,
        else: Map.drop(profile, [:reflect, :write_journal])

    profile =
      case Keyword.fetch(opts, :writer_endpoint) do
        {:ok, endpoint} -> profile |> Map.put(:reflect, endpoint) |> Map.delete(:write_journal)
        :error -> profile
      end

    life = start_life(cid, profile)

    if Keyword.get(opts, :experienced, true) do
      Life.activity(life, finished(profile, "visit_plaza", :completed))
      assert {:ok, %{pending_episodes: 1}} = Life.observe(cid)
    end

    %{fixture: fixture, cid: cid, clock: clock, profile: profile, life: life}
  end

  # Life 起在测试的监督下（停的时候由监督者按父进程退出处理），等到行与认识都加载好。
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

  # 一帧观察：S1-X2 第 4 轮那一刻的真实原始观察，游戏钟换成给定的日号与日内分钟。
  defp frame(life, day, minute) do
    observation = rawobs(4)

    Life.observation(
      life,
      %{observation | world_time: %{observation.world_time | day: day, minute_of_day: minute}}
    )
  end

  # 采用一份当日计划：一帧观察（分钟取这份应答在 S1-R8 里的此刻）→ 等规划写作 → 给真实应答 → 等落栏。
  defp plan_today(%{cid: cid, life: life}, day, name) do
    frame(life, day, plan_sample(name)["now_minute"])
    {worker, _user} = await_plan_write()
    reply(worker, name)
    await_plan(cid, &(&1.row["day"] == day and not &1.running))
  end

  # 等下一次规划写作，返回 `{worker, 用户消息}`；顺带核对系统提示词与 S1-R8 真实请求体逐字节相同（结果放进邮箱）。
  # 途中到来的反思写作（kind:event 也触发反思；系统提示词不同）一律给写作接口真实形状的失败（`Writer.write/3` 的 `:timeout`）。
  defp await_plan_write do
    plan_system = plan_request()["system"]

    receive do
      {:write, worker, ^plan_system, user} ->
        send(self(), {:plan_system_checked, true})
        {worker, user}

      {:write, worker, "You are this person: " <> _ = system, _user} ->
        if String.contains?(system, "It is time to plan the rest of today."),
          do: flunk("规划系统提示词与 S1-R8 的真实请求体不同"),
          else: send(worker, {:reply, {:error, :timeout}})

        await_plan_write()
    after
      10_000 -> flunk("没有收到规划写作")
    end
  end

  # 这段时间里没有起规划写作（只认规划的系统提示词；途中到来的反思写作留在邮箱里，由下一次 `await_plan_write/0` 处理）。
  defp refute_plan_write(ms) do
    plan_system = plan_request()["system"]
    refute_receive {:write, _, ^plan_system, _}, ms
  end

  defp reply(worker, name),
    do: send(worker, {:reply, {:ok, %{text: plan_sample(name)["text"], usage: %{}}}})

  defp await_plan(cid, ready) do
    NpcWorld.await(
      fn ->
        case Life.observe(cid) do
          {:ok, %{plan: %{} = plan}} -> ready.(plan) && plan
          _ -> false
        end
      end,
      15_000
    )
  end

  # 一项活动结束时 Runtime 交给 Life 的经历：经 Selector 的产品函数做出（选定 → 结局 → 经历）。
  defp finished(profile, name, result) do
    selection = %{
      activity: name,
      trigger: "start",
      confidence: 0.6,
      latency_ms: 1,
      recall_ms: 1,
      model: "test"
    }

    {_trigger, state} =
      Selector.new() |> Selector.chose(selection, profile, 0) |> Selector.ended(result)

    Selector.experience(state, profile)
  end

  defp dones(plan), do: Enum.map(plan.row["intents"], & &1["done"])
  defp advance(clock, ms), do: Agent.update(clock, &(&1 + ms))
  defp now(clock), do: Agent.get(clock, & &1)

  defp plan_sample(name), do: plan_fixture("s1r8-#{name}.json")
  defp plan_request, do: plan_fixture("requests-R1.json")
  defp plan_fixture(name), do: Path.join(@plan_fixtures, name) |> File.read!() |> Jason.decode!()

  # 词表：S1-R7 的候选，形状同注册表构造的候选（Life 与 Selector 读 `name`、`criterion`、`place_name`）。
  defp activities do
    for %{"name" => name, "criterion" => criterion} <- plan_fixture("activities.json"),
        do: %{name: name, criterion: criterion, place_name: nil}
  end

  defp names, do: Enum.map(activities(), & &1.name)
end
