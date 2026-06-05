defmodule DataService.Voxel.SceneNodeRegistryStoreTest do
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Voxel.SceneNodeRegistryStore

  setup do
    # The umbrella test_helper runs migrations once at boot. Each test starts
    # from a clean slate by truncating the singleton row table.
    Repo.query!("TRUNCATE TABLE voxel_scene_node_registry_snapshots", [])
    :ok
  end

  test "load_state returns an empty map when no row has been written yet" do
    assert {:ok, %{}} = SceneNodeRegistryStore.load_state(Repo)
  end

  test "save_state inserts the row and load_state round-trips the same shape" do
    state = sample_state()

    assert :ok = SceneNodeRegistryStore.save_state(Repo, state)

    assert {:ok, loaded} = SceneNodeRegistryStore.load_state(Repo)

    assert loaded ==
             Map.take(state, [:join_order, :region_assignments, :round_robin_cursor])
  end

  test "node atoms and integer region keys round-trip exactly through term_to_binary" do
    state = sample_state()
    assert :ok = SceneNodeRegistryStore.save_state(Repo, state)

    assert {:ok, loaded} = SceneNodeRegistryStore.load_state(Repo)
    assert loaded.join_order == [:scene1@h, :scene2@h]
    assert loaded.region_assignments == %{100 => :scene1@h, 101 => :scene2@h}
    assert loaded.round_robin_cursor == 2
  end

  test "save_state replaces the existing row instead of inserting a second one" do
    assert :ok = SceneNodeRegistryStore.save_state(Repo, sample_state())

    next_state = %{
      join_order: [:scene9@h],
      region_assignments: %{500 => :scene9@h},
      round_robin_cursor: 1
    }

    assert :ok = SceneNodeRegistryStore.save_state(Repo, next_state)
    assert {:ok, loaded} = SceneNodeRegistryStore.load_state(Repo)
    assert loaded.join_order == [:scene9@h]
    assert loaded.region_assignments == next_state.region_assignments

    assert %{rows: [[1]]} =
             Repo.query!("SELECT count(*) FROM voxel_scene_node_registry_snapshots", [])
  end

  test "save_state strips unknown top-level keys before persisting" do
    state =
      sample_state()
      |> Map.put(:persist_fn, fn _ -> :ok end)
      |> Map.put(:transient, :nope)

    assert :ok = SceneNodeRegistryStore.save_state(Repo, state)

    assert {:ok, loaded} = SceneNodeRegistryStore.load_state(Repo)
    refute Map.has_key?(loaded, :persist_fn)
    refute Map.has_key?(loaded, :transient)
  end

  test "load_state rejects payloads with unexpected top-level keys" do
    bad_payload = :erlang.term_to_binary(%{join_order: [], foo: %{}})
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.query!(
      "INSERT INTO voxel_scene_node_registry_snapshots (id, payload, inserted_at, updated_at) VALUES (1, $1, $2, $2)",
      [bad_payload, now]
    )

    assert {:error, {:unexpected_keys, unexpected}} = SceneNodeRegistryStore.load_state(Repo)
    assert :foo in unexpected
  end

  test "load_state rejects a malformed join_order" do
    bad_payload = :erlang.term_to_binary(%{join_order: [1, 2, 3]})
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.query!(
      "INSERT INTO voxel_scene_node_registry_snapshots (id, payload, inserted_at, updated_at) VALUES (1, $1, $2, $2)",
      [bad_payload, now]
    )

    assert {:error, :unexpected_join_order_shape} = SceneNodeRegistryStore.load_state(Repo)
  end

  test "persist_fn / load_fn round-trip without referencing the repo at the call site" do
    persist = SceneNodeRegistryStore.persist_fn(Repo)
    load = SceneNodeRegistryStore.load_fn(Repo)
    state = sample_state()

    assert :ok = persist.(state)
    assert {:ok, loaded} = load.()
    assert loaded.region_assignments == state.region_assignments
  end

  defp sample_state do
    %{
      join_order: [:scene1@h, :scene2@h],
      region_assignments: %{100 => :scene1@h, 101 => :scene2@h},
      round_robin_cursor: 2
    }
  end
end
