defmodule GateServer.InterfaceDegradedTest do
  @moduledoc """
  Reproduces finding cluster-discovery-3: a missing hard dependency
  (`scene_server`) must drive `GateServer.Interface` into a controlled
  `:degraded` state instead of an unbounded crash-restart loop.
  """

  use ExUnit.Case, async: false

  alias GateServer.Interface

  setup do
    # Guarantee the hard dependency is absent for this process's view so the
    # bounded-retry path exhausts its budget deterministically.
    case BeaconServer.Client.lookup(:scene_server) do
      :error -> :ok
      {:ok, _node} -> BeaconServer.Client.unregister(:scene_server)
    end

    :ok
  end

  test "missing scene_server drives the interface into :degraded, not a crash loop" do
    pid =
      start_supervised!(
        {Interface,
         name: nil, max_attempts: 1, base_backoff_ms: 1, max_backoff_ms: 1}
      )

    ref = Process.monitor(pid)

    # Let handle_continue/2 run its first (and, with max_attempts: 1, only)
    # resolution attempt to completion.
    _ = :sys.get_state(pid)

    # The process must still be alive: degradation is a state, not a crash.
    refute_received {:DOWN, ^ref, :process, ^pid, _reason}
    assert Process.alive?(pid)
    assert Interface.server_state(pid) == :degraded
  end

  test "degraded interface stays alive across multiple resolution rounds (no restart loop)" do
    pid =
      start_supervised!(
        {Interface,
         name: nil, max_attempts: 2, base_backoff_ms: 1, max_backoff_ms: 2}
      )

    ref = Process.monitor(pid)

    # 退避重试是异步的(Process.send_after):同步的 :sys.get_state 快照不会 drain 已调度的
    # 定时重试消息,因此必须轮询等待预算耗尽后进入 :degraded,而非假设两次 get_state 就到位。
    assert eventually(fn -> Interface.server_state(pid) == :degraded end)

    refute_received {:DOWN, ^ref, :process, ^pid, _reason}
    assert Process.alive?(pid)
  end

  test "retry_dependencies/1 re-runs resolution and reports the resulting state" do
    pid =
      start_supervised!(
        {Interface,
         name: nil, max_attempts: 1, base_backoff_ms: 1, max_backoff_ms: 1}
      )

    _ = :sys.get_state(pid)
    assert Interface.server_state(pid) == :degraded

    # Still missing -> retry returns :degraded again without crashing.
    assert Interface.retry_dependencies(pid) == :degraded
    assert Process.alive?(pid)
  end

  # 轮询直到 fun 返回真(用于等待异步退避→degraded 的状态转换),最多约 200ms。
  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() ->
        true

      retries > 0 ->
        Process.sleep(2)
        eventually(fun, retries - 1)

      true ->
        false
    end
  end
end
