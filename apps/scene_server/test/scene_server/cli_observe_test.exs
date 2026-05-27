defmodule SceneServer.CliObserveTest do
  use ExUnit.Case, async: false

  alias SceneServer.CliObserve

  setup do
    previous_log = Application.get_env(:scene_server, :cli_observe_log)

    on_exit(fn ->
      CliObserve.flush()

      case previous_log do
        nil -> Application.delete_env(:scene_server, :cli_observe_log)
        value -> Application.put_env(:scene_server, :cli_observe_log, value)
      end
    end)

    :ok
  end

  test "emit does not block callers when the observe writer is busy during a path switch" do
    first_path = observe_path("first")
    second_path = observe_path("second")

    try do
      File.rm(first_path)
      File.rm(second_path)

      Application.put_env(:scene_server, :cli_observe_log, first_path)
      CliObserve.emit("first_event", %{step: 1})
      CliObserve.flush()

      writer = CliObserve.writer_pid(first_path)
      assert is_pid(writer)

      :sys.suspend(writer)
      Application.put_env(:scene_server, :cli_observe_log, second_path)

      task = Task.async(fn -> CliObserve.emit("second_event", %{step: 2}) end)

      assert Task.yield(task, 200) == {:ok, :ok}

      :sys.resume(writer)
      CliObserve.flush()
      File.rm(first_path)
      File.rm(second_path)
    after
      resume_writer(first_path)
      resume_writer(second_path)
    end
  end

  test "path switches use independent writer queues" do
    first_path = observe_path("first-queue")
    second_path = observe_path("second-queue")

    try do
      File.rm(first_path)
      File.rm(second_path)

      Application.put_env(:scene_server, :cli_observe_log, first_path)
      CliObserve.emit("first_queue_event", %{step: 1})
      CliObserve.flush()

      first_writer = CliObserve.writer_pid(first_path)
      assert is_pid(first_writer)

      :sys.suspend(first_writer)

      Application.put_env(:scene_server, :cli_observe_log, second_path)
      CliObserve.emit("second_queue_event", %{step: 2})
      CliObserve.flush(500)

      assert File.read!(second_path) =~ "second_queue_event"
    after
      resume_writer(first_path)
      resume_writer(second_path)
    end
  end

  test "concurrent first writes to one path share one flushable writer" do
    path = observe_path("same-path")
    File.rm(path)
    Application.put_env(:scene_server, :cli_observe_log, path)

    1..20
    |> Enum.map(fn index ->
      Task.async(fn -> CliObserve.emit("same_path_event", %{index: index}) end)
    end)
    |> Enum.each(&Task.await(&1, 1_000))

    CliObserve.flush()

    lines = path |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 20

    assert Enum.all?(1..20, fn index ->
             Enum.any?(lines, &String.contains?(&1, "index: #{index}"))
           end)

    assert CliObserve.writer_count(path) == 1
  end

  test "registered logical scene routes override the global observe path" do
    routed_path = observe_path("routed-scene")
    fallback_path = observe_path("fallback-scene")
    File.rm(routed_path)
    File.rm(fallback_path)
    Application.put_env(:scene_server, :cli_observe_log, fallback_path)

    assert {:ok, token} = CliObserve.register_route(42_424, routed_path)

    try do
      CliObserve.emit("routed_scene_event", %{logical_scene_id: 42_424, step: 1})
      CliObserve.emit("fallback_scene_event", %{logical_scene_id: 42_425, step: 2})

      CliObserve.flush_path(routed_path)
      CliObserve.flush_path(fallback_path)

      assert File.read!(routed_path) =~ "routed_scene_event"
      refute File.read!(fallback_path) =~ "routed_scene_event"
      assert File.read!(fallback_path) =~ "fallback_scene_event"
    after
      CliObserve.unregister_route(42_424, token)
    end
  end

  test "observe manager is owned by the scene application supervisor" do
    assert Enum.any?(Supervisor.which_children(SceneServer.Supervisor), fn
             {SceneServer.CliObserve.Manager, _pid, _type, _modules} -> true
             _other -> false
           end)
  end

  test "manager APIs do not start a manager outside the scene supervisor" do
    path = observe_path("unsupervised-manager")
    File.rm(path)

    manager_pid = Process.whereis(SceneServer.CliObserve.Manager)
    assert is_pid(manager_pid)

    try do
      assert :ok =
               Supervisor.terminate_child(
                 SceneServer.Supervisor,
                 SceneServer.CliObserve.Manager
               )

      eventually(fn -> is_nil(Process.whereis(SceneServer.CliObserve.Manager)) end)

      assert SceneServer.CliObserve.Manager.ensure_writer(path) == nil
      assert SceneServer.CliObserve.Manager.writer_pid(path) == nil
      assert SceneServer.CliObserve.Manager.writer_count(path) == 0
      assert SceneServer.CliObserve.Manager.stop_writer(path) == :ok
      assert Process.whereis(SceneServer.CliObserve.Manager) == nil
      assert supervised_manager_pid() == :undefined

      assert {:ok, restarted} =
               Supervisor.restart_child(
                 SceneServer.Supervisor,
                 SceneServer.CliObserve.Manager
               )

      assert is_pid(restarted)
      assert supervised_manager_pid() == restarted
    after
      ensure_manager_supervised()
    end
  end

  test "manager restart does not leave orphan writers for the same path" do
    path = observe_path("manager-restart")
    File.rm(path)
    Application.put_env(:scene_server, :cli_observe_log, path)

    CliObserve.emit("before_manager_restart", %{step: 1})
    CliObserve.flush()

    manager_pid = Process.whereis(SceneServer.CliObserve.Manager)
    writer_before = CliObserve.writer_pid(path)
    assert is_pid(manager_pid)
    assert is_pid(writer_before)

    ref = Process.monitor(manager_pid)
    :ok = GenServer.stop(manager_pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^manager_pid, :normal}

    eventually(fn ->
      restarted = Process.whereis(SceneServer.CliObserve.Manager)
      is_pid(restarted) and restarted != manager_pid
    end)

    refute Process.alive?(writer_before)

    CliObserve.emit("after_manager_restart", %{step: 2})
    CliObserve.flush()

    writer_after = CliObserve.writer_pid(path)
    assert is_pid(writer_after)
    assert writer_after != writer_before
    assert CliObserve.writer_count(path) == 1
  end

  test "late stale writer down messages do not remove the replacement writer" do
    path = observe_path("late-down")
    File.rm(path)
    Application.put_env(:scene_server, :cli_observe_log, path)

    CliObserve.emit("before_late_down", %{step: 1})
    CliObserve.flush()

    manager_pid = Process.whereis(SceneServer.CliObserve.Manager)
    writer = CliObserve.writer_pid(path)
    assert is_pid(manager_pid)
    assert is_pid(writer)

    stale_ref = make_ref()

    :sys.replace_state(manager_pid, fn state ->
      put_in(state, [:refs, stale_ref], path)
    end)

    send(manager_pid, {:DOWN, stale_ref, :process, self(), :normal})

    eventually(fn -> CliObserve.writer_pid(path) == writer end)

    CliObserve.emit("after_late_down", %{step: 2})
    CliObserve.flush()

    assert CliObserve.writer_pid(path) == writer
    assert CliObserve.writer_count(path) == 1
    assert File.read!(path) =~ "after_late_down"
  end

  test "stopping a path writer removes it from the manager" do
    path = observe_path("stop-writer")
    File.rm(path)
    Application.put_env(:scene_server, :cli_observe_log, path)

    CliObserve.emit("stoppable_event", %{step: 1})
    CliObserve.flush()

    assert is_pid(CliObserve.writer_pid(path))
    assert CliObserve.writer_count(path) == 1

    Application.delete_env(:scene_server, :cli_observe_log)

    assert :ok = CliObserve.stop_writer(path)
    assert CliObserve.writer_pid(path) == nil
    assert CliObserve.writer_count(path) == 0
  end

  test "stopping a suspended path writer does not block the observe manager" do
    path = observe_path("stop-suspended-writer")
    File.rm(path)
    Application.put_env(:scene_server, :cli_observe_log, path)

    CliObserve.emit("stoppable_suspended_event", %{step: 1})
    CliObserve.flush()

    writer = CliObserve.writer_pid(path)
    assert is_pid(writer)

    :sys.suspend(writer)
    Application.delete_env(:scene_server, :cli_observe_log)

    task = Task.async(fn -> CliObserve.stop_writer(path) end)

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
    assert CliObserve.writer_pid(path) == nil
    assert CliObserve.writer_count(path) == 0
    refute Process.alive?(writer)
  end

  defp resume_writer(path) do
    case CliObserve.writer_pid(path) do
      nil -> :ok
      pid -> :sys.resume(pid)
    end
  catch
    :exit, _reason -> :ok
  end

  defp resume_pid(pid) when is_pid(pid) do
    :sys.resume(pid)
  catch
    :exit, _reason -> :ok
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: flunk("condition did not become true")

  defp supervised_manager_pid do
    SceneServer.Supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {SceneServer.CliObserve.Manager, pid, _type, _modules} -> pid
      _other -> nil
    end)
  end

  defp ensure_manager_supervised do
    case supervised_manager_pid() do
      pid when is_pid(pid) ->
        :ok

      :undefined ->
        kill_unsupervised_manager()

        case Supervisor.restart_child(SceneServer.Supervisor, SceneServer.CliObserve.Manager) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          {:error, :running} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
    end
  end

  defp kill_unsupervised_manager do
    case Process.whereis(SceneServer.CliObserve.Manager) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          500 -> :ok
        end
    end
  end

  defp observe_path(name) do
    Path.join(
      System.tmp_dir!(),
      "scene-cli-observe-#{name}-#{System.unique_integer([:positive])}.log"
    )
  end
end
