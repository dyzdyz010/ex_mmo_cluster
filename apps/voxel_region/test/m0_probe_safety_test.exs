Code.require_file("../bench/paging_m0/probe.ex", __DIR__)

defmodule VoxelRegion.M0ProbeSafetyTest do
  @moduledoc """
  只测试：自有小型GenServer验证M0诊断的返回运输，不启动World、数据库或真实benchmark。
  canary只属于此测试进程的合法初始状态；不向运行authority回填状态，不靠内存阈值猜是否复制。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.Bench.M0Probe

  defmodule Target do
    @moduledoc "只测试：提供紧凑stats的自有进程，私有canary绝不属于公开stats合同。"
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(_) do
      shared = Enum.reduce(1..8, [1], fn _, previous -> {previous, previous} end)
      {:ok, %{probe_canary: shared, seq: 17, refined: %{}, resident: MapSet.new(),
        instances: %{}, epochs: %{}, damage: %{}, snapshots: MapSet.new(), payloads: %{}, entries: %{}}}
    end

    @impl true
    def handle_call({:page_request, _request, :stats}, from, state), do: handle_call(:stats, from, state)
    def handle_call(:stats, _from, state) do
      {:reply, %{seq: 17, resident_pages: 0, instances: 0, refined_macros: 0, damaged_targets: 0,
        snapshot_regions: 0, entries: 0, retained_transactions: 0,
        scope: %{canonical_data: "resident_pages", runtime: "world"}}, state}
    end
  end

  test "field_heap诊断只能运输小摘要，不能借sys.replace_state把完整state回给调用者" do
    target = start_supervised!({Target, []})
    :erlang.trace(target, true, [:send, {:tracer, self()}])
    try do
      task = Task.async(fn -> M0Probe.field_heap(target) end)
      result = Task.await(task, 5_000) |> Jason.decode!()
      assert is_map(result)
      barrier = :erlang.trace_delivered(target)
      messages = delivered(target, barrier, [])
      IO.puts("M0_PROBE_TRANSPORT " <> Jason.encode!(%{reply_count: length(messages),
        full_state_reply_count: Enum.count(messages, &full_state_reply?/1),
        max_reply_etf_upper_bytes: messages |> Enum.map(&:erlang.external_size/1) |> Enum.max(fn -> 0 end)}))
      refute Enum.any?(messages, &full_state_reply?/1),
        "诊断调用虽然另外发送了小摘要，系统调用仍把完整state作为返回消息复制了出去"
      assert %{"status" => "unavailable", "reason" => reason} = result["field_breakdown"]
      assert is_binary(reason) and reason != ""
    after
      :erlang.trace(target, false, [:send])
    end
  end

  defp delivered(target, barrier, messages) do
    receive do
      {:trace, ^target, :send, message, _destination} -> delivered(target, barrier, [message | messages])
      {:trace_delivered, ^target, ^barrier} -> messages
    after
      1_000 -> flunk("没有收到该自有进程的trace完成屏障")
    end
  end

  defp full_state_reply?({_reply_ref, %{probe_canary: _}}), do: true
  defp full_state_reply?({_reply_ref, {:ok, %{probe_canary: _}}}), do: true
  defp full_state_reply?(_message), do: false
end
