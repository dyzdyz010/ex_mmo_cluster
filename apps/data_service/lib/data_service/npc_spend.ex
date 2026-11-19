defmodule DataService.NpcSpend do
  @moduledoc """
  全局系统功能：NPC 模型花费的账本（`npc_spend_ledger` 表），按北京自然日累计，进程重启不清零。唯一写入方是
  `NpcServer.SpendBudget`（花费额度的 owner）；本模块只做存取，不计价、不判定（计价与判定在 `NpcServer.SpendBudget.Price`）。

  一行一次模型调用：`source` 是 `"product"`（产品经 `NpcServer.ModelUsage` 发出的请求）或 `"hindsight"`（Hindsight 的 LLM 追踪行），
  `source_id` 在同一来源里唯一（`unique(source, source_id)`：重读同一行只记一次）；`day` 是按完成时刻归的北京自然日；
  `nano_usd` 是按价目折出的 nano-USD，null = 未定价。只保留最近 7 天（`prune/1`，由 owner 在启动与切日时调用）。

  与 `DataService.NpcMemory` 同范式：直接走 `DataService.Repo` 的模块函数；数据库失败照常 raise，由调用方决定怎么处理。
  """
  import Ecto.Query, only: [from: 2]
  alias DataService.Repo

  @table "npc_spend_ledger"

  @typedoc "一行（插入时的形状；`inserted_at` 由本模块填）。时刻是 UTC 的 `DateTime`。"
  @type row :: %{
          source: String.t(),
          source_id: String.t(),
          bank: String.t() | nil,
          operation: String.t() | nil,
          model: String.t() | nil,
          day: Date.t(),
          started_at: DateTime.t(),
          ended_at: DateTime.t(),
          input_tokens: non_neg_integer(),
          cached_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          thoughts_tokens: non_neg_integer(),
          nano_usd: non_neg_integer() | nil
        }

  @doc """
  插入一批行，已有同一 `{source, source_id}` 的跳过（`ON CONFLICT DO NOTHING`）；返回**真正新插入**的行
  `[%{source:, source_id:, model:, day:, nano_usd:}]`——调用方只把这些累加进当日总额，重读不重计。
  """
  @spec insert_new([row()]) :: [map()]
  def insert_new([]), do: []

  def insert_new(rows) when is_list(rows) do
    now = DateTime.utc_now()

    {_, inserted} =
      Repo.insert_all(@table, Enum.map(rows, &Map.put(&1, :inserted_at, now)),
        on_conflict: :nothing,
        conflict_target: [:source, :source_id],
        returning: [:source, :source_id, :model, :day, :nano_usd]
      )

    inserted
  end

  @doc "北京自然日 `day` 的累计：`%{product: nano, hindsight: nano, unpriced: 未定价行数}`（没有行为 0）。"
  @spec day_totals(Date.t()) :: %{
          product: non_neg_integer(),
          hindsight: non_neg_integer(),
          unpriced: non_neg_integer()
        }
  def day_totals(%Date{} = day) do
    rows =
      Repo.all(
        from(l in @table,
          where: l.day == ^day,
          group_by: l.source,
          select:
            {l.source, fragment("COALESCE(SUM(?), 0)::bigint", l.nano_usd),
             fragment("COUNT(*) - COUNT(?)", l.nano_usd)}
        )
      )

    Enum.reduce(rows, %{product: 0, hindsight: 0, unpriced: 0}, fn {source, nano, unpriced},
                                                                   acc ->
      key = if source == "product", do: :product, else: :hindsight
      %{acc | key => acc[key] + nano, unpriced: acc.unpriced + unpriced}
    end)
  end

  @doc """
  Hindsight 各库已入账的读回游标：`%{bank => 最晚一行的 started_at（Unix 毫秒）}`，只看 `since` 及以后各日的行
  （owner 重启时从这里接着读，往回多读一段由 owner 定）。
  """
  @spec bank_watermarks(Date.t()) :: %{String.t() => integer()}
  def bank_watermarks(%Date{} = since) do
    Repo.all(
      from(l in @table,
        where: l.source == "hindsight" and l.day >= ^since and not is_nil(l.bank),
        group_by: l.bank,
        select: {l.bank, max(l.started_at)}
      )
    )
    |> Map.new(fn {bank, at} -> {bank, unix_ms(at)} end)
  end

  @doc "删掉 `before` 之前（不含）各日的行，返回删了几行。"
  @spec prune(Date.t()) :: non_neg_integer()
  def prune(%Date{} = before) do
    {count, _} = Repo.delete_all(from(l in @table, where: l.day < ^before))
    count
  end

  # 无 schema 的查询把 timestamp 列读成 NaiveDateTime（UTC）。
  defp unix_ms(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)

  defp unix_ms(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)
end
