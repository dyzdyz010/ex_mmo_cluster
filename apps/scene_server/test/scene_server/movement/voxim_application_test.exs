defmodule SceneServer.Movement.VoximApplicationTest do
  use ExUnit.Case, async: false

  defmodule Native do
    def new_world(), do: make_ref()
  end

  defmodule World do
    def canonical_snapshot_and_subscribe(owner, _, _, _, _include_chunks \\ true) do
      send(owner, {:m1_snapshot_requested, self()})
      receive do
        :finish -> :ok
      end
    end
  end

  @tag :m3_remaining
  test "configured M1 application starts the real Scene without legacy native physics" do
    path = Path.expand("../../../../../../Voxim/Docs/M1/fixtures/demo-config.json", __DIR__)
    before = Application.get_env(:scene_server, SceneServer.Movement.Scene)
    Application.put_env(:scene_server, SceneServer.Movement.Scene,
      name: SceneServer.Movement.Scene, scene_id: 1, scene_epoch: 1,
      world_ref: self(), world_api: World, native: Native, config_path: path)
    on_exit(fn ->
      if before, do: Application.put_env(:scene_server, SceneServer.Movement.Scene, before),
        else: Application.delete_env(:scene_server, SceneServer.Movement.Scene)
    end)

    assert {:ok, supervisor} = SceneServer.Application.start(:normal, [])
    assert is_pid(Process.whereis(SceneServer.Movement.Scene))
    info = SceneServer.Movement.Scene.observe(SceneServer.Movement.Scene)
    assert is_pid(info.player_supervisor_pid) and is_pid(info.replication_pid)
    assert DynamicSupervisor.count_children(info.player_supervisor_pid).active == 0
    assert Process.whereis(SceneServer.PhysicsManager) == nil
    assert_receive {:m1_snapshot_requested, worker}
    Supervisor.stop(supervisor)
    Process.exit(worker, :kill)
  end
end
