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
