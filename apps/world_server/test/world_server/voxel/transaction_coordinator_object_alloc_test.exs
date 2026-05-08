defmodule WorldServer.Voxel.TransactionCoordinatorObjectAllocTest do
  # Phase 4 Step 4-4: BuildTransaction.scene_objects 字段 + 在 begin_transaction
  # 内分配 object_id (decision doc D2 + D3)。
  use ExUnit.Case, async: true

  alias WorldServer.Voxel.BuildTransaction
  alias WorldServer.Voxel.TransactionCoordinator
  alias WorldServer.Voxel.TransactionParticipant

  describe "begin_transaction with scene_objects (Phase 4 D2 + D3)" do
    test "default scene_objects field is empty when seeds not supplied" do
      coordinator = start_coordinator!()

      assert {:ok, %BuildTransaction{scene_objects: []}} =
               TransactionCoordinator.begin_transaction(
                 coordinator,
                 "tx-no-objects",
                 base_attrs()
               )
    end

    test "allocates object_id for each seed via next_object_id_fn" do
      coordinator = start_coordinator!(allocator_returning([100, 101]))

      attrs = Map.put(base_attrs(), :scene_objects, [seed_attrs(), seed_attrs(blueprint_id: 9)])

      assert {:ok, %BuildTransaction{scene_objects: scene_objects}} =
               TransactionCoordinator.begin_transaction(coordinator, "tx-objects", attrs)

      assert Enum.map(scene_objects, & &1.object_id) == [100, 101]
      assert Enum.at(scene_objects, 1).blueprint_id == 9
    end

    test "preserves all seed fields in the allocated scene_objects entries" do
      coordinator = start_coordinator!(allocator_returning([42]))

      seed =
        seed_attrs(
          blueprint_id: 7,
          blueprint_version: 3,
          parcel_id: 13,
          anchor_world_micro: {-1_000, 0, 500},
          rotation: 2,
          owner_actor_id: 1_001,
          covered_chunks: [{0, 0, 0}, {0, 0, 1}],
          state_flags: 0,
          object_attribute_ref: 0,
          object_tag_set_ref: 0,
          object_version: 1,
          part_states: [
            %{part_id: 1, health: 80, state_flags: 0},
            %{part_id: 2, health: 40, state_flags: 0}
          ]
        )

      attrs = Map.put(base_attrs(), :scene_objects, [seed])

      assert {:ok, %BuildTransaction{scene_objects: [obj]}} =
               TransactionCoordinator.begin_transaction(coordinator, "tx-roundtrip", attrs)

      assert obj.object_id == 42
      assert obj.blueprint_id == 7
      assert obj.blueprint_version == 3
      assert obj.parcel_id == 13
      assert obj.anchor_world_micro == {-1_000, 0, 500}
      assert obj.rotation == 2
      assert obj.owner_actor_id == 1_001
      assert obj.covered_chunks == [{0, 0, 0}, {0, 0, 1}]
      assert obj.part_states == seed.part_states
      assert obj.object_version == 1
    end

    test "rejects begin_transaction with :object_id_unavailable when allocator fails" do
      failing_allocator = fn -> {:error, :sequence_unavailable} end
      coordinator = start_coordinator!(next_object_id_fn: failing_allocator)

      attrs = Map.put(base_attrs(), :scene_objects, [seed_attrs()])

      assert {:error, :object_id_unavailable} =
               TransactionCoordinator.begin_transaction(coordinator, "tx-fail", attrs)
    end

    test "rejects begin_transaction with :object_id_unavailable when allocator raises" do
      raising_allocator = fn -> raise "boom" end
      coordinator = start_coordinator!(next_object_id_fn: raising_allocator)

      attrs = Map.put(base_attrs(), :scene_objects, [seed_attrs()])

      assert {:error, :object_id_unavailable} =
               TransactionCoordinator.begin_transaction(coordinator, "tx-raise", attrs)
    end

    test "rejects malformed seed (missing required field)" do
      coordinator = start_coordinator!(allocator_returning([1]))

      bad_seed = seed_attrs() |> Map.delete(:part_states)
      attrs = Map.put(base_attrs(), :scene_objects, [bad_seed])

      assert {:error, {:missing_scene_object_field, :part_states}} =
               TransactionCoordinator.begin_transaction(coordinator, "tx-bad", attrs)
    end

    test "rejects malformed seed (empty part_states)" do
      coordinator = start_coordinator!(allocator_returning([1]))

      bad_seed = seed_attrs(part_states: [])
      attrs = Map.put(base_attrs(), :scene_objects, [bad_seed])

      assert {:error, :invalid_part_states} =
               TransactionCoordinator.begin_transaction(coordinator, "tx-empty-parts", attrs)
    end

    test "rejects malformed seed (empty covered_chunks)" do
      coordinator = start_coordinator!(allocator_returning([1]))

      bad_seed = seed_attrs(covered_chunks: [])
      attrs = Map.put(base_attrs(), :scene_objects, [bad_seed])

      assert {:error, :invalid_covered_chunks} =
               TransactionCoordinator.begin_transaction(coordinator, "tx-empty-cov", attrs)
    end

    test "rejects malformed seed (anchor_world_micro not a triple)" do
      coordinator = start_coordinator!(allocator_returning([1]))

      bad_seed = seed_attrs(anchor_world_micro: {1, 2})
      attrs = Map.put(base_attrs(), :scene_objects, [bad_seed])

      assert {:error, :invalid_anchor_world_micro} =
               TransactionCoordinator.begin_transaction(coordinator, "tx-bad-anchor", attrs)
    end

    test "replay (same transaction_id) does NOT re-allocate ids" do
      # First call: counter returns [50]. If replay tried to allocate again it
      # would either fail (counter exhausted) or get a different id [51].
      counter = :counters.new(1, [])
      :counters.put(counter, 1, 0)

      allocator = fn ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 -> {:ok, 50}
          2 -> {:ok, 51}
          _ -> {:error, :exhausted}
        end
      end

      coordinator = start_coordinator!(next_object_id_fn: allocator)

      attrs = Map.put(base_attrs(), :scene_objects, [seed_attrs()])

      assert {:ok, %BuildTransaction{scene_objects: [%{object_id: 50}]} = t1} =
               TransactionCoordinator.begin_transaction(coordinator, "tx-replay", attrs)

      assert {:ok, %BuildTransaction{scene_objects: [%{object_id: 50}]} = t2} =
               TransactionCoordinator.begin_transaction(coordinator, "tx-replay", attrs)

      assert t1 == t2
      # Counter advanced only once (replay path skips allocation).
      assert :counters.get(counter, 1) == 1
    end

    test "scene_objects is NOT included in begin_fingerprint (replay tolerates seed drift)" do
      coordinator = start_coordinator!(allocator_returning([10, 11]))

      first_attrs = Map.put(base_attrs(), :scene_objects, [seed_attrs()])

      assert {:ok, %BuildTransaction{scene_objects: [%{object_id: 10}]}} =
               TransactionCoordinator.begin_transaction(coordinator, "tx-fp", first_attrs)

      # Replay with different seeds should still hit the existing transaction
      # (fingerprint excludes scene_objects).
      replay_attrs =
        Map.put(base_attrs(), :scene_objects, [seed_attrs(blueprint_id: 99)])

      assert {:ok, %BuildTransaction{scene_objects: [%{object_id: 10}]}} =
               TransactionCoordinator.begin_transaction(coordinator, "tx-fp", replay_attrs)
    end
  end

  describe "BuildTransaction struct shape" do
    test "default scene_objects is []" do
      assert %BuildTransaction{scene_objects: []} = stub_transaction()
    end
  end

  defp start_coordinator!(opts \\ []) do
    opts = Keyword.put_new(opts, :next_object_id_fn, fn -> {:ok, 1} end)

    start_supervised!(
      {TransactionCoordinator,
       Keyword.put(opts, :name, :"tx_coord_#{System.unique_integer([:positive])}")}
    )
  end

  defp allocator_returning(ids) when is_list(ids) do
    counter = :counters.new(1, [])
    :counters.put(counter, 1, 0)

    pid = self()

    allocator = fn ->
      :counters.add(counter, 1, 1)
      idx = :counters.get(counter, 1)

      case Enum.at(ids, idx - 1) do
        nil ->
          send(pid, {:allocator_exhausted, idx})
          {:error, :exhausted}

        id ->
          {:ok, id}
      end
    end

    [next_object_id_fn: allocator]
  end

  defp base_attrs do
    %{
      logical_scene_id: 1,
      parcel_id: 13,
      reservation_id: "res-1",
      decision_version: 1,
      participants: participants()
    }
  end

  defp participants do
    [
      %TransactionParticipant{
        region_id: 10,
        lease_id: 100,
        owner_scene_instance_ref: 1_000,
        owner_epoch: 1,
        affected_chunks: [{0, 0, 0}]
      }
    ]
  end

  defp seed_attrs(overrides \\ []) do
    overrides = Map.new(overrides)

    base = %{
      blueprint_id: 7,
      blueprint_version: 1,
      parcel_id: 13,
      anchor_world_micro: {1_000, 0, -500},
      rotation: 0,
      owner_actor_id: 1_001,
      covered_chunks: [{0, 0, 0}],
      state_flags: 0,
      object_attribute_ref: 0,
      object_tag_set_ref: 0,
      object_version: 1,
      part_states: [
        %{part_id: 1, health: 80, state_flags: 0}
      ]
    }

    Map.merge(base, overrides)
  end

  defp stub_transaction do
    %BuildTransaction{
      transaction_id: "stub",
      logical_scene_id: 1,
      parcel_id: 1,
      reservation_id: "stub",
      participants: [],
      intent_hash: 0,
      decision_version: 1,
      timeout_at_ms: 0
    }
  end
end
