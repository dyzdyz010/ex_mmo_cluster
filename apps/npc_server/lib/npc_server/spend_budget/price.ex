defmodule NpcServer.SpendBudget.Price do
  @moduledoc """
  花费额度的纯函数：一次模型调用的 token 合不合法、花多少钱、落在高峰还是非高峰、归哪个北京自然日，以及当日后台开还是停的判定。
  进程、库与 HTTP 都不在这里（所有权在 `NpcServer.SpendBudget`）。

  ## 计量口径（决策稿 §7，2026-11-19 统筹会话定）

  一次调用的 token 交成 `%{input:, cached:, output:, thoughts:}`：`input` 含命中部分，`cached` 是其中的命中，
  `thoughts` 是**没有**算进 `output` 的思考 token。花费 = (input − cached) × 未命中价 + cached × 命中价 + (output + thoughts) × 输出价。
  Hindsight 的追踪行思考单列（OpenAI 兼容通道的 `output_tokens` 不含思考），产品回执的输出已含推理（`thoughts` 交 0）。

  四项必须是非负整数且命中不多于输入（`tokens/1`）：这是计价公式不出负数的前提。两个来源在各自的信任边界调同一个 `tokens/1`——
  产品回执在 `NpcServer.ModelUsage`（不合法的那一笔记为未定价），Hindsight 追踪行在 `Life.Hindsight.llm_requests/3`（不合法整次读失败）；
  之后 `charge/4` 与 `cost/2` 只收合法的四项，不再复核。

  金额用整数：价目在配置边界折成每 token 多少 pico-USD（10⁻¹² 美元，`SpendBudget.Config`），一次调用的总额折成 nano-USD
  （10⁻⁹ 美元）时**向上**取整——宁多计不少计（额度是用户定的硬约束）。

  ## 定档与归日

  按调用的**完成时刻**（Hindsight 行的 `ended_at`、产品回执到达的时刻）定档与归日，统筹会话定：DeepSeek 官方价目页
  （2026-11-19 核对）只写了时段，没写按请求开始还是结束判定。

  - **定档**按 UTC：官方原文是“Peak hours are 01:00 - 04:00 and 06:00 - 10:00 UTC, Monday through Friday, excluding Chinese public
    holidays”，所以高峰规则是“UTC 的星期几 + UTC 日内分钟段”（`Config` 的 `peak`），其余时刻为非高峰；不配即每一刻都按高峰。
    **中国法定节假日不建模**：节假日的工作日白天按高峰计，最多把这些时段的花费算成两倍（多计，不少计），边界写在决策稿 §7。
  - **归日**按北京时间（固定 UTC+8，Asia/Shanghai 自 1991 年起不用夏令时）：日界只做定长偏移，不查时区库。
  """

  # 北京时间相对 UTC 的固定偏移。
  @offset_ms 8 * 3_600_000
  @day_ms 86_400_000
  # 1970-01-01 是星期四（ISO 星期几 = 4）。
  @epoch_weekday 4

  @typedoc "每 token 的价（pico-USD）。"
  @type rates :: %{miss: non_neg_integer(), hit: non_neg_integer(), out: non_neg_integer()}
  @typedoc "一次调用的 token（见 moduledoc 的计量口径）；只经 `tokens/1` 构造。"
  @type tokens :: %{
          input: non_neg_integer(),
          cached: non_neg_integer(),
          output: non_neg_integer(),
          thoughts: non_neg_integer()
        }
  @typedoc """
  高峰规则：`:always`（每一刻都按高峰）或若干条 `{起始星期, 终止星期, [{起分钟, 止分钟}]}`——星期是 ISO 编号（1 = 周一 … 7 = 周日，
  起 ≤ 止、闭区间），分钟段是 UTC 日内分钟、左闭右开（止可到 1440）。任一条命中即高峰。
  """
  @type peak :: :always | [{1..7, 1..7, [{non_neg_integer(), pos_integer()}]}]

  @doc """
  一次调用的四项 token 的唯一校验：四项都是非负整数、且命中不多于输入 → `{:ok, 原样}`；否则 `:error`。
  产品回执（`NpcServer.ModelUsage`）与 Hindsight 追踪行（`Life.Hindsight.llm_requests/3`）都在接纳处调它。
  """
  @spec tokens(map()) :: {:ok, tokens()} | :error
  def tokens(%{input: input, cached: cached, output: output, thoughts: thoughts} = tokens)
      when is_integer(input) and input >= 0 and is_integer(cached) and cached >= 0 and
             cached <= input and is_integer(output) and output >= 0 and is_integer(thoughts) and
             thoughts >= 0,
      do: {:ok, tokens}

  def tokens(_), do: :error

  @doc """
  按配置的价目给一次调用计价：`{:ok, nano_usd}`；模型不在价目表里（或回执里没有模型名）→ `:unpriced`。
  档位由 `ended_ms`（完成时刻，Unix 毫秒）按配置的高峰规则定。
  """
  @spec charge(NpcServer.SpendBudget.Config.t(), String.t() | nil, tokens(), integer()) ::
          {:ok, non_neg_integer()} | :unpriced
  def charge(config, model, tokens, ended_ms) do
    case Map.fetch(config.prices, model) do
      {:ok, table} -> {:ok, cost(Map.fetch!(table, tier(config.peak, ended_ms)), tokens)}
      :error -> :unpriced
    end
  end

  @doc "按一档价目计一次调用的 nano-USD（向上取整）。"
  @spec cost(rates(), tokens()) :: non_neg_integer()
  def cost(rates, %{input: input, cached: cached, output: output, thoughts: thoughts}) do
    pico = (input - cached) * rates.miss + cached * rates.hit + (output + thoughts) * rates.out
    div(pico + 999, 1000)
  end

  @doc "完成时刻 `ms` 落在哪一档：命中任一条高峰规则（UTC 星期几 + UTC 日内分钟段，左闭右开）为 `:peak`，否则 `:off_peak`。"
  @spec tier(peak(), integer()) :: :peak | :off_peak
  def tier(:always, _ms), do: :peak

  def tier(rules, ms) do
    days = Integer.floor_div(ms, @day_ms)
    weekday = Integer.mod(days + @epoch_weekday - 1, 7) + 1
    minute = div(Integer.mod(ms, @day_ms), 60_000)

    peak? =
      Enum.any?(rules, fn {first, last, segments} ->
        weekday >= first and weekday <= last and
          Enum.any?(segments, fn {from, to} -> minute >= from and minute < to end)
      end)

    if peak?, do: :peak, else: :off_peak
  end

  @doc "时刻 `ms`（Unix 毫秒）所属的北京自然日。"
  @spec day(integer()) :: Date.t()
  def day(ms), do: Date.add(~D[1970-01-01], Integer.floor_div(ms + @offset_ms, @day_ms))

  @doc "北京自然日 `day` 零点的 Unix 毫秒。"
  @spec day_start_ms(Date.t()) :: integer()
  def day_start_ms(day), do: Date.diff(day, ~D[1970-01-01]) * @day_ms - @offset_ms

  @doc "`ms` 之后的下一个北京零点（Unix 毫秒）；`ms` 恰在零点时给再下一个。"
  @spec next_day_ms(integer()) :: integer()
  def next_day_ms(ms), do: day_start_ms(Date.add(day(ms), 1))

  @doc """
  当日后台的判定，按先后：当日总额 `total` 为 nil（当日账本还没读到：启动或换日时读失败）→ `{:paused, :unmeasured}`；
  `total` ≥ 停止线 `stop`（恰等即停）→ `{:paused, :limit}`；当日有没能计价的行（`unpriced > 0`）→ `{:paused, :unpriced}`；
  Hindsight 用量已连续 `read_age_ms` 没读全、或有行已连续 `unsaved_age_ms` 写不进账本，任一 ≥ `unmeasured_ms` →
  `{:paused, :unmeasured}`；否则 `:open`。`total` 已含写不进账本的行（花了就是花了），所以写不进时停止线照样管用。
  “无法计量即停后台”是原创决策（已报用户）：宁停后台不少计。
  """
  @spec verdict(%{
          total: non_neg_integer() | nil,
          stop: non_neg_integer(),
          unpriced: non_neg_integer(),
          read_age_ms: integer(),
          unsaved_age_ms: non_neg_integer(),
          unmeasured_ms: pos_integer()
        }) :: :open | {:paused, :limit | :unpriced | :unmeasured}
  def verdict(%{total: total, stop: stop, unpriced: unpriced} = facts) do
    cond do
      total == nil -> {:paused, :unmeasured}
      total >= stop -> {:paused, :limit}
      unpriced > 0 -> {:paused, :unpriced}
      facts.read_age_ms >= facts.unmeasured_ms -> {:paused, :unmeasured}
      facts.unsaved_age_ms >= facts.unmeasured_ms -> {:paused, :unmeasured}
      true -> :open
    end
  end
end
