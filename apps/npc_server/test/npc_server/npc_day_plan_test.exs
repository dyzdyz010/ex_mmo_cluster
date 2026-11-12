defmodule NpcServer.NpcDayPlanTest do
  @moduledoc """
  只测试：LLM 日计划（N2）与重新规划（N3）。请求函数一律替换为本地假应答（profile.request），不发 HTTP、不调用真实模型。
  day_ms 取 1_000_000，千分位 = rem(now, day_ms) / 1000，期望值按此手算。
  "没有请求"的断言用同一发送者的后续消息做同步点（进程邮箱按发送次序处理），不靠固定等待。
  2026-11-12（薄片一 S1-A）：读计划的 `Utility` 与作息树 `Trees.settler_daily/1` 已删除，原先经它们断言的三处
  （计划当前段的选取与权重、决策日志的 plan_source、Runtime 用例里按计划选 avoid）随被测对象一起去掉；
  DayPlan 自己的请求、校验、拼接、额度与 Runtime 的挂接仍在这里验证。
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias NpcServer.{DayPlan, LlmBudget, Runtime}
  alias NpcServer.Life.State

  @day_ms 1_000_000
  @plan [
    %{"from" => 0, "to" => 300, "activity" => "rest", "target" => "home"},
    %{"from" => 300, "to" => 650, "activity" => "work", "target" => nil},
    %{"from" => 650, "to" => 800, "activity" => "social", "target" => "plaza"},
    %{"from" => 800, "to" => 1000, "activity" => "rest", "target" => "home"}
  ]

  setup do
    for module <- [DayPlan, LlmBudget], do: Logger.put_module_level(module, :info)
    on_exit(fn -> for m <- [DayPlan, LlmBudget], do: Logger.delete_module_level(m) end)
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, replies} = Agent.start_link(fn -> [] end)
    %{clock: clock, replies: replies}
  end

  defp reply(slots, say \\ nil),
    do:
      {:ok,
       %{
         "output" => [
           %{
             "type" => "function_call",
             "call_id" => "c1",
             "name" => "day_plan",
             "arguments" => Jason.encode!(%{"slots" => slots, "say" => say})
           }
         ],
         "usage" => %{"input_tokens" => 100, "output_tokens" => 20}
       }}

  defp profile(%{clock: clock, replies: replies}) do
    test = self()

    %{
      utility: %{day_ms: @day_ms, clock: fn -> Agent.get(clock, & &1) end},
      endpoint: %{model: "test-model"},
      tools: %{},
      skills: %{build: %{}, gather: %{}, travel: %{}},
      request: fn _endpoint, body ->
        send(test, {:request, body})

        Agent.get_and_update(replies, fn
          [next | rest] -> {next, rest}
          [] -> {reply(@plan), []}
        end)
      end
    }
  end

  defp start(ctx, now, replies) do
    Agent.update(ctx.clock, fn _ -> now end)
    Agent.update(ctx.replies, fn _ -> replies end)
    {:ok, pid} = DayPlan.start_link(self(), %{cid: 1, name: "阿青"}, profile(ctx))
    pid
  end

  defp speech(text \\ "你好", kind \\ 0),
    do: %{
      conversation_id: 42,
      turn: 1,
      speaker_id: 7,
      speaker_epoch: 1,
      speaker_kind: kind,
      speaker_name: "玩家甲",
      target_id: 1,
      at_ms: 0,
      text: text
    }

  defp fail(id, verb \\ :travel, reason \\ :no_path),
    do: %{id: id, verb: verb, status: :rejected, reason: reason, data: nil}

  defp done(id), do: %{id: id, verb: :travel, status: :done, reason: nil, data: %{}}

  describe "N2 日计划" do
    test "接受的计划：按应答的次序与边界发给 owner", ctx do
      start(ctx, 0, [reply(@plan)])
      assert_receive {:request, _}
      assert_receive {:day_plan, %{day: 0, slots: slots}}

      assert slots == [
               {0, 300, "rest", "home"},
               {300, 650, "work", nil},
               {650, 800, "social", "plaza"},
               {800, 1000, "rest", "home"}
             ]
    end

    test "缺口、重叠、未知活动、未知去处、不到 1000、没有工具调用：整份拒绝并记原因，不发计划", ctx do
      bad = [
        {[
           %{"from" => 0, "to" => 300, "activity" => "rest", "target" => nil},
           %{"from" => 400, "to" => 1000, "activity" => "work", "target" => nil}
         ], "gap"},
        {[
           %{"from" => 0, "to" => 500, "activity" => "rest", "target" => nil},
           %{"from" => 400, "to" => 1000, "activity" => "work", "target" => nil}
         ], "overlap"},
        {[%{"from" => 0, "to" => 1000, "activity" => "dance", "target" => nil}],
         "unknown_activity"},
        {[%{"from" => 0, "to" => 1000, "activity" => "rest", "target" => "mine"}],
         "unknown_target"},
        {[%{"from" => 0, "to" => 900, "activity" => "rest", "target" => nil}],
         "not_covering_day"},
        {[%{"from" => 100, "to" => 1000, "activity" => "rest", "target" => nil}], "gap"}
      ]

      text_only =
        {:ok,
         %{
           "output" => [%{"type" => "message"}],
           "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
         }}

      for {slots, why} <- bad do
        log =
          capture_log([level: :info], fn ->
            pid = start(ctx, 0, [reply(slots), text_only])
            assert_receive {:request, _}

            # 同步点：第二次请求开始说明第一次的应答已处理完（第二次应答同样不合格）。
            DayPlan.speech(pid, speech())
            assert_receive {:request, _}
            ref = Process.monitor(pid)
            Process.unlink(pid)
            Process.exit(pid, :kill)
            assert_receive {:DOWN, ^ref, _, _, _}
          end)

        assert log =~ "npc_day_plan_rejected cid=1 day=0 reason={:invalid, :#{why}} trigger=plan"
        refute_received {:day_plan, _}
      end

      assert {:error, {:invalid, :no_day_plan_call}} = DayPlan.parse(elem(text_only, 1))
    end

    test "同一天再到 :day 不请求；进入第二天恰好再请求一次", ctx do
      pid = start(ctx, 10, [reply(@plan), reply(@plan)])
      assert_receive {:request, _}
      assert_receive {:day_plan, %{day: 0}}

      send(pid, :day)
      Agent.update(ctx.clock, fn _ -> @day_ms + 5 end)
      send(pid, :day)
      send(pid, :day)

      assert_receive {:request, _}
      assert_receive {:day_plan, %{day: 1}}

      # 同步点：第 1 天的升级请求证明前面的 :day 都已处理，期间只有上面那一次计划请求。
      DayPlan.speech(pid, speech())
      assert_receive {:request, %{instructions: instructions}}
      assert instructions =~ "刚对你说"
      refute_received {:request, _}
    end

    test "Runtime 为带 utility + endpoint 的 profile 起 DayPlan，并把被接受的计划挂到自己的 observe 上", ctx do
      Agent.update(ctx.clock, fn _ -> 400_000 end)

      Agent.update(ctx.replies, fn _ ->
        [reply([%{"from" => 0, "to" => 1000, "activity" => "avoid", "target" => nil}])]
      end)

      profile =
        Map.merge(profile(ctx), %{
          tree: &NpcServer.Trees.settler/1,
          definition: String.duplicate("AB", 32),
          sites: [],
          revisit_ticks: 600
        })

      runtime = Runtime.init({NpcServer.Brain.Tree, profile}, %{cid: 1, name: "阿青"})
      assert_receive {:request, _}
      assert %{plan: %{day: 0, slots: [{0, 1000, "avoid", nil}]}} = wait_plan(runtime, 100)
    end
  end

  describe "N3 升级" do
    test "同一失败连续 3 次恰好请求一次；2 次不请求；中间成功清零", ctx do
      pid = start(ctx, 0, [reply(@plan)])
      assert_receive {:request, _}

      # 2 次 + 成功 + 2 次：都不到 3 次连续。不同原因也不连续。
      for o <- [fail(1), fail(2), done(3), fail(4), fail(5), fail(6, :travel, :blocked)],
          do: DayPlan.outcome(pid, o)

      # 非整数 id（日计划自己的 say）不计入。
      DayPlan.outcome(pid, fail({:day_plan, 1}, :say, :rate_limited))
      DayPlan.speech(pid, speech())
      assert_receive {:request, %{instructions: i}}
      assert i =~ "刚对你说"

      for id <- 7..9, do: DayPlan.outcome(pid, fail(id))
      assert_receive {:request, %{instructions: i}}
      assert i =~ "连续 3 次做 travel 都失败了，原因 :no_path"

      DayPlan.speech(pid, speech())
      assert_receive {:request, %{instructions: i}}
      assert i =~ "刚对你说"
      refute_received {:request, _}
    end

    test "玩家直接说话：一次请求，应答的 say 回复该会话；NPC 说话不触发", ctx do
      pid = start(ctx, 500_000, [reply(@plan), reply(@plan, "好的，我先歇会儿。")])
      assert_receive {:request, _}

      DayPlan.speech(pid, speech("我是 NPC", 1))
      DayPlan.speech(pid, speech("你好"))
      assert_receive {:request, %{input: input}}
      assert %{"now_permille" => 500, "current_plan" => [_, _, _, _]} = Jason.decode!(input)

      assert_receive {:"$gen_cast",
                      {:command,
                       %{
                         id: {:day_plan, 1},
                         verb: :say,
                         text: "好的，我先歇会儿。",
                         target_id: 7,
                         conversation_id: 42
                       }}}

      refute_received {:request, _}
    end

    test "当日额度用完（1 计划 + 4 升级）：第 6 次触发不请求并记 exhausted", ctx do
      log =
        capture_log([level: :info], fn ->
          pid = start(ctx, 0, [])
          assert_receive {:request, _}
          for _ <- 1..4, do: DayPlan.speech(pid, speech())
          for _ <- 1..4, do: assert_receive({:request, _})

          DayPlan.speech(pid, speech())

          # 先等它处理完第 6 次（邮箱空且阻塞在 receive），再换日：否则可能在第二天才处理而额度已清零。
          idle(pid, 100)
          refute_received {:request, _}
          # 进入第二天，额度清零，计划请求恰好一次。
          Agent.update(ctx.clock, fn _ -> @day_ms end)
          send(pid, :day)
          assert_receive {:request, %{instructions: i}}
          refute i =~ "刚对你说"
          refute_received {:request, _}
        end)

      assert log =~ "npc_llm_day_budget_exhausted cid=1 day=0"
      assert log =~ "npc_llm_usage cid=1 day=0 reason=plan calls=1 in=100 out=20"
      assert log =~ "npc_llm_usage cid=1 day=0 reason=speech calls=5 in=500 out=100"
      assert DayPlan.cap() == 5
    end

    test "重新规划只替换现在之后：千分位 500 处拼接旧计划前段与新计划后段", ctx do
      new = [
        %{"from" => 0, "to" => 400, "activity" => "social", "target" => "plaza"},
        %{"from" => 400, "to" => 900, "activity" => "rest", "target" => "home"},
        %{"from" => 900, "to" => 1000, "activity" => "work", "target" => nil}
      ]

      pid = start(ctx, 500_000, [reply(@plan), reply(new)])
      assert_receive {:day_plan, %{day: 0}}
      DayPlan.speech(pid, speech())

      # 旧：0-300 rest，300-650 work，… → 保留 0-300 rest、300-500 work；新：400-900 rest 截成 500-900，900-1000 work。
      assert_receive {:day_plan, %{day: 0, slots: slots}}

      assert slots == [
               {0, 300, "rest", "home"},
               {300, 500, "work", nil},
               {500, 900, "rest", "home"},
               {900, 1000, "work", nil}
             ]
    end

    test "愤怒来源序号变化触发一次；首次读到的是基线，同一序号不再触发", ctx do
      pid = start(ctx, 0, [])
      assert_receive {:request, _}

      calm = State.new(1, "world", 0, 0)
      angry = fn seq -> put_in(calm, ["evidence", "anger"], %{"actor" => 3, "seq" => seq}) end

      DayPlan.life_state(pid, angry.(4))
      DayPlan.life_state(pid, angry.(4))
      DayPlan.life_state(pid, angry.(5))
      DayPlan.life_state(pid, angry.(5))
      assert_receive {:request, %{instructions: i}}
      assert i =~ "被人惹恼"

      DayPlan.speech(pid, speech())
      assert_receive {:request, %{instructions: i}}
      assert i =~ "刚对你说"
      refute_received {:request, _}
    end
  end

  # 可观察条件：邮箱为空且进程阻塞在 receive，即此前发给它的消息都已处理完。
  defp idle(pid, tries) do
    case Process.info(pid, [:message_queue_len, :status]) do
      [message_queue_len: 0, status: :waiting] ->
        :ok

      _ when tries > 0 ->
        Process.sleep(10)
        idle(pid, tries - 1)
    end
  end

  defp wait_plan(runtime, tries) do
    case Runtime.observe(runtime) do
      %{plan: nil} when tries > 0 ->
        Process.sleep(10)
        wait_plan(runtime, tries - 1)

      reply ->
        reply
    end
  end
end
