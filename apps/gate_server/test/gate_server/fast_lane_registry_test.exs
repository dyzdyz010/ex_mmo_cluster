defmodule GateServer.FastLaneRegistryTest do
  use ExUnit.Case, async: false

  setup_all do
    _ = Application.stop(:gate_server)
    :ok
  end

  setup do
    ensure_name_available(GateServer.FastLaneRegistry)

    start_supervised!(
      {GateServer.FastLaneRegistry,
       name: GateServer.FastLaneRegistry, session_idle_timeout_ms: 250}
    )

    :ok
  end

  test "reattaching the same tcp connection replaces the previous udp peer" do
    connection_pid = self()

    assert {:ok, ticket1} = GateServer.FastLaneRegistry.issue_ticket(connection_pid, %{})
    assert {:ok, %{peer: {{127, 0, 0, 1}, 40_001}}} =
             GateServer.FastLaneRegistry.attach_ticket(ticket1, {{127, 0, 0, 1}, 40_001})

    assert_receive {:"$gen_cast", {:udp_attached, {{127, 0, 0, 1}, 40_001}, ^ticket1}}, 500

    assert {:ok, ticket2} = GateServer.FastLaneRegistry.issue_ticket(connection_pid, %{})
    assert {:ok, %{peer: {{127, 0, 0, 1}, 40_002}}} =
             GateServer.FastLaneRegistry.attach_ticket(ticket2, {{127, 0, 0, 1}, 40_002})

    assert_receive {:"$gen_cast", {:udp_detached, {{127, 0, 0, 1}, 40_001}, :peer_replaced}},
                   500

    assert_receive {:"$gen_cast", {:udp_attached, {{127, 0, 0, 1}, 40_002}, ^ticket2}}, 500

    assert nil == GateServer.FastLaneRegistry.session_for_peer({{127, 0, 0, 1}, 40_001})

    assert %{peer: {{127, 0, 0, 1}, 40_002}} =
             GateServer.FastLaneRegistry.session_for_connection(connection_pid)
  end

  test "reassigning one udp peer detaches the old owning connection" do
    old_connection = start_probe(self())
    new_connection = start_probe(self())
    shared_peer = {{127, 0, 0, 1}, 41_001}

    assert {:ok, old_ticket} = GateServer.FastLaneRegistry.issue_ticket(old_connection, %{})
    assert {:ok, %{peer: ^shared_peer}} =
             GateServer.FastLaneRegistry.attach_ticket(old_ticket, shared_peer)

    assert_receive {:probe, ^old_connection,
                    {:"$gen_cast", {:udp_attached, ^shared_peer, ^old_ticket}}},
                   500

    assert {:ok, new_ticket} = GateServer.FastLaneRegistry.issue_ticket(new_connection, %{})
    assert {:ok, %{peer: ^shared_peer}} =
             GateServer.FastLaneRegistry.attach_ticket(new_ticket, shared_peer)

    assert_receive {:probe, ^old_connection,
                    {:"$gen_cast", {:udp_detached, ^shared_peer, :peer_reassigned}}},
                   500

    assert_receive {:probe, ^new_connection,
                    {:"$gen_cast", {:udp_attached, ^shared_peer, ^new_ticket}}},
                   500

    assert %{peer: ^shared_peer} = GateServer.FastLaneRegistry.session_for_connection(new_connection)
    assert nil == GateServer.FastLaneRegistry.session_for_connection(old_connection)
  end

  test "dead tcp connections automatically lose their udp attachment" do
    connection = spawn(fn -> Process.sleep(:infinity) end)
    peer = {{127, 0, 0, 1}, 42_001}

    assert {:ok, ticket} = GateServer.FastLaneRegistry.issue_ticket(connection, %{})
    assert {:ok, %{peer: ^peer}} = GateServer.FastLaneRegistry.attach_ticket(ticket, peer)

    Process.exit(connection, :kill)

    wait_until(fn -> GateServer.FastLaneRegistry.session_for_connection(connection) == nil end)
    assert nil == GateServer.FastLaneRegistry.session_for_peer(peer)
  end

  defp start_probe(parent) do
    spawn_link(fn -> probe_loop(parent) end)
  end

  defp probe_loop(parent) do
    receive do
      message ->
        send(parent, {:probe, self(), message})
        probe_loop(parent)
    end
  end

  defp ensure_name_available(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        Process.exit(pid, :kill)
        wait_until(fn -> Process.whereis(name) == nil end)
    end
  end

  defp wait_until(fun, attempts \\ 30)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end
