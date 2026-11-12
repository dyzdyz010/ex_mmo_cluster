defmodule NpcServer.LlmBudget do
  @moduledoc """
  每个 NPC 每游戏日的 LLM 调用预算与用量日志（纯值，无进程、无配置）。

  - 值：`%{day:, calls:, input_tokens:, output_tokens:}`，全是整数。
  - 日号 = `div(now_ms, day_ms)`，与选择器同一时钟约定：墙钟毫秒按 `day_ms`（缺省 1_440_000 = 现实 24 分钟）分日。
  - `admit/5`：当日已调用 `cap` 次则拒绝并记 `npc_llm_day_budget_exhausted`；跨日先清零再放行。
  - `record/4`：累加一次调用的 token（OpenAI Responses 形 `usage`，与 `Skills.HouseDesign` 读法一致）并记 `npc_llm_usage`。
  - 唯一调用方是 `NpcServer.DayPlan`（日计划与升级）：每次请求前 `admit`、请求后 `record`。`Brain.Llm` 仍只用它自己的每小时额度。
  """
  require Logger

  @default_day_ms 1_440_000

  @type t :: %{
          day: integer(),
          calls: non_neg_integer(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer()
        }

  @doc "默认的游戏日长度（毫秒）。"
  @spec default_day_ms() :: pos_integer()
  def default_day_ms, do: @default_day_ms

  @doc "空预算（尚未进入任何一天；首次 `admit` 会切到当日）。"
  @spec new() :: t()
  def new, do: %{day: -1, calls: 0, input_tokens: 0, output_tokens: 0}

  @doc "当日还有额度则放行，跨日先清零；用完返回 `{:error, :day_budget_exhausted}` 并记日志。"
  @spec admit(t(), integer(), pos_integer(), pos_integer(), term()) ::
          {:ok, t()} | {:error, :day_budget_exhausted}
  def admit(budget, now_ms, cap, day_ms, cid) do
    day = div(now_ms, day_ms)
    budget = if budget.day == day, do: budget, else: %{new() | day: day}

    if budget.calls < cap do
      {:ok, budget}
    else
      Logger.info("npc_llm_day_budget_exhausted cid=#{cid} day=#{day}")
      {:error, :day_budget_exhausted}
    end
  end

  @doc "记一次调用：调用数 +1，token 加上 `usage`，并记 `npc_llm_usage`。"
  @spec record(t(), map(), term(), term()) :: t()
  def record(budget, %{"input_tokens" => input, "output_tokens" => output}, reason, cid) do
    budget = %{
      budget
      | calls: budget.calls + 1,
        input_tokens: budget.input_tokens + input,
        output_tokens: budget.output_tokens + output
    }

    Logger.info(
      "npc_llm_usage cid=#{cid} day=#{budget.day} reason=#{reason} calls=#{budget.calls} " <>
        "in=#{budget.input_tokens} out=#{budget.output_tokens}"
    )

    budget
  end
end
