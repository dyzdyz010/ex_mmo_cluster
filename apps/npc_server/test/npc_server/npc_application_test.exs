defmodule NpcServer.NpcApplicationTest do
  use ExUnit.Case, async: false
  Code.require_file("../support/npc_world.exs", __DIR__)
  alias NpcServer.NpcWorld

  test "正式 NPC 应用从登记恢复，监督器故障后相同身份重新加入 Scene" do
    MmoTest.Database.start!()
    DataService.Repo.delete_all("npc_specs")
    on_exit(fn -> DataService.Repo.delete_all("npc_specs") end)
    fixture = NpcWorld.start()
    old = Application.get_env(:world_server, :movement_routes)

    Application.put_env(:world_server, :movement_routes, %{
      1 => %{scene_ref: fixture.scene, world_ref: fixture.world, scene_epoch: 7}
    })

    on_exit(fn ->
      if old,
        do: Application.put_env(:world_server, :movement_routes, old),
        else: Application.delete_env(:world_server, :movement_routes)
    end)

    {:ok, character} =
      DataService.CharacterStore.ensure_npc("常驻#{System.unique_integer([:positive])}")

    :ok =
      DataService.NpcSpecs.upsert(character.id, %{
        scene_id: 1,
        spawn: {4.0, 66.0, 10.0},
        brain: "patrol",
        params: %{"route" => [[4, 10], [8, 10]]}
      })

    assert Application.load(:npc_server) in [:ok, {:error, {:already_loaded, :npc_server}}]

    start_supervised!(
      Supervisor.child_spec({WorldServer.Session, name: WorldServer.Session}, id: :shared_session)
    )

    start_supervised!(%{
      id: :npc_application,
      start: {NpcServer.Application, :start, [:normal, []]},
      type: :supervisor
    })

    cid = character.id
    NpcWorld.await(fn -> match?([%{cid: ^cid, running: true}], NpcServer.Registry.list()) end)
    assert %{status: :running, enabled: 1, running: 1} = NpcServer.Bootstrap.status()
    [{body, _}] = Registry.lookup(NpcServer.Names, cid)
    NpcWorld.await(fn -> NpcServer.Body.observe(body).tick > 0 end)

    for owner <- [body, NpcServer.BodySupervisor, NpcServer.Names] do
      [{before, _}] = Registry.lookup(NpcServer.Names, cid)
      Process.exit(if(is_pid(owner), do: owner, else: Process.whereis(owner)), :kill)

      NpcWorld.await(fn ->
        case Process.whereis(NpcServer.Names) do
          nil ->
            false

          _ ->
            case Registry.lookup(NpcServer.Names, cid) do
              [{after_pid, _}] when after_pid != before ->
                Process.alive?(after_pid) and NpcServer.Body.observe(after_pid).tick > 0

              _ ->
                false
            end
        end
      end)

      assert [%{cid: ^cid, running: true}] = NpcServer.Registry.list()
    end
  end
end
