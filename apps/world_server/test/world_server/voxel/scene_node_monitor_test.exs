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

  # Phase 3 / S1: establish-then-reconcile timing-race fix. On (re)start the
  # monitor reconciles the registry's hydrated `join_order` against the live
  # node set before taking over `:nodedown` sweeping. Under the non-distributed
  # test BEAM (`:nonode@nohost`), `:net_kernel.monitor_nodes/1` returns
  # `:ignored`, so the monitor takes the single-BEAM no-op reconcile branch and
  # must leave pre-populated (e.g. Postgres-hydrated) entries intact — the
  # scene_node there *is* this same node, so it is not stale.
  describe "establish-then-reconcile on startup" do
    test "single-BEAM: pre-populated registry entries are preserved across monitor start" do
      registry_name = Module.concat([__MODULE__, :reconcile_single_beam, Registry])
      monitor_name = Module.concat([__MODULE__, :reconcile_single_beam, Monitor])

      # 本测试自起一对 registry/monitor（验证"已水合 entries → 启动 monitor 不被
      # reconcile 覆盖"），与文件级 `setup` 起的那对不同名。两次 start_supervised
      # 默认 child id 都是模块名会撞 {:already_started}，因此给本 body 的子进程显式
      # 唯一 id。
      start_supervised!({SceneNodeRegistry, name: registry_name}, id: registry_name)
      :ok = SceneNodeRegistry.register_scene_node(registry_name, :scene1@h)
      :ok = SceneNodeRegistry.register_scene_node(registry_name, :scene2@h)

      # Start the monitor *after* the registry already holds entries (mirrors a
      # restart that hydrated from Postgres before the monitor came up).
      monitor =
        start_supervised!({SceneNodeMonitor, name: monitor_name, registry: registry_name},
          id: monitor_name
        )

      # Flush handle_continue(:reconcile_live_nodes, ...) deterministically.
      sync(monitor)

      assert Process.alive?(GenServer.whereis(monitor))
      # Non-distributed BEAM → reconcile is a no-op, hydrated entries untouched.
      assert %{join_order: [:scene1@h, :scene2@h]} = SceneNodeRegistry.snapshot(registry_name)
    end

    test "monitor still sweeps :nodedown after the reconcile continue completes" do
      registry_name = Module.concat([__MODULE__, :reconcile_then_down, Registry])
      monitor_name = Module.concat([__MODULE__, :reconcile_then_down, Monitor])

      # 同上：本 body 自起的 registry/monitor 需显式唯一 child id，避免与文件级
      # setup 起的默认模块 id 撞 {:already_started}。
      start_supervised!({SceneNodeRegistry, name: registry_name}, id: registry_name)
      :ok = SceneNodeRegistry.register_scene_node(registry_name, :scene1@h)

      monitor =
        start_supervised!({SceneNodeMonitor, name: monitor_name, registry: registry_name},
          id: monitor_name
        )

      # Let the startup continue run, then deliver a nodedown like the real VM.
      sync(monitor)
      send(monitor, {:nodedown, :scene1@h})
      sync(monitor)

      assert %{join_order: []} = SceneNodeRegistry.snapshot(registry_name)
    end
  end
end
