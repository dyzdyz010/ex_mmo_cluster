defmodule DataService.Voxel.TransactionCoordinatorStoreTest do
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelTransactionCoordinatorRow
  alias DataService.Voxel.TransactionCoordinatorStore

  setup do
    # The umbrella test_helper runs migrations once at boot. Each test starts
    # from a clean slate by truncating the per-transaction row table.
    Repo.query!("TRUNCATE TABLE voxel_transaction_coordinator_rows", [])

    # 这些用例写的是**共享生产表** voxel_transaction_coordinator_rows(里面是
    # plain-map 等残缺 fixture 行)。若不在退出时清掉,world_server 应用 boot 时
    # WorldSup → TransactionCoordinator.init 会 load 到这些残缺行(world boot 早于
    # 任何 test setup)。coordinator 已对非 struct 行做 boot 兜底(见
    # sanitize_loaded_active_set),但这里仍清表以免给其它 app 留脏数据。
    on_exit(fn -> Repo.query!("TRUNCATE TABLE voxel_transaction_coordinator_rows", []) end)

    :ok
  end

  test "load_state returns an empty map when no row has been written yet" do
    assert {:ok, %{}} = TransactionCoordinatorStore.load_state(Repo)
  end

  test "persist_rows upserts changed rows and load_state reconstructs the four maps" do
    changed = [
      {"tx-1",
       %{
         transaction: %{transaction_id: "tx-1", state: :preparing, decision_version: 1},
         begin_fingerprint: %{transaction_id: "tx-1", intent_hash: "hash-1"},
         decision_index: nil
       }},
      {"tx-2",
       %{
         transaction: nil,
         begin_fingerprint: nil,
         decision_index: %{transaction_id: "tx-2", decision: :commit, decision_version: 3}
       }}
    ]

    assert :ok = TransactionCoordinatorStore.persist_rows(Repo, changed, [])

    assert {:ok, loaded} = TransactionCoordinatorStore.load_state(Repo)

    assert loaded.transactions["tx-1"] == %{
             transaction_id: "tx-1",
             state: :preparing,
             decision_version: 1
           }

    assert loaded.begin_fingerprints["tx-1"] == %{transaction_id: "tx-1", intent_hash: "hash-1"}

    # tx-2 是只带决策归档的轻量历史行(active struct 为 nil)。
    refute Map.has_key?(loaded.transactions, "tx-2")

    assert loaded.decision_index["tx-2"] == %{
             transaction_id: "tx-2",
             decision: :commit,
             decision_version: 3
           }

    # decisions map 由 decision_index 行重建 {transaction_id, decision_version} key。
    assert loaded.decisions[{"tx-2", 3}].decision == :commit
  end

  test "persist_rows replaces an existing row in place (one row per transaction_id)" do
    assert :ok =
             TransactionCoordinatorStore.persist_rows(
               Repo,
               [{"tx-x", %{transaction: %{state: :preparing}, begin_fingerprint: nil, decision_index: nil}}],
               []
             )

    assert :ok =
             TransactionCoordinatorStore.persist_rows(
               Repo,
               [{"tx-x", %{transaction: %{state: :prepared}, begin_fingerprint: nil, decision_index: nil}}],
               []
             )

    assert {:ok, loaded} = TransactionCoordinatorStore.load_state(Repo)
    assert loaded.transactions["tx-x"] == %{state: :prepared}

    # 同一 transaction_id 只有一行。
    assert Repo.aggregate(VoxelTransactionCoordinatorRow, :count) == 1
  end

  test "persist_rows deletes rows whose ids are in deleted_ids" do
    assert :ok =
             TransactionCoordinatorStore.persist_rows(
               Repo,
               [
                 {"tx-keep", %{transaction: %{state: :preparing}, begin_fingerprint: nil, decision_index: nil}},
                 {"tx-drop", %{transaction: %{state: :preparing}, begin_fingerprint: nil, decision_index: nil}}
               ],
               []
             )

    assert :ok = TransactionCoordinatorStore.persist_rows(Repo, [], ["tx-drop"])

    assert {:ok, loaded} = TransactionCoordinatorStore.load_state(Repo)
    assert Map.has_key?(loaded.transactions, "tx-keep")
    refute Map.has_key?(loaded.transactions, "tx-drop")
  end

  test "tuple transaction ids round-trip through the binary primary key" do
    tx_id = {:voxel_transaction, 42}

    assert :ok =
             TransactionCoordinatorStore.persist_rows(
               Repo,
               [{tx_id, %{transaction: %{state: :preparing}, begin_fingerprint: nil, decision_index: nil}}],
               []
             )

    assert {:ok, loaded} = TransactionCoordinatorStore.load_state(Repo)
    assert loaded.transactions[tx_id] == %{state: :preparing}
  end

  test "a corrupt row is skipped rather than failing the whole load" do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    # 写一个好行 + 一个 payload 损坏的行。
    good_id = :erlang.term_to_binary("tx-good")
    good_payload = :erlang.term_to_binary(%{transaction: %{state: :preparing}})
    bad_id = :erlang.term_to_binary("tx-bad")
    bad_payload = <<0, 1, 2, 3>>

    Repo.query!(
      "INSERT INTO voxel_transaction_coordinator_rows (transaction_id, payload, inserted_at, updated_at) VALUES ($1, $2, $3, $3), ($4, $5, $3, $3)",
      [good_id, good_payload, now, bad_id, bad_payload]
    )

    assert {:ok, loaded} = TransactionCoordinatorStore.load_state(Repo)
    assert loaded.transactions["tx-good"] == %{state: :preparing}
    refute Map.has_key?(loaded.transactions, "tx-bad")
  end

  test "persist_rows_fn / load_fn round-trip without referencing the repo at the call site" do
    persist = TransactionCoordinatorStore.persist_rows_fn(Repo)
    load = TransactionCoordinatorStore.load_fn(Repo)

    assert :ok =
             persist.(
               [{"tx-fn", %{transaction: %{state: :preparing}, begin_fingerprint: nil, decision_index: nil}}],
               []
             )

    assert {:ok, loaded} = load.()
    assert loaded.transactions["tx-fn"] == %{state: :preparing}
  end
end
