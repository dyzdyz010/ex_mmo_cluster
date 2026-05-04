defmodule DataService.Voxel.MapLedgerStoreTest do
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Voxel.MapLedgerStore

  setup do
    # The umbrella test_helper runs migrations once at boot. Each test starts
    # from a clean slate by truncating the singleton row table.
    Repo.query!("TRUNCATE TABLE voxel_map_ledger_snapshots", [])
    :ok
  end

  test "load_state returns an empty map when no row has been written yet" do
    assert {:ok, %{}} = MapLedgerStore.load_state(Repo)
  end

  test "save_state inserts the row and load_state round-trips the same shape" do
    state = sample_state()

    assert :ok = MapLedgerStore.save_state(Repo, state)

    assert {:ok, loaded} = MapLedgerStore.load_state(Repo)
    assert loaded == Map.take(state, [:assignments, :leases, :chunk_summaries, :migrations])
  end

  test "save_state replaces the existing row instead of inserting a second one" do
    assert :ok = MapLedgerStore.save_state(Repo, sample_state())

    next_state = %{
      assignments: %{42 => %{owner_scene_instance_ref: 4242, owner_epoch: 2}},
      leases: %{},
      chunk_summaries: %{},
      migrations: %{}
    }

    assert :ok = MapLedgerStore.save_state(Repo, next_state)
    assert {:ok, loaded} = MapLedgerStore.load_state(Repo)
    assert loaded.assignments == next_state.assignments

    assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM voxel_map_ledger_snapshots", [])
  end

  test "save_state strips unknown top-level keys before persisting" do
    state =
      sample_state()
      |> Map.put(:write_token_store, :some_pid_atom)
      |> Map.put(:persistence_path, "/tmp/should_not_persist")

    assert :ok = MapLedgerStore.save_state(Repo, state)

    assert {:ok, loaded} = MapLedgerStore.load_state(Repo)
    refute Map.has_key?(loaded, :write_token_store)
    refute Map.has_key?(loaded, :persistence_path)
  end

  test "load_state rejects payloads with unexpected top-level keys" do
    bad_payload = :erlang.term_to_binary(%{assignments: %{}, foo: %{}})
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.query!(
      "INSERT INTO voxel_map_ledger_snapshots (id, payload, inserted_at, updated_at) VALUES (1, $1, $2, $2)",
      [bad_payload, now]
    )

    assert {:error, {:unexpected_keys, unexpected}} = MapLedgerStore.load_state(Repo)
    assert :foo in unexpected
  end

  test "persist_fn / load_fn round-trip without referencing the repo at the call site" do
    persist = MapLedgerStore.persist_fn(Repo)
    load = MapLedgerStore.load_fn(Repo)
    state = sample_state()

    assert :ok = persist.(state)
    assert {:ok, loaded} = load.()
    assert loaded.assignments == state.assignments
  end

  defp sample_state do
    %{
      assignments: %{
        70 => %{
          region_id: 70,
          logical_scene_id: 7,
          owner_scene_instance_ref: 700,
          owner_epoch: 1,
          bounds_chunk_min: {0, 0, 0},
          bounds_chunk_max: {4, 4, 4}
        }
      },
      leases: %{
        70 => %{lease_id: 700_001, owner_scene_instance_ref: 700, owner_epoch: 1}
      },
      chunk_summaries: %{},
      migrations: %{
        "migration-7" => %{
          migration_id: "migration-7",
          state: :prewarming,
          target_scene_instance_ref: 800
        }
      }
    }
  end
end
