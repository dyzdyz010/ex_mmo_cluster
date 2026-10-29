defmodule VoxelRegion.AttachmentFilterTest do
  @moduledoc "只测试：有限附件候选按同一几何owner筛选，不为存在性构造完整去重足迹。"
  use ExUnit.Case, async: false
  alias VoxelRegion.Attachments
  alias VoxelRegion.World.{AttachmentOps, Canonical}

  test "先筛附件候选再排序且不构造逐槽宏格去重表" do
    face = {0, 0, {8, 1, 1}}
    line = {1, 2, {8, 8, 1}}
    far = {0, 1, {80, 80, 80}}
    state = Canonical.index_attachments(%{attachments: %{line => {2, 11}, far => {3, 11}, face => {1, 11}}})
    {actual, calls} = count_macros(fn -> AttachmentOps.affected_attachments(state, [{0, 0, 0}]) end)
    assert actual == [face, line]
    assert calls == 0
  end

  test "相交谓词保留三轴面与棱的负侧支撑及负宏格边界" do
    cases = [
      {{0, 0, {0, 0, 0}}, [{0, 0, 0}, {-1, 0, 0}], {0, -1, 0}},
      {{0, 1, {0, 0, 0}}, [{0, 0, 0}, {0, -1, 0}], {-1, 0, 0}},
      {{0, 2, {0, 0, 0}}, [{0, 0, 0}, {0, 0, -1}], {-1, 0, 0}},
      {{1, 0, {0, 0, 0}}, [{0, 0, 0}, {0, -1, 0}, {0, 0, -1}, {0, -1, -1}], {-1, 0, 0}},
      {{1, 1, {0, 0, 0}}, [{0, 0, 0}, {-1, 0, 0}, {0, 0, -1}, {-1, 0, -1}], {0, -1, 0}},
      {{1, 2, {0, 0, 0}}, [{0, 0, 0}, {-1, 0, 0}, {0, -1, 0}, {-1, -1, 0}], {0, 0, -1}},
      {{0, 0, {-8, -8, -8}}, [{-1, -1, -1}, {-2, -1, -1}], {-1, -2, -1}},
      {{1, 2, {-8, -8, -8}}, [{-1, -1, -1}, {-2, -1, -1}, {-1, -2, -1}, {-2, -2, -1}], {-1, -1, -2}}
    ]
    for {slot, expected, absent} <- cases do
      assert Enum.sort(Attachments.macros([slot])) == Enum.sort(expected)
      for cell <- expected, do: assert(Attachments.touches_macros?(slot, MapSet.new([cell])))
      refute Attachments.touches_macros?(slot, MapSet.new([absent]))
      refute Attachments.touches_macros?(slot, MapSet.new())
    end
  end

  defp count_macros(action) do
    mfa = {Attachments, :macros, 1}
    assert {:module, Attachments} = Code.ensure_loaded(Attachments)
    parent = self()
    {worker, monitor} = spawn_monitor(fn ->
      receive do
        :run ->
          send(parent, {:result, self(), action.()})
          receive do: (:stop -> :ok)
      end
    end)
    sessions = :trace.session_info(:all)
    session = :trace.session_create(:attachment_filter, self(), [])
    try do
      assert :trace.function(session, mfa, true, [:local]) == 1
      assert :trace.process(session, worker, true, [:call, :arity]) == 1
      send(worker, :run)
      result = receive do
        {:result, ^worker, result} -> result
      after
        5_000 -> flunk("附件候选投影没有完成")
      end
      marker = :trace.delivered(session, worker)
      {result, drain(worker, mfa, marker, 0)}
    after
      :trace.process(session, worker, false, [:call, :arity])
      assert :trace.function(session, mfa, false, [:local]) == 1
      assert :trace.info(session, worker, :flags) == {:flags, []}
      assert :trace.info(session, mfa, :traced) == {:traced, false}
      marker = :trace.delivered(session, worker)
      assert drain(worker, mfa, marker, 0) == 0
      assert :trace.session_destroy(session)
      assert :trace.session_info(worker) == []
      assert :trace.session_info(:all) == sessions
      send(worker, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    end
  end

  defp drain(worker, mfa, marker, calls) do
    receive do
      {:trace, ^worker, :call, ^mfa} -> drain(worker, mfa, marker, calls + 1)
      {:trace_delivered, ^worker, ^marker} -> calls
    after
      1_000 -> flunk("附件候选 trace 投递屏障未完成")
    end
  end
end
