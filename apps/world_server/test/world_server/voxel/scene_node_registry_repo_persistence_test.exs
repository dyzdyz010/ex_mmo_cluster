defmodule WorldServer.Voxel.SceneNodeRegistryRepoPersistenceTest do
  @moduledoc """
  Fault-injection coverage for Phase 3 / S1 (cluster-discovery-4): region
  ownership in `SceneNodeRegistry` is durable. The Postgres row is the source
  of truth and the GenServer cache is hydrated from it on (re)start, so a crash
  / restart of the registry must not lose `join_order` or `region_assignments`.

  Brings up the data_service repo locally because the umbrella's default
  world_server test_helper already wires it for the coordinator suite. Tests are
  tagged `:postgres` so a developer without a Postgres server can opt out via
  `mix test --exclude postgres`.
  """

  use ExUnit.Case, async: false

  @moduletag :postgres

  alias DataService.Repo
  alias DataService.Voxel.SceneNodeRegistryStore
  alias WorldServer.Voxel.SceneNodeRegistry

  setup_all do
    Application.ensure_all_started(:jason)
    Application.ensure_all_started(:postgrex)
    Application.ensure_all_started(:ecto_sql)

    case Ecto.Adapters.Postgres.storage_up(Repo.config()) do
      :ok -> :ok
      {:error, :already_up} -> :ok
    end

    case Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    migrations_path = Application.app_dir(:data_service, "priv/repo/migrations")

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Repo, fn repo ->
        Ecto.Migrator.run(repo, migrations_path, :up, all: true)
      end)

    :ok
  end

  setup do
    Repo.query!("TRUNCATE TABLE voxel_scene_node_registry_snapshots", [])
    :ok
  end

  defp persist, do: SceneNodeRegistryStore.persist_fn(Repo)
  defp load, do: SceneNodeRegistryStore.load_fn(Repo)

  test "region ownership survives a registry crash + restart (hydrate from Postgres)" do
    opts = [persist_fn: persist(), load_fn: load()]

    first = start_supervised!({SceneNodeRegistry, opts}, id: :first_registry)

    :ok = SceneNodeRegistry.register_scene_node(first, :scene1@h)
    :ok = SceneNodeRegistry.register_scene_node(first, :scene2@h)
    assert {:ok, :scene1@h} = SceneNodeRegistry.assign_region(first, 100)
    assert {:ok, :scene2@h} = SceneNodeRegistry.assign_region(first, 101)

    # Simulate a crash: kill the process so on-restart state can only come from
    # Postgres, never from in-memory carry-over.
    pid = GenServer.whereis(first)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    stop_supervised!(:first_registry)

    revived = start_supervised!({SceneNodeRegistry, opts}, id: :revived_registry)

    assert %{
             join_order: [:scene1@h, :scene2@h],
             region_assignments: %{100 => :scene1@h, 101 => :scene2@h}
           } = SceneNodeRegistry.snapshot(revived)

    # Round-robin cursor is part of the durable snapshot, so the next new region
    # continues the rotation instead of restarting at the head.
    assert {:ok, :scene1@h} = SceneNodeRegistry.assign_region(revived, 102)
    # Frozen assignments stay frozen across restart.
    assert {:ok, :scene1@h} = SceneNodeRegistry.lookup_assignment(revived, 100)
    assert {:ok, :scene2@h} = SceneNodeRegistry.lookup_assignment(revived, 101)
  end

  test "unregister is durable: a swept node does not come back after restart" do
    opts = [persist_fn: persist(), load_fn: load()]

    first = start_supervised!({SceneNodeRegistry, opts}, id: :unreg_first)

    :ok = SceneNodeRegistry.register_scene_node(first, :scene1@h)
    :ok = SceneNodeRegistry.register_scene_node(first, :scene2@h)
    assert {:ok, :scene1@h} = SceneNodeRegistry.assign_region(first, 1)
    :ok = SceneNodeRegistry.unregister_scene_node(first, :scene1@h)

    stop_supervised!(:unreg_first)

    revived = start_supervised!({SceneNodeRegistry, opts}, id: :unreg_revived)

    # scene1 stays out of the rotation, but its frozen assignment is preserved.
    assert %{join_order: [:scene2@h]} = SceneNodeRegistry.snapshot(revived)
    assert {:ok, :scene1@h} = SceneNodeRegistry.lookup_assignment(revived, 1)
    assert {:ok, :scene2@h} = SceneNodeRegistry.assign_region(revived, 2)
  end

  test "a corrupt row degrades to empty defaults instead of crashing the registry" do
    # Write a payload the store will reject (unexpected top-level key).
    bad_payload = :erlang.term_to_binary(%{join_order: [:scene1@h], bogus: %{}})
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.query!(
      "INSERT INTO voxel_scene_node_registry_snapshots (id, payload, inserted_at, updated_at) " <>
        "VALUES (1, $1, $2, $2)",
      [bad_payload, now]
    )

    # Sanity: the store itself rejects the row.
    assert {:error, {:unexpected_keys, _}} = SceneNodeRegistryStore.load_state(Repo)

    # The registry must still boot (degraded, empty) rather than crash-loop.
    registry =
      start_supervised!(
        {SceneNodeRegistry, [persist_fn: persist(), load_fn: load()]},
        id: :corrupt_registry
      )

    assert %{join_order: [], region_assignments: assignments} =
             SceneNodeRegistry.snapshot(registry)

    assert assignments == %{}
  end

  test "persisted snapshot reflects the latest mutation (row, not memory, is truth)" do
    registry =
      start_supervised!(
        {SceneNodeRegistry, [persist_fn: persist(), load_fn: load()]},
        id: :truth_registry
      )

    :ok = SceneNodeRegistry.register_scene_node(registry, :scene1@h)
    assert {:ok, :scene1@h} = SceneNodeRegistry.assign_region(registry, 7)

    # Read the durable row directly: it must already carry the assignment.
    assert {:ok, loaded} = SceneNodeRegistryStore.load_state(Repo)
    assert loaded.join_order == [:scene1@h]
    assert loaded.region_assignments == %{7 => :scene1@h}
    assert loaded.round_robin_cursor == 1
  end
end
