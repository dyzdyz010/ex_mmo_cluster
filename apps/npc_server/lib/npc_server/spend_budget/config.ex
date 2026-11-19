defmodule NpcServer.SpendBudget.Config do
  @moduledoc """
  花费额度的运行配置：读运行环境的信任边界只在 `load!/1`，校验一次后构造成本结构体，之后 `SpendBudget` 与 `Price`
  直接用，不再解析原始字符串。非法即 raise（`SpendBudget` 在 `init` 调它，NPC 应用随之起不来，release 启动失败）；
  错误消息只点变量名与原因，**不带原值**（价目、模型名、地址都不进日志）。

  “NPC 启用”的判据是运行环境配了 `NPC_LIFE_HINDSIGHT_URL`：额度要读的就是这一台 Hindsight，统一形态（`"npc"`）的 Life
  缺省也连它（`NpcServer.Registry`）。没配 → `:disabled`（不读其余变量；`SpendBudget` 此时按“无法计量”让后台一直停着，
  不设“未配置即不限”的分支）。配了 → 下面几项必填：

  | 变量 | 形状 | 结构体字段 |
  |---|---|---|
  | `NPC_SPEND_LIMIT_USD` | 每天上限（美元，正的十进制数，至多 9 位小数） | `limit_nano` |
  | `NPC_SPEND_STOP_RATIO` | 后台停止线占上限的比例，`(0, 1]` | `stop_nano` = ⌊limit × ratio⌋ |
  | `NPC_SPEND_PRICES` | JSON：`{模型名: {"peak": {"miss", "hit", "out"}, "off_peak": {同}}}`，每百万 token 的美元价，≥ 0、至多 6 位小数 | `prices`（每 token 的 pico-USD） |
  | `NPC_SPEND_PEAK_UTC` | 可缺省：按 UTC 的高峰规则（下述）；缺省即每一刻都按高峰（多计，安全侧） | `peak`（`Price.peak()`） |

  `NPC_SPEND_PEAK_UTC` 的形状：一条或多条规则，分号分隔；每条是 `星期 时段[,时段…]`。星期写一天（`mon` … `sun`）或一段
  （`mon-fri`，起不晚于止，不跨周日到周一——要跨就拆成两条）；时段是 UTC 的 `HH:MM-HH:MM`（左闭右开，可写到 `24:00`，同一条里不重叠）。
  命中任一条为高峰，其余为非高峰。DeepSeek 官方（决策稿 §7 原文）写作 `mon-fri 01:00-04:00,06:00-10:00`。
  中国法定节假日不建模（节假日工作日的白天按高峰计：多计，不少计）。

  Hindsight 地址的合法性与选择位置模型名所在的变量都按 `NpcServer.Registry` 的同一份规则（`Registry.hindsight_url/1`、
  `Registry.jev_model_env/1`）：额度读的就是登记给 Life 的那一台 Hindsight，核的就是登记时 Jev endpoint 用的那个模型名。
  另核产品经 `NpcServer.ModelUsage` 发出的模型都在价目表里：选择位置与写作位置（`NPC_REFLECT_MODEL`），配了哪个核哪个；
  `ModelUsage` 按请求时配置的模型名计价（不按应答里回报的名字），所以这里核过的名字就是计价时查表的名字。
  Hindsight 自己用的模型不在产品的运行环境里，读回时遇到价目表没有的模型由 `SpendBudget` 按 `:unpriced` 停后台。
  """

  @enforce_keys [:hindsight_url, :limit_nano, :stop_nano, :prices, :peak]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          hindsight_url: String.t(),
          limit_nano: pos_integer(),
          stop_nano: pos_integer(),
          prices: %{String.t() => %{peak: rates(), off_peak: rates()}},
          peak: NpcServer.SpendBudget.Price.peak()
        }
  @type rates :: NpcServer.SpendBudget.Price.rates()

  @nano 1_000_000_000
  # 每百万 token 的美元价 → 每 token 的 pico-USD：p / 10⁶ × 10¹² = p × 10⁶。
  @pico_per_usd_per_million 1_000_000
  @weekdays %{"mon" => 1, "tue" => 2, "wed" => 3, "thu" => 4, "fri" => 5, "sat" => 6, "sun" => 7}

  @doc "读运行环境（缺省 `System.get_env/0`）构造配置；没配 `NPC_LIFE_HINDSIGHT_URL` 为 `:disabled`。非法即 raise `ArgumentError`。"
  @spec load!(%{String.t() => String.t()}) :: t() | :disabled
  def load!(env \\ System.get_env()) do
    case Map.fetch(env, "NPC_LIFE_HINDSIGHT_URL") do
      :error ->
        :disabled

      {:ok, url} ->
        limit = limit!(env)
        prices = prices!(env)
        products!(env, prices)

        %__MODULE__{
          hindsight_url: url!(url),
          limit_nano: limit,
          stop_nano: stop!(env, limit),
          prices: prices,
          peak: peak!(env)
        }
    end
  end

  defp url!(url) do
    case NpcServer.Registry.hindsight_url(url) do
      {:ok, url} -> url
      :error -> invalid!("NPC_LIFE_HINDSIGHT_URL", "必须是主机非空、不带用户信息的 http / https 地址")
    end
  end

  defp limit!(env) do
    with {:ok, text} <- Map.fetch(env, "NPC_SPEND_LIMIT_USD"),
         {:ok, usd} <- decimal(text),
         true <- Decimal.gt?(usd, 0),
         {:ok, nano} <- scaled(usd, @nano) do
      nano
    else
      _ -> invalid!("NPC_SPEND_LIMIT_USD", "必填，正的美元数，至多 9 位小数")
    end
  end

  defp stop!(env, limit) do
    with {:ok, text} <- Map.fetch(env, "NPC_SPEND_STOP_RATIO"),
         {:ok, ratio} <- decimal(text),
         true <- Decimal.gt?(ratio, 0) and not Decimal.gt?(ratio, 1),
         stop when stop > 0 <-
           Decimal.mult(limit, ratio) |> Decimal.round(0, :floor) |> Decimal.to_integer() do
      stop
    else
      _ -> invalid!("NPC_SPEND_STOP_RATIO", "必填，(0, 1] 之间的比例，且停止线不为 0")
    end
  end

  defp prices!(env) do
    name = "NPC_SPEND_PRICES"

    with {:ok, text} <- Map.fetch(env, name),
         {:ok, %{} = table} when map_size(table) > 0 <- Jason.decode(text, floats: :decimals) do
      Map.new(table, fn {model, tiers} -> {model, tiers!(tiers)} end)
    else
      _ -> invalid!(name, "必填，非空 JSON 对象：{模型名: {\"peak\": …, \"off_peak\": …}}")
    end
  end

  defp tiers!(%{"peak" => peak, "off_peak" => off_peak} = tiers) when map_size(tiers) == 2,
    do: %{peak: rates!(peak), off_peak: rates!(off_peak)}

  defp tiers!(_),
    do: invalid!("NPC_SPEND_PRICES", "每个模型恰有 peak 与 off_peak 两档")

  defp rates!(%{"miss" => miss, "hit" => hit, "out" => out} = rates) when map_size(rates) == 3,
    do: %{miss: rate!(miss), hit: rate!(hit), out: rate!(out)}

  defp rates!(_),
    do: invalid!("NPC_SPEND_PRICES", "每档恰有 miss / hit / out 三项")

  defp rate!(value) do
    with {:ok, price} <- number(value),
         false <- Decimal.negative?(price),
         {:ok, pico} <- scaled(price, @pico_per_usd_per_million) do
      pico
    else
      _ -> invalid!("NPC_SPEND_PRICES", "价是每百万 token 的美元数，≥ 0、至多 6 位小数")
    end
  end

  defp products!(env, prices) do
    for name <- [NpcServer.Registry.jev_model_env(env["NPC_JEV_API"]), "NPC_REFLECT_MODEL"],
        model = env[name],
        model != nil,
        not Map.has_key?(prices, model),
        do: invalid!(name, "这个产品模型不在 NPC_SPEND_PRICES 的价目表里")

    :ok
  end

  defp peak!(env) do
    case Map.fetch(env, "NPC_SPEND_PEAK_UTC") do
      :error -> :always
      {:ok, text} -> text |> String.split(";") |> Enum.map(&peak_rule!/1)
    end
  end

  # 一条规则：`星期 时段[,时段…]`，时段按起点排序后不得重叠。
  defp peak_rule!(text) do
    with [days, segments] <- text |> String.trim() |> String.split(~r/\s+/, parts: 2),
         {:ok, first, last} <- weekdays(days) do
      segments = segments |> String.split(",") |> Enum.map(&segment!/1) |> Enum.sort()

      segments
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [{_, to}, {from, _}] ->
        if from < to, do: invalid!("NPC_SPEND_PEAK_UTC", "同一条规则里的时段不能重叠")
      end)

      {first, last, segments}
    else
      _ ->
        invalid!(
          "NPC_SPEND_PEAK_UTC",
          "每条规则是“星期 时段[,时段…]”，星期写 mon … sun 或 mon-fri 这样的一段（不跨周日到周一）"
        )
    end
  end

  defp weekdays(text) do
    case String.split(text, "-") do
      [day] -> weekday_range(@weekdays[day], @weekdays[day])
      [first, last] -> weekday_range(@weekdays[first], @weekdays[last])
      _ -> :error
    end
  end

  defp weekday_range(first, last) when is_integer(first) and is_integer(last) and first <= last,
    do: {:ok, first, last}

  defp weekday_range(_, _), do: :error

  defp segment!(text) do
    with [_, h1, m1, h2, m2] <-
           Regex.run(~r/\A\s*(\d\d):(\d\d)-(\d\d):(\d\d)\s*\z/, text),
         from = minute(h1, m1),
         to = minute(h2, m2),
         true <- from != nil and to != nil and from < to and from < 1440 do
      {from, to}
    else
      _ ->
        invalid!("NPC_SPEND_PEAK_UTC", "时段是 UTC 的 HH:MM-HH:MM，逗号分隔，起点早于终点，终点至多 24:00")
    end
  end

  defp minute(hour, minute) do
    {hour, minute} = {String.to_integer(hour), String.to_integer(minute)}

    cond do
      hour == 24 and minute == 0 -> 1440
      hour < 24 and minute < 60 -> hour * 60 + minute
      true -> nil
    end
  end

  defp decimal(text) when is_binary(text) do
    case Decimal.parse(String.trim(text)) do
      {decimal, ""} ->
        if Decimal.inf?(decimal) or Decimal.nan?(decimal), do: :error, else: {:ok, decimal}

      _ ->
        :error
    end
  end

  defp number(value) when is_integer(value), do: {:ok, Decimal.new(value)}
  defp number(%Decimal{} = value), do: {:ok, value}
  defp number(_), do: :error

  # 乘上倍数后必须是整数（小数位超过精度即拒，不静默截断）。
  defp scaled(decimal, factor) do
    scaled = Decimal.mult(decimal, factor)
    if Decimal.integer?(scaled), do: {:ok, Decimal.to_integer(scaled)}, else: :error
  end

  defp invalid!(name, reason), do: raise(ArgumentError, "#{name} 不合法：#{reason}")
end
