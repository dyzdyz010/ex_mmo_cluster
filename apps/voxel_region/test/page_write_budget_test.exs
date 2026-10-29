defmodule VoxelRegion.PageWriteBudgetTest do
  @moduledoc """
  只测试：PageCut 的自然单元运输预算。测试进程充当只接收 batch／发 ACK 的 writer，
  没有World物理、数据库或编码替身；被断言的是正式PageCut回调实际发出的自然单元序列。
  预算是未压缩ETF运输字节上界，不是RSS，也不是Pages.row压缩后的PG payload字节。
  小参数只证明算法，不是生产预算参数的性能验收；单元超限反例在产生边界明确失败。
  """
  use ExUnit.Case, async: true
  alias VoxelRegion.World.{PageCut, Pages, PageWriter}

  defmodule FailedPublish do
    @moduledoc "只测试：替代持久发布的错误返回；没有成功发布或回收能力。"
    def publish(_handle, _seq, _rows, _globals), do: {:error, :test_only_publish_failed}
  end

  test "不同大小的少量自然单元按字节分批，不能因未满64条就一起发送" do
    limit = 512
    {state, attempt, expected} = open_cut([12, 15, 14], %{batch_bytes: limit, inflight_bytes: 2_048})
    batches = finish_cut(state, attempt, limit, [])
    assert length(batches) > 1
    assert List.flatten(batches) == expected
  end

  test "尚有批次信用但剩余字节不够时停止发送，ACK释放原预算后继续同一序列" do
    window = 512
    {state, attempt, expected} = open_cut([20, 20, 20], %{batch_bytes: 1_024, inflight_bytes: window})
    assert_receive {:"$gen_cast", {:batch, ^attempt, 1, first}}
    report_batch(state, first, :inflight, window)
    assert byte_size(:erlang.term_to_binary(first)) <= window
    assert PageCut.backlog(state).inflight_bytes <= window
    # 每个含20格世代的单元超过半个窗口：另一条虽符合batch预算，也不能挤进剩余在途空间。
    state = PageCut.handle(state, :page_pump)
    refute_receive {:"$gen_cast", {:batch, ^attempt, _, _}}, 0
    assert PageCut.backlog(state).inflight_bytes <= window
    state = PageCut.handle(state, {:page_ack, attempt})
    remaining = finish_cut(state, attempt, window, [])
    assert List.flatten([first | remaining]) == expected
  end

  test "多批在途按实际总量记账，旧attempt不释放信用，全部ACK前不发布" do
    {state, attempt, expected} = open_cut([20, 20, 20], %{batch_bytes: 512, inflight_bytes: 1_024})
    assert_receive {:"$gen_cast", {:batch, ^attempt, 1, first}}
    state = PageCut.handle(state, :page_pump)
    assert_receive {:"$gen_cast", {:batch, ^attempt, 1, second}}
    state = PageCut.handle(state, :page_pump)
    assert_receive {:"$gen_cast", {:batch, ^attempt, 1, third}}
    batches = [first, second, third]
    bytes = Enum.map(batches, &byte_size(:erlang.term_to_binary(&1)))
    assert Enum.sum(bytes) <= 1_024
    assert PageCut.backlog(state).inflight_bytes == Enum.sum(bytes)
    assert List.flatten(batches) == expected
    assert PageCut.handle(state, {:page_ack, make_ref()}) == state
    state = PageCut.handle(state, :page_pump)
    refute_receive {:"$gen_cast", {:publish, _, _, _, _}}, 0
    state = PageCut.handle(state, {:page_ack, attempt})
    assert PageCut.backlog(state).inflight_bytes == Enum.sum(tl(bytes))
    refute_receive {:"$gen_cast", {:publish, _, _, _, _}}, 0
    state = PageCut.handle(state, {:page_ack, attempt})
    assert PageCut.backlog(state).inflight_bytes == List.last(bytes)
    refute_receive {:"$gen_cast", {:publish, _, _, _, _}}, 0
    state = PageCut.handle(state, {:page_ack, attempt})
    assert_receive {:"$gen_cast", {:publish, ^attempt, 1, [], globals}}
    assert PageCut.backlog(state).inflight_bytes == byte_size(globals)
  end

  test "单个合法自然单元超限在产生端拒绝，不发送超额首批或发布" do
    {state, attempt, [expected]} = new_cut([20], page_write_budget: %{batch_bytes: 298, inflight_bytes: 512})
    bytes = byte_size(:erlang.term_to_binary([expected]))
    assert bytes > 298
    {unit, _} = expected
    assert {^expected, ^bytes} = Pages.write_unit(state.page_store.cut.frozen, unit, bytes)
    assert_raise ArgumentError, ~r/voxel write unit .*#{bytes} > 298/, fn ->
      PageCut.handle(state, {:page_begun, attempt})
    end
    refute_receive {:"$gen_cast", {:batch, _, _, _}}, 0
    refute_receive {:"$gen_cast", {:publish, _, _, _, _}}, 0
    assert state.page_store.published == 0
  end

  test "未配置有限预算仍可运输现格式合法大单元，不暗加512字节默认" do
    {state, attempt, expected} = new_cut([60], [])
    assert byte_size(:erlang.term_to_binary(expected)) > 512
    state = PageCut.handle(state, {:page_begun, attempt})
    assert finish_cut(state, attempt, 10_000, []) |> List.flatten() == expected
  end

  test "最终全局行超在途窗口明确拒绝，不能发布后才报告超限" do
    balances = Map.new(1..200, fn cid -> {{cid, 11}, cid * 100_003} end)
    {state, attempt, []} = new_cut([], [page_write_budget: %{batch_bytes: 512, inflight_bytes: 512}],
      %{material_balances: balances})
    assert byte_size(Pages.globals(state.page_store.cut.frozen)) > 512
    assert_raise ArgumentError, ~r/voxel globals exceed declared write inflight budget/, fn ->
      PageCut.handle(state, {:page_begun, attempt})
    end
    refute_receive {:"$gen_cast", {:publish, _, _, _, _}}, 0
    assert state.page_store.published == 0
  end

  test "持久发布失败只返回原错误，不发送已发布或释放为成功" do
    {state, attempt, _} = new_cut([], [])
    writer = %{world: self(), log: {FailedPublish, :unused}}
    assert {:noreply, ^writer} = PageWriter.handle_cast({:publish, attempt, 1, [], <<>>}, writer)
    assert_receive {:page_failed, ^attempt, :test_only_publish_failed}
    refute_receive {:page_published, _, _}, 0
    assert_raise RuntimeError, ~r/page publish of seq 1 failed/, fn ->
      PageCut.handle(state, {:page_failed, attempt, :test_only_publish_failed})
    end
    assert state.page_store.published == 0
  end

  defp open_cut(counts, limits) do
    {state, attempt, expected} = new_cut(counts, page_write_budget: limits)
    IO.puts("R5_BUDGET_UNITS " <> Jason.encode!(%{limits: limits,
      unit_etf_bytes: Enum.map(expected, &byte_size(:erlang.term_to_binary([&1])))}))
    for value <- expected do
      assert byte_size(:erlang.term_to_binary([value])) <= min(limits.batch_bytes, limits.inflight_bytes)
    end
    {PageCut.handle(state, {:page_begun, attempt}), attempt, expected}
  end

  defp new_cut(counts, opts, extra \\ %{}) do
    values = for {count, index} <- Enum.with_index(counts), into: %{} do
      chunk = {index, 0, 0}
      cells = for slot <- 0..(count - 1), into: %{},
        do: {{index * 16 + rem(slot, 16), div(slot, 16), 0}, 1_000_000}
      {chunk, VoxelRegion.EpochChunk.from_map(chunk, cells)}
    end
    dirty = MapSet.new(Map.keys(values), &{:chunk, :epochs, &1})
    state = %{seq: 1, thermal_run: nil, thermal: nil, protection: %{regions: %{}},
      epochs: values, page_dirty: dirty,
      page_store: PageCut.new(0, opts)} |> Map.merge(extra)
    state = put_in(state.page_store.writer, self()) |> PageCut.want()
    # 单元排序沿切点自己的不可变序列；测试不另造排序算法或尾批语义。
    expected = for {:chunk, :epochs, key} = unit <- state.page_store.cut.units,
      do: {unit, Map.fetch!(values, key)}
    assert_receive {:"$gen_cast", {:begin, attempt, 1}}
    {state, attempt, expected}
  end

  defp finish_cut(state, attempt, batch_limit, batches) do
    receive do
      {:"$gen_cast", {:batch, ^attempt, 1, units}} ->
        report_batch(state, units, :batch, batch_limit)
        assert byte_size(:erlang.term_to_binary(units)) <= batch_limit
        assert PageCut.backlog(state).inflight_bytes >= byte_size(:erlang.term_to_binary(units))
        state = PageCut.handle(state, {:page_ack, attempt})
        finish_cut(state, attempt, batch_limit, [units | batches])

      {:"$gen_cast", {:publish, ^attempt, 1, [], globals}} ->
        assert is_binary(globals)
        Enum.reverse(batches)
    after
      1_000 -> flunk("自然单元未在ACK后完成既有切点运输")
    end
  end

  defp report_batch(state, units, kind, limit) do
    IO.puts("R5_BUDGET_BATCH " <> Jason.encode!(%{budget_kind: kind, declared_limit_bytes: limit,
      unit_count: length(units), batch_etf_bytes: byte_size(:erlang.term_to_binary(units)),
      unacked_etf_upper_bytes: PageCut.backlog(state).inflight_bytes}))
  end
end
