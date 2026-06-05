defmodule AgentServer.InterfaceDegradedTest do
  @moduledoc """
  Reproduces finding cluster-discovery-3 for the agent node: a missing
  `agent_manager` dependency must drive `AgentServer.Interface` into a
  controlled `:degraded` state instead of an unbounded crash-restart loop.
  """

  use ExUnit.Case, async: false

  alias AgentServer.Interface

  setup do
    case BeaconServer.Client.lookup(:agent_manager) do
      :error -> :ok
      {:ok, _node} -> BeaconServer.Client.unregister(:agent_manager)
    end

    :ok
  end

  test "missing agent_manager drives the interface into :degraded, not a crash loop" do
    pid =
      start_supervised!(
        {Interface,
         name: nil, max_attempts: 1, base_backoff_ms: 1, max_backoff_ms: 1}
      )

    ref = Process.monitor(pid)

    _ = :sys.get_state(pid)

    refute_received {:DOWN, ^ref, :process, ^pid, _reason}
    assert Process.alive?(pid)
    assert Interface.server_state(pid) == :degraded
  end

  test "retry_dependencies/1 re-runs resolution without crashing" do
    pid =
      start_supervised!(
        {Interface,
         name: nil, max_attempts: 1, base_backoff_ms: 1, max_backoff_ms: 1}
      )

    _ = :sys.get_state(pid)
    assert Interface.server_state(pid) == :degraded

    assert Interface.retry_dependencies(pid) == :degraded
    assert Process.alive?(pid)
  end
end
