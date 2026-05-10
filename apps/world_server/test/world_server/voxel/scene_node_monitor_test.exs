defmodule WorldServer.Voxel.SceneNodeMonitorTest do
  use ExUnit.Case, async: false

  alias WorldServer.Voxel.{SceneNodeMonitor, SceneNodeRegistry}

  defp start_pair!(ctx) do
    registry_name = Module.concat([__MODULE__, ctx.test, Registry])
    monitor_name = Module.concat([__MODULE__, ctx.test, Monitor])

    start_supervised!({SceneNodeRegistry, name: registry_name})
    start_supervised!({SceneNodeMonitor, name: monitor_name, registry: registry_name})

    %{registry: registry_name, monitor: monitor_name}
  end

  setup ctx, do: start_pair!(ctx)

  # `send/2` is async; without a sync barrier between sending the
  # `{:nodedown, ...}` message and asserting on registry state, the
  # snapshot call races the monitor's handle_info. `:sys.get_state/1`
  # is a synchronous round-trip and flushes the monitor's mailbox up
  # to the point of call.
  defp sync(server), do: :sys.get_state(server)

  test "forwards :nodedown to SceneNodeRegistry.unregister_scene_node", %{
    registry: registry,
    monitor: monitor
  } do
    :ok = SceneNodeRegistry.register_scene_node(registry, :scene1@h)
    :ok = SceneNodeRegistry.register_scene_node(registry, :scene2@h)
    assert %{join_order: [:scene1@h, :scene2@h]} = SceneNodeRegistry.snapshot(registry)

    # Simulate :net_kernel.monitor_nodes/1 delivering a 2-tuple
    # nodedown for one of them.
    send(monitor, {:nodedown, :scene1@h})
    sync(monitor)

    assert %{join_order: [:scene2@h]} = SceneNodeRegistry.snapshot(registry)
  end

  test "handles 3-tuple {:nodedown, node, info} variant", %{
    registry: registry,
    monitor: monitor
  } do
    :ok = SceneNodeRegistry.register_scene_node(registry, :scene3@h)

    send(monitor, {:nodedown, :scene3@h, [{:nodedown_reason, :connection_closed}]})
    sync(monitor)

    assert %{join_order: []} = SceneNodeRegistry.snapshot(registry)
  end

  test "ignores :nodeup (scene_nodes register themselves explicitly)", %{
    registry: registry,
    monitor: monitor
  } do
    send(monitor, {:nodeup, :some_other@h})
    send(monitor, {:nodeup, :some_other@h, [{:node_type, :visible}]})
    sync(monitor)

    # Nothing got registered — only explicit register calls populate
    # join_order.
    assert %{join_order: []} = SceneNodeRegistry.snapshot(registry)
  end

  test "nodedown for a never-registered node is a no-op", %{
    registry: registry,
    monitor: monitor
  } do
    :ok = SceneNodeRegistry.register_scene_node(registry, :alive@h)

    send(monitor, {:nodedown, :never_seen@h})
    sync(monitor)

    assert %{join_order: [:alive@h]} = SceneNodeRegistry.snapshot(registry)
  end

  test "ignores unrecognised messages without crashing", %{monitor: monitor} do
    send(monitor, :unexpected_atom)
    send(monitor, {:totally_unknown, 1, 2, 3})
    sync(monitor)

    assert Process.alive?(GenServer.whereis(monitor))
  end
end
