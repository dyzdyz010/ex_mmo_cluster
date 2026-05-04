defmodule DataService.Voxel.TransactionCoordinatorStoreTest do
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Voxel.TransactionCoordinatorStore

  setup do
    # The umbrella test_helper runs migrations once at boot. Each test starts
    # from a clean slate by truncating the singleton row table.
    Repo.query!("TRUNCATE TABLE voxel_transaction_coordinator_snapshots", [])
    :ok
  end

  test "load_state returns an empty map when no row has been written yet" do
    assert {:ok, %{}} = TransactionCoordinatorStore.load_state(Repo)
  end

  test "save_state inserts the row and load_state round-trips the same shape" do
    state = sample_state()

    assert :ok = TransactionCoordinatorStore.save_state(Repo, state)

    assert {:ok, loaded} = TransactionCoordinatorStore.load_state(Repo)

    assert loaded ==
             Map.take(state, [:transactions, :begin_fingerprints, :decisions, :decision_index])
  end

  test "save_state replaces the existing row instead of inserting a second one" do
    assert :ok = TransactionCoordinatorStore.save_state(Repo, sample_state())

    next_state = %{
      transactions: %{"tx-2" => %{state: :prepared, decision_version: 1}},
      begin_fingerprints: %{"tx-2" => %{intent_hash: "hash-2"}},
      decisions: %{},
      decision_index: %{}
    }

    assert :ok = TransactionCoordinatorStore.save_state(Repo, next_state)
    assert {:ok, loaded} = TransactionCoordinatorStore.load_state(Repo)
    assert loaded.transactions == next_state.transactions

    assert %{rows: [[1]]} =
             Repo.query!("SELECT count(*) FROM voxel_transaction_coordinator_snapshots", [])
  end

  test "save_state strips unknown top-level keys before persisting" do
    state =
      sample_state()
      |> Map.put(:persist_fn, fn _ -> :ok end)
      |> Map.put(:persistence_path, "/tmp/should_not_persist")

    assert :ok = TransactionCoordinatorStore.save_state(Repo, state)

    assert {:ok, loaded} = TransactionCoordinatorStore.load_state(Repo)
    refute Map.has_key?(loaded, :persist_fn)
    refute Map.has_key?(loaded, :persistence_path)
  end

  test "load_state rejects payloads with unexpected top-level keys" do
    bad_payload = :erlang.term_to_binary(%{transactions: %{}, foo: %{}})
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.query!(
      "INSERT INTO voxel_transaction_coordinator_snapshots (id, payload, inserted_at, updated_at) VALUES (1, $1, $2, $2)",
      [bad_payload, now]
    )

    assert {:error, {:unexpected_keys, unexpected}} =
             TransactionCoordinatorStore.load_state(Repo)

    assert :foo in unexpected
  end

  test "persist_fn / load_fn round-trip without referencing the repo at the call site" do
    persist = TransactionCoordinatorStore.persist_fn(Repo)
    load = TransactionCoordinatorStore.load_fn(Repo)
    state = sample_state()

    assert :ok = persist.(state)
    assert {:ok, loaded} = load.()
    assert loaded.transactions == state.transactions
  end

  defp sample_state do
    %{
      transactions: %{
        "tx-1" => %{
          transaction_id: "tx-1",
          state: :preparing,
          decision_version: 1
        }
      },
      begin_fingerprints: %{
        "tx-1" => %{
          transaction_id: "tx-1",
          intent_hash: "hash-1",
          decision_version: 1
        }
      },
      decisions: %{
        {"tx-1", 1} => %{
          transaction_id: "tx-1",
          decision: :commit,
          decision_version: 1
        }
      },
      decision_index: %{
        "tx-1" => %{
          transaction_id: "tx-1",
          decision: :commit,
          decision_version: 1
        }
      }
    }
  end
end
