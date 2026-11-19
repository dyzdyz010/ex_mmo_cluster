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

    # 正式应用自己把出站车道（`NpcServer.Http`）放在监督树第一位：先停掉 test_helper 起的那一个，
    # 测完（受监督的应用已停）再起回来给别的用例。
    :ok = Supervisor.stop(NpcServer.Http)

    on_exit(fn ->
      {:ok, http} = NpcServer.Http.start_link()
      Process.unlink(http)
    end)

    start_supervised!(%{
      id: :npc_application,
      start: {NpcServer.Application, :start, [:normal, []]},
      type: :supervisor
    })

    cid = character.id
    NpcWorld.await(fn -> match?([%{cid: ^cid, running: true}], NpcServer.Registry.list()) end)
    assert %{status: :running, enabled: 1, running: 1} = NpcServer.Bootstrap.status()

    # 崩溃域：BodySupervisor 是所有 NPC 的父监督者，强度显式放宽（缺省 3 次 / 5 秒会让一次全节点抖动
    # 把整组 NPC 永久带走）。这里从监督树状态直接读，不靠"杀多少次才炸"去猜。
    supervisor = :sys.get_state(NpcServer.BodySupervisor)
    assert supervisor.max_restarts == 60
    assert supervisor.max_seconds == 10

    [{body, _}] = Registry.lookup(NpcServer.Names, cid)
    NpcWorld.await(fn -> NpcServer.Body.observe(body).tick > 0 end)

    # 花费额度排在 Bootstrap 之后（`:rest_for_one` 下它崩溃只重启它自己）：杀掉它，NPC 的 Body 与 Bootstrap 都不重起。
    ids = NpcServer.Supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))
    assert Enum.take(ids, 2) == [NpcServer.SpendBudget, NpcServer.Bootstrap]
    bootstrap = Process.whereis(NpcServer.Bootstrap)
    budget = Process.whereis(NpcServer.SpendBudget)
    Process.exit(budget, :kill)

    NpcWorld.await(fn ->
      Process.whereis(NpcServer.SpendBudget) not in [nil, budget]
    end)

    assert [{^body, _}] = Registry.lookup(NpcServer.Names, cid)
    assert Process.alive?(body)
    assert Process.whereis(NpcServer.Bootstrap) == bootstrap

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
