defmodule SceneServer.Voxel.ObjectOwnerLookupTest do
  # Phase A4-4 (D7):per-scene owner cache underpinning cross-region damage
  # routing and 0x6C ObjectStateDelta fan-out.
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.ObjectOwnerLookup

  defmodule FakeStore do
    @moduledoc false

    def get_object(object_id, opts) do
      table = Keyword.fetch!(opts, :table)

      case :ets.lookup(table, object_id) do
        [{_, obj}] -> {:ok, obj}
        [] -> {:error, :object_not_found}
      end
    end
  end

  setup do
    fake_table = :ets.new(:fake_objects, [:set, :public])

    name = :"owner_lookup_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {ObjectOwnerLookup, name: name, store: FakeStore, store_opts: [table: fake_table]}
      )

    %{name: name, pid: pid, fake_table: fake_table}
  end

  describe "fetch_owner/3" do
    test "miss returns :not_found when row does not exist", %{name: name} do
      assert {:error, :not_found} = ObjectOwnerLookup.fetch_owner(name, 1, 999)
    end

    test "cold-start miss reads from store and populates ETS",
         %{name: name, fake_table: tbl} do
      seed_object(tbl, %{
        object_id: 42,
        logical_scene_id: 7,
        owner_region_id: 11,
        owner_lease_id: 101,
        covered_chunks: [{0, 0, 0}, {1, 0, 0}]
      })

      assert {:ok, info} = ObjectOwnerLookup.fetch_owner(name, 7, 42)
      assert info.owner_region_id == 11
      assert info.owner_lease_id == 101
      # Cold-start degenerate split:every chunk attributed to the owner key.
      assert info.covered_chunks_by_region == %{
               {11, 101} => [{0, 0, 0}, {1, 0, 0}]
             }

      # Second call must hit ETS without falling through to the store. We
      # remove the seeded row from the fake store; a cache miss would now
      # surface :not_found, but a cache hit must still succeed.
      :ets.delete(tbl, 42)
      assert {:ok, ^info} = ObjectOwnerLookup.fetch_owner(name, 7, 42)
    end

    test "scopes to scene_id (different scene returns :not_found)",
         %{name: name, fake_table: tbl} do
      seed_object(tbl, %{
        object_id: 42,
        logical_scene_id: 7,
        owner_region_id: 11,
        owner_lease_id: 101,
        covered_chunks: [{0, 0, 0}]
      })

      assert {:error, :not_found} = ObjectOwnerLookup.fetch_owner(name, 99, 42)
    end
  end

  describe "register/3" do
    test "writes the explicit per-region split, overriding cold-start shape",
         %{name: name, fake_table: tbl} do
      seed_object(tbl, %{
        object_id: 42,
        logical_scene_id: 7,
        owner_region_id: 11,
        owner_lease_id: 101,
        covered_chunks: [{0, 0, 0}, {1, 0, 0}]
      })

      # First a cold-start miss populates the degenerate split.
      assert {:ok, %{covered_chunks_by_region: %{{11, 101} => _}}} =
               ObjectOwnerLookup.fetch_owner(name, 7, 42)

      explicit = %{
        {11, 101} => [{0, 0, 0}],
        {12, 102} => [{1, 0, 0}]
      }

      :ok =
        ObjectOwnerLookup.register(
          name,
          %{
            logical_scene_id: 7,
            object_id: 42,
            owner_region_id: 11,
            owner_lease_id: 101
          },
          explicit
        )

      assert {:ok, info} = ObjectOwnerLookup.fetch_owner(name, 7, 42)
      assert info.owner_region_id == 11
      assert info.owner_lease_id == 101
      assert info.covered_chunks_by_region == explicit
    end

    test "register without a prior store seed still caches", %{name: name} do
      explicit = %{{1, 1} => [{0, 0, 0}]}

      :ok =
        ObjectOwnerLookup.register(
          name,
          %{
            logical_scene_id: 9,
            object_id: 7,
            owner_region_id: 1,
            owner_lease_id: 1
          },
          explicit
        )

      assert {:ok, info} = ObjectOwnerLookup.fetch_owner(name, 9, 7)
      assert info.covered_chunks_by_region == explicit
    end
  end

  describe "evict/3" do
    test "removes the cache entry; subsequent fetch falls through to store",
         %{name: name, fake_table: tbl} do
      seed_object(tbl, %{
        object_id: 42,
        logical_scene_id: 7,
        owner_region_id: 11,
        owner_lease_id: 101,
        covered_chunks: [{0, 0, 0}]
      })

      assert {:ok, _} = ObjectOwnerLookup.fetch_owner(name, 7, 42)

      :ok = ObjectOwnerLookup.evict(name, 7, 42)
      :ets.delete(tbl, 42)

      assert {:error, :not_found} = ObjectOwnerLookup.fetch_owner(name, 7, 42)
    end

    test "evicting a missing entry is idempotent", %{name: name} do
      assert :ok = ObjectOwnerLookup.evict(name, 7, 999)
    end
  end

  describe "clear/1" do
    test "drops all cache entries", %{name: name, fake_table: tbl} do
      seed_object(tbl, %{
        object_id: 42,
        logical_scene_id: 7,
        owner_region_id: 11,
        owner_lease_id: 101,
        covered_chunks: [{0, 0, 0}]
      })

      assert {:ok, _} = ObjectOwnerLookup.fetch_owner(name, 7, 42)

      :ok = ObjectOwnerLookup.clear(name)
      :ets.delete(tbl, 42)

      assert {:error, :not_found} = ObjectOwnerLookup.fetch_owner(name, 7, 42)
    end
  end

  describe "snapshot/1" do
    test "returns the cached rows", %{name: name} do
      explicit = %{{1, 1} => [{0, 0, 0}]}

      :ok =
        ObjectOwnerLookup.register(
          name,
          %{
            logical_scene_id: 9,
            object_id: 7,
            owner_region_id: 1,
            owner_lease_id: 1
          },
          explicit
        )

      assert [{{9, 7}, 1, 1, ^explicit}] = ObjectOwnerLookup.snapshot(name)
    end
  end

  defp seed_object(table, attrs) do
    :ets.insert(table, {attrs.object_id, attrs})
  end
end
