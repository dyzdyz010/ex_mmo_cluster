defmodule GateServer.CliObservePathSwitchTest do
  use ExUnit.Case, async: false

  test "gate observe path switches do not block on the previous writer queue" do
    assert_path_switch_emit_does_not_block(
      GateServer.CliObserve,
      GateServer.CliObserve.Writer,
      :gate_server,
      "gate"
    )
  end

  test "world observe path switches do not block on the previous writer queue" do
    assert_path_switch_emit_does_not_block(
      WorldServer.CliObserve,
      WorldServer.CliObserve.Writer,
      :world_server,
      "world"
    )
  end

  test "chat observe path switches do not block on the previous writer queue" do
    assert_path_switch_emit_does_not_block(
      ChatServer.CliObserve,
      ChatServer.CliObserve.Writer,
      :chat_server,
      "chat"
    )
  end

  test "registered logical scene routes override global observe paths" do
    assert_route_overrides_global_path(GateServer.CliObserve, :gate_server, "gate")
    assert_route_overrides_global_path(WorldServer.CliObserve, :world_server, "world")
    assert_route_overrides_global_path(ChatServer.CliObserve, :chat_server, "chat")
  end

  defp assert_path_switch_emit_does_not_block(observe_module, writer_name, app, prefix) do
    previous_log = Application.fetch_env(app, :cli_observe_log)
    first_path = observe_path("#{prefix}-first")
    second_path = observe_path("#{prefix}-second")

    try do
      File.rm(first_path)
      File.rm(second_path)

      Application.put_env(app, :cli_observe_log, first_path)
      observe_module.emit("#{prefix}_first_event", %{step: 1})
      observe_module.flush()

      writer = Process.whereis(writer_name)
      assert is_pid(writer)

      :sys.suspend(writer)
      Application.put_env(app, :cli_observe_log, second_path)

      task = Task.async(fn -> observe_module.emit("#{prefix}_second_event", %{step: 2}) end)

      result =
        try do
          Task.yield(task, 200) || :timeout
        after
          resume_pid(writer)
        end

      if result == :timeout do
        Task.shutdown(task, 1_000)
      end

      assert result == {:ok, :ok}
      observe_module.flush()
      assert File.read!(second_path) =~ "#{prefix}_second_event"
    after
      restore_env(app, previous_log)
      flush_observe(observe_module)
    end
  end

  defp assert_route_overrides_global_path(observe_module, app, prefix) do
    previous_log = Application.fetch_env(app, :cli_observe_log)
    routed_path = observe_path("#{prefix}-routed")
    fallback_path = observe_path("#{prefix}-fallback")

    try do
      File.rm(routed_path)
      File.rm(fallback_path)
      Application.put_env(app, :cli_observe_log, fallback_path)

      assert {:ok, token} = observe_module.register_route(51_515, routed_path)

      try do
        observe_module.emit("#{prefix}_routed_event", %{logical_scene_id: 51_515})
        observe_module.emit("#{prefix}_fallback_event", %{logical_scene_id: 51_516})
        observe_module.flush()

        assert File.read!(routed_path) =~ "#{prefix}_routed_event"
        refute File.read!(fallback_path) =~ "#{prefix}_routed_event"
        assert File.read!(fallback_path) =~ "#{prefix}_fallback_event"
      after
        observe_module.unregister_route(51_515, token)
      end
    after
      restore_env(app, previous_log)
      flush_observe(observe_module)
    end
  end

  defp flush_observe(observe_module) do
    observe_module.flush()
  catch
    :exit, _reason -> :ok
  end

  defp restore_env(app, {:ok, value}), do: Application.put_env(app, :cli_observe_log, value)
  defp restore_env(app, :error), do: Application.delete_env(app, :cli_observe_log)

  defp resume_pid(pid) when is_pid(pid) do
    :sys.resume(pid)
  catch
    :exit, _reason -> :ok
  end

  defp observe_path(name) do
    Path.join(
      System.tmp_dir!(),
      "cli-observe-path-switch-#{name}-#{System.unique_integer([:positive])}.log"
    )
  end
end
