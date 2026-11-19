defmodule NpcServer.SpendBudget.Price do
  @moduledoc """
  花费额度的纯函数：一次模型调用花多少钱、落在高峰还是非高峰、归哪个北京自然日，以及当日后台开还是停的判定。
  进程、库与 HTTP 都不在这里（所有权在 `NpcServer.SpendBudget`）。

  ## 计量口径（决策稿 §7，2026-11-19 统筹会话定）

  一次调用的 token 交成 `%{input:, cached:, output:, thoughts:}`：`input` 含命中部分，`cached` 是其中的命中，
  `thoughts` 是**没有**算进 `output` 的思考 token。花费 = (input − cached) × 未命中价 + cached × 命中价 + (output + thoughts) × 输出价。
  Hindsight 的追踪行思考单列（OpenAI 兼容通道的 `output_tokens` 不含思考），产品回执的输出已含推理（`thoughts` 交 0）。

  金额用整数：价目在配置边界折成每 token 多少 pico-USD（10⁻¹² 美元，`SpendBudget.Config`），一次调用的总额折成 nano-USD
  （10⁻⁹ 美元）时**向上**取整——宁多计不少计（额度是用户定的硬约束）。

  ## 定档与归日

  按调用的**完成时刻**（Hindsight 行的 `ended_at`、产品回执到达的时刻）定档与归日，统筹会话定：DeepSeek 官方价目页
  （2026-11-19 核对）只写了时段，没写按请求开始还是结束判定。北京时间固定 UTC+8（Asia/Shanghai 自 1991 年起不用夏令时），
  所以日界与时段只做定长偏移，不查时区库。非高峰时段是北京时间的日内分钟段（左闭右开），不配即全天按高峰。
  """

  # 北京时间相对 UTC 的固定偏移。
  @offset_ms 8 * 3_600_000
  @day_ms 86_400_000

  @typedoc "每 token 的价（pico-USD）。"
  @type rates :: %{miss: non_neg_integer(), hit: non_neg_integer(), out: non_neg_integer()}
  @typedoc "一次调用的 token（见 moduledoc 的计量口径）。"
  @type tokens :: %{
          input: non_neg_integer(),
          cached: non_neg_integer(),
          output: non_neg_integer(),
          thoughts: non_neg_integer()
        }

  @doc """
  按配置的价目给一次调用计价：`{:ok, nano_usd}`；模型不在价目表里（或回执里没有模型名）→ `:unpriced`。
  档位由 `ended_ms`（完成时刻，Unix 毫秒）在北京时间里的时段定。
  """
  @spec charge(NpcServer.SpendBudget.Config.t(), String.t() | nil, tokens(), integer()) ::
          {:ok, non_neg_integer()} | :unpriced
  def charge(config, model, tokens, ended_ms) do
    case Map.fetch(config.prices, model) do
      {:ok, table} -> {:ok, cost(Map.fetch!(table, tier(config.off_peak, ended_ms)), tokens)}
      :error -> :unpriced
    end
  end

  @doc "按一档价目计一次调用的 nano-USD（向上取整）。"
  @spec cost(rates(), tokens()) :: non_neg_integer()
  def cost(rates, %{input: input, cached: cached, output: output, thoughts: thoughts}) do
    pico = (input - cached) * rates.miss + cached * rates.hit + (output + thoughts) * rates.out
    div(pico + 999, 1000)
  end

  @doc "完成时刻 `ms` 落在哪一档：在任一非高峰分钟段（北京时间，左闭右开）里为 `:off_peak`，否则 `:peak`。"
  @spec tier([{non_neg_integer(), pos_integer()}], integer()) :: :peak | :off_peak
  def tier(off_peak, ms) do
    minute = div(Integer.mod(ms + @offset_ms, @day_ms), 60_000)

    if Enum.any?(off_peak, fn {from, to} -> minute >= from and minute < to end),
      do: :off_peak,
      else: :peak
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
  当日后台的判定，按先后：当日总额 `total` ≥ 停止线 `stop`（恰等即停）→ `{:paused, :limit}`；当日有没能计价的行
  （`unpriced > 0`）→ `{:paused, :unpriced}`；Hindsight 用量已连续 `read_age_ms` ≥ `unmeasured_ms` 没读全 → `{:paused, :unmeasured}`；
  否则 `:open`。后两条是“无法计量即停后台”（原创决策，已报用户）：宁停后台不少计。
  """
  @spec verdict(%{
          total: non_neg_integer(),
          stop: non_neg_integer(),
          unpriced: non_neg_integer(),
          read_age_ms: integer(),
          unmeasured_ms: pos_integer()
        }) :: :open | {:paused, :limit | :unpriced | :unmeasured}
  def verdict(%{total: total, stop: stop, unpriced: unpriced} = facts) do
    cond do
      total >= stop -> {:paused, :limit}
      unpriced > 0 -> {:paused, :unpriced}
      facts.read_age_ms >= facts.unmeasured_ms -> {:paused, :unmeasured}
      true -> :open
    end
  end
end
