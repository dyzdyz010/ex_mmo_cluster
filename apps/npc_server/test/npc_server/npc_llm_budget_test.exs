defmodule NpcServer.LlmBudgetTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias NpcServer.LlmBudget

  @day_ms 1_000

  test "cap 3：同日第 4 次被拒，次日清零后再放行" do
    # 第 0 天（0..999 ms）放行 3 次，每次放行后记一次调用。
    budget =
      Enum.reduce([0, 100, 999], LlmBudget.new(), fn now, b ->
        assert {:ok, b} = LlmBudget.admit(b, now, 3, @day_ms, 7)
        LlmBudget.record(b, %{"input_tokens" => 1, "output_tokens" => 1}, :test, 7)
      end)

    assert budget.calls == 3
    assert {:error, :day_budget_exhausted} = LlmBudget.admit(budget, 999, 3, @day_ms, 7)

    # 第 1 天（1000 ms 起）：日号 div(1000, 1000) = 1，计数与 token 全部清零。
    assert {:ok, next} = LlmBudget.admit(budget, 1_000, 3, @day_ms, 7)
    assert next == %{day: 1, calls: 0, input_tokens: 0, output_tokens: 0}
  end

  test "拒绝时记 npc_llm_day_budget_exhausted，带 cid 与日号" do
    full = %{day: 2, calls: 3, input_tokens: 0, output_tokens: 0}

    log =
      capture_log(fn ->
        assert {:error, :day_budget_exhausted} = LlmBudget.admit(full, 2_500, 3, @day_ms, 42)
      end)

    assert log =~ "npc_llm_day_budget_exhausted cid=42 day=2"
  end

  test "token 按两次 usage 累加" do
    b = %{day: 0, calls: 0, input_tokens: 0, output_tokens: 0}
    b = LlmBudget.record(b, %{"input_tokens" => 120, "output_tokens" => 30, "total_tokens" => 150}, :plan, 1)
    b = LlmBudget.record(b, %{"input_tokens" => 80, "output_tokens" => 5, "total_tokens" => 85}, :plan, 1)

    # 120 + 80 = 200；30 + 5 = 35。
    assert b == %{day: 0, calls: 2, input_tokens: 200, output_tokens: 35}
  end

  test "用量日志含 reason 与 cid" do
    b = %{day: 5, calls: 0, input_tokens: 0, output_tokens: 0}

    log =
      capture_log(fn ->
        LlmBudget.record(b, %{"input_tokens" => 10, "output_tokens" => 4}, :escalation, 99)
      end)

    assert log =~ "npc_llm_usage cid=99 day=5 reason=escalation calls=1 in=10 out=4"
  end
end
