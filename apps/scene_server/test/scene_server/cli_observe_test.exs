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

    File.rm(first_path)
    File.rm(second_path)

    Application.put_env(:scene_server, :cli_observe_log, first_path)
    CliObserve.emit("first_event", %{step: 1})
    CliObserve.flush()

    writer = Process.whereis(SceneServer.CliObserve.Writer)
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
    case Process.whereis(SceneServer.CliObserve.Writer) do
      nil -> :ok
      pid -> :sys.resume(pid)
    end
  end

  defp observe_path(name) do
    Path.join(
      System.tmp_dir!(),
      "scene-cli-observe-#{name}-#{System.unique_integer([:positive])}.log"
    )
  end
end
