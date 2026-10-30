defmodule WorldServer.SessionTest do
  @moduledoc "只测试：真实会话进程与公共 API；Scene / 路由替身只记录占用和移交交接。"
  use ExUnit.Case, async: true
  alias WorldServer.Session

  defmodule Scene do
    def join(ref, identity, character, sink) do
      send(ref, {:joined, identity, character.id, sink})
      {:ok, ref}
    end

    def leave(ref, identity, reason) do
      send(ref, {:left, identity, reason})
      :ok
    end
  end

  defmodule Router do
    def route(2), do: {:ok, %{scene_ref: :target, scene_epoch: 9}}

    def prepare_transfer(old, fresh, artifact, sink) do
      send(sink, {:prepared, old, fresh, artifact})
      {:ok, :target_player}
    end

    def commit_transfer(_old, _fresh), do: :ok
  end

  @tag :idle_binary_release
  test "移交成功或拒绝后空闲自动释放artifact二进制，休眠后仍可提交" do
    server = start_supervised!({Session, route_module: Router})
    route = %{scene_id: 1, scene_epoch: 7, scene_ref: self()}
    {old, _} = Session.claim(server, Scene, route, %{id: 101})

    for id <- [101, 102] do
      artifact = %{id: id, collision_checkpoint: :binary.copy(<<23>>, 2 * 1024 * 1024)}
      result = Session.prepare_transfer(server, old, 2, artifact)

      if id == 101,
        do: assert(match?({:ok, _, _, _}, result)),
        else: assert(result == {:error, :stale_owner})

      before = binary_bytes(server)
      assert_hibernated(server, System.monotonic_time(:millisecond) + 3000)
      assert {:binary, binaries} = Process.info(server, :binary)
      assert Enum.all?(binaries, fn {_, size, _} -> size < 2 * 1024 * 1024 end)

      if System.get_env("QINGLAN_MEMORY_EVIDENCE"),
        do:
          IO.puts(
            "memory_evidence session id=#{id} before_bytes=#{before} after_bytes=#{binary_bytes(server)}"
          )
    end

    assert {:ok, fresh, _, _} = Session.prepare_transfer(server, old, 2, %{id: 101})
    assert :ok = Session.commit_transfer(server, old, fresh, 101)
  end

  defp assert_hibernated(server, deadline) do
    # OTP29的hibernate/0保留调用栈，旧OTP的hibernate/3直接显示BIF。
    if Process.info(server, :current_function) not in [
         {:current_function, {:gen_server, :loop_hibernate, 4}},
         {:current_function, {:erlang, :hibernate, 3}}
       ] do
      assert System.monotonic_time(:millisecond) < deadline, "Session未在空闲时休眠回收"
      Process.sleep(10)
      assert_hibernated(server, deadline)
    end
  end

  defp binary_bytes(pid) do
    {:binary, binaries} = Process.info(pid, :binary)
    Enum.sum(for {_, size, _} <- binaries, do: size)
  end

  test "共享入口保留真实调用者身份，另一个控制进程不能替它移交" do
    server = start_supervised!({Session, route_module: Router})
    route = %{scene_id: 1, scene_epoch: 7, scene_ref: self()}
    me = self()
    {old, {:ok, ^me}} = Session.claim(server, Scene, route, %{id: 101})
    assert_receive {:joined, ^old, 101, ^me}

    task = Task.async(fn -> Session.prepare_transfer(server, old, 2, %{id: 101}) end)
    assert {:error, :stale_owner} = Task.await(task)

    assert {:ok, fresh, %{scene_epoch: 9}, :target_player} =
             Session.prepare_transfer(server, old, 2, %{id: 101})

    assert_receive {:prepared, ^old, ^fresh, %{id: 101}}
    assert fresh.session_epoch > old.session_epoch
    assert :ok = Session.commit_transfer(server, old, fresh, 101)
    assert {:error, :stale_owner} = Session.prepare_transfer(server, old, 2, %{id: 101})
  end

  test "两个控制器占用同一角色经过同一个 owner 撤销旧会话" do
    server = start_supervised!({Session, []})
    route = %{scene_id: 1, scene_epoch: 7, scene_ref: self()}
    {old, _} = Session.claim(server, Scene, route, %{id: 101})
    assert_receive {:joined, ^old, 101, _}

    task = Task.async(fn -> Session.claim(server, Scene, route, %{id: 101}) end)
    {fresh, _} = Task.await(task)
    assert_receive {:left, ^old, 2}
    assert_receive {:mmo_close, ^old, 2}
    assert_receive {:joined, ^fresh, 101, replacement}
    assert replacement == task.pid
    assert fresh.session_epoch > old.session_epoch
  end
end
