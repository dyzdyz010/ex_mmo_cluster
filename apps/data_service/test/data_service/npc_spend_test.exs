defmodule DataService.NpcSpendTest do
  @moduledoc """
  只测试（存储层，DB-backed）：NPC 模型花费账本的去重插入、按日累计、读回游标与保留期。
  行的形状同 `NpcServer.SpendBudget` 写入的那种（产品回执行与 Hindsight 追踪行），金额是手写的 nano-USD。
  """
  use ExUnit.Case, async: false
  alias DataService.NpcSpend

  setup_all do
    MmoTest.Database.start!()
    :ok
  end

  setup do
    DataService.Repo.delete_all("npc_spend_ledger")
    :ok
  end

  test "insert_new 只返回真正新插入的行；同一 {source, source_id} 重插不重计" do
    a = row("hindsight", "a", ~D[2026-11-18], 100)
    b = row("hindsight", "b", ~D[2026-11-18], 200)

    assert [%{source_id: "a", nano_usd: 100}, %{source_id: "b", nano_usd: 200}] =
             Enum.sort_by(NpcSpend.insert_new([a, b]), & &1.source_id)

    # 同一批里有已入账的两行（Hindsight 回看重读）和一行新的；另一来源同名 id 是另一行。
    c = row("hindsight", "c", ~D[2026-11-18], 300)
    p = row("product", "a", ~D[2026-11-18], 7)

    assert [%{source: "hindsight", source_id: "c"}, %{source: "product", source_id: "a"}] =
             Enum.sort_by(NpcSpend.insert_new([a, b, c, p]), & &1.source)

    assert [] == NpcSpend.insert_new([a, c])
    assert [] == NpcSpend.insert_new([])
    assert 4 == DataService.Repo.aggregate("npc_spend_ledger", :count)
  end

  test "day_totals 按来源分开累计，未定价行只计数；别的日子不混进来" do
    NpcSpend.insert_new([
      row("product", "p1", ~D[2026-11-18], 10),
      row("product", "p2", ~D[2026-11-18], 5),
      row("hindsight", "h1", ~D[2026-11-18], 1_000),
      row("hindsight", "h2", ~D[2026-11-18], nil),
      row("hindsight", "h3", ~D[2026-11-19], 99)
    ])

    assert NpcSpend.day_totals(~D[2026-11-18]) == %{product: 15, hindsight: 1_000, unpriced: 1}
    assert NpcSpend.day_totals(~D[2026-11-19]) == %{product: 0, hindsight: 99, unpriced: 0}
    assert NpcSpend.day_totals(~D[2026-11-20]) == %{product: 0, hindsight: 0, unpriced: 0}
  end

  test "bank_watermarks 给各库最晚一行的 started_at，只看 since 及以后；prune 删 before 之前各日" do
    NpcSpend.insert_new([
      row("hindsight", "x1", ~D[2026-11-17], 1, "npc-life-7", ~U[2026-11-17 03:00:00Z]),
      row("hindsight", "x2", ~D[2026-11-18], 1, "npc-life-7", ~U[2026-11-18 02:00:00.123Z]),
      row("hindsight", "x3", ~D[2026-11-18], 1, "npc-life-7", ~U[2026-11-18 01:00:00Z]),
      row("hindsight", "y1", ~D[2026-11-17], 1, "npc-reflect-7", ~U[2026-11-17 05:00:00Z]),
      row("product", "z1", ~D[2026-11-18], 1, nil, ~U[2026-11-18 09:00:00Z])
    ])

    assert NpcSpend.bank_watermarks(~D[2026-11-18]) == %{
             "npc-life-7" => DateTime.to_unix(~U[2026-11-18 02:00:00.123Z], :millisecond)
           }

    assert %{"npc-reflect-7" => _, "npc-life-7" => _} = NpcSpend.bank_watermarks(~D[2026-11-17])

    assert 2 == NpcSpend.prune(~D[2026-11-18])
    assert 3 == DataService.Repo.aggregate("npc_spend_ledger", :count)
  end

  defp row(source, id, day, nano, bank \\ nil, started \\ ~U[2026-11-18 02:00:00Z]) do
    %{
      source: source,
      source_id: id,
      bank: bank,
      operation: "op",
      model: "deepseek-flash",
      day: day,
      started_at: started,
      ended_at: DateTime.add(started, 1, :second),
      input_tokens: 10,
      cached_tokens: 0,
      output_tokens: 1,
      thoughts_tokens: 0,
      nano_usd: nano
    }
  end
end
