defmodule DataService.Voxel.RegionDirectoryStoreTest do
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Voxel.RegionDirectoryStore, as: Store

  setup do
    Store.reset()
    :ok
  end

  defp region_attrs(region_id, overrides \\ %{}) do
    Map.merge(
      %{
        region_id: region_id,
        logical_scene_id: 1,
        bounds_chunk_min_x: 0,
        bounds_chunk_min_y: 0,
        bounds_chunk_min_z: 0,
        bounds_chunk_max_x: 8,
        bounds_chunk_max_y: 64,
        bounds_chunk_max_z: 8,
        owner_scene_instance_ref: 1,
        owner_epoch: 3,
        lease_id: 100,
        assigned_scene_node: "scene1@host",
        region_state: "active",
        region_version: 2,
        expires_at_ms: 1_700_000_000_000
      },
      overrides
    )
  end

  test "upsert + get round-trips every field including nullable ones" do
    assert :ok = Store.upsert_region(region_attrs(10))
    assert {:ok, row} = Store.get_region(10)
    assert row.region_id == 10
    assert row.logical_scene_id == 1
    assert row.bounds_chunk_max_y == 64
    assert row.owner_epoch == 3
    assert row.lease_id == 100
    assert row.assigned_scene_node == "scene1@host"
    assert row.region_state == "active"
    assert row.region_version == 2
    assert row.expires_at_ms == 1_700_000_000_000
  end

  test "nullable fields round-trip nil (a region before its lease is issued)" do
    assert :ok =
             Store.upsert_region(
               region_attrs(11, %{lease_id: nil, assigned_scene_node: nil, expires_at_ms: nil})
             )

    assert {:ok, row} = Store.get_region(11)
    assert row.lease_id == nil
    assert row.assigned_scene_node == nil
    assert row.expires_at_ms == nil
  end

  test "upsert is last-writer-wins on region_id (O(1) per change, no torn blob)" do
    assert :ok = Store.upsert_region(region_attrs(12, %{owner_epoch: 1, region_version: 1}))
    assert :ok = Store.upsert_region(region_attrs(12, %{owner_epoch: 5, region_version: 9}))

    assert {:ok, row} = Store.get_region(12)
    assert row.owner_epoch == 5
    assert row.region_version == 9

    # Still exactly one row for that region.
    assert length(Store.load_all()) == 1
  end

  test "load_all and load_by_logical_scene (shard load path)" do
    assert :ok = Store.upsert_region(region_attrs(20, %{logical_scene_id: 1}))
    assert :ok = Store.upsert_region(region_attrs(21, %{logical_scene_id: 1}))
    assert :ok = Store.upsert_region(region_attrs(22, %{logical_scene_id: 2}))

    assert Store.load_all() |> length() == 3
    scene1 = Store.load_by_logical_scene(1)
    assert scene1 |> Enum.map(& &1.region_id) |> Enum.sort() == [20, 21]
    assert Store.load_by_logical_scene(2) |> Enum.map(& &1.region_id) == [22]
  end

  test "delete_region removes one row (region GC)" do
    assert :ok = Store.upsert_region(region_attrs(30))
    assert :ok = Store.upsert_region(region_attrs(31))
    assert :ok = Store.delete_region(30)

    assert Store.get_region(30) == :error
    assert {:ok, _} = Store.get_region(31)
  end

  test "upsert_region_in_repo commits atomically inside the caller's transaction" do
    {:ok, :ok} =
      Repo.transaction(fn ->
        Store.upsert_region_in_repo(Repo, region_attrs(40))
      end)

    assert {:ok, _} = Store.get_region(40)
  end

  test "a raising transaction rolls back the directory write (atomic boundary)" do
    result =
      Repo.transaction(fn ->
        Store.upsert_region_in_repo(Repo, region_attrs(41))
        Repo.rollback(:boom)
      end)

    assert result == {:error, :boom}
    # The directory write was rolled back with the rest of the transaction.
    assert Store.get_region(41) == :error
  end
end
