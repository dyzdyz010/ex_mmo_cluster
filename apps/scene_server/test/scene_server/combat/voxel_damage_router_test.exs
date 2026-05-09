defmodule SceneServer.Combat.VoxelDamageRouterTest do
  use ExUnit.Case, async: false

  alias DataService.Repo
  alias DataService.Schema.VoxelChunkSnapshot
  alias SceneServer.Combat.VoxelDamageRouter
  alias SceneServer.Voxel.{Codec, Storage}

  setup do
    Repo.delete_all(VoxelChunkSnapshot)
    :ok
  end

  defmodule FakeRegistry do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, %{calls: [], reply: Keyword.get(opts, :reply, :ok)},
        name: opts[:name]
      )
    end

    def calls(server), do: GenServer.call(server, :calls)
    def set_reply(server, reply), do: GenServer.call(server, {:set_reply, reply})

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

    def handle_call({:set_reply, reply}, _from, state), do: {:reply, :ok, %{state | reply: reply}}

    def handle_call({:accumulate_damage, _scene_id, _oid, _pid, _dmg, _opts} = call, _from, state) do
      {:reply, state.reply, %{state | calls: [call | state.calls]}}
    end
  end

  defp persist_storage(scene_id, chunk_coord, storage) do
    payload = Codec.encode_chunk_snapshot_payload(storage)

    Repo.insert!(%VoxelChunkSnapshot{
      logical_scene_id: scene_id,
      coord_x: elem(chunk_coord, 0),
      coord_y: elem(chunk_coord, 1),
      coord_z: elem(chunk_coord, 2),
      chunk_version: storage.chunk_version,
      schema_version: 1,
      chunk_size_in_macro: 16,
      micro_resolution: 8,
      region_id: 0,
      lease_id: 0,
      owner_scene_instance_ref: 0,
      owner_epoch: 0,
      chunk_hash: <<0::64>>,
      data: payload
    })
  end

  test "returns :no_voxel when ChunkSnapshotStore has no row for the target chunk" do
    {:ok, registry} = start_supervised({FakeRegistry, []})

    outcome = VoxelDamageRouter.try_apply_damage(7_777, {0, 0, 0}, 10, object_registry: registry)
    assert outcome == :no_voxel
    assert FakeRegistry.calls(registry) == []
  end

  test "returns :no_voxel when target slot is unowned (empty macro)" do
    {:ok, registry} = start_supervised({FakeRegistry, []})

    storage =
      %{
        logical_scene_id: 7_778,
        chunk_coord: {0, 0, 0},
        chunk_version: 1
      }
      |> Storage.normalize!()

    persist_storage(7_778, {0, 0, 0}, storage)

    outcome =
      VoxelDamageRouter.try_apply_damage(7_778, {8, 16, 24}, 10, object_registry: registry)

    assert outcome == :no_voxel
    assert FakeRegistry.calls(registry) == []
  end

  test "dispatches accumulate_damage when target slot has owner_object_id/part_id" do
    {:ok, registry} = start_supervised({FakeRegistry, []})

    layer_attrs = %{
      material_id: 4,
      health: 100,
      owner_object_id: 42,
      owner_part_id: 7
    }

    # macro (1,2,3)、micro slot (1,0,0) → linear slot 1
    storage =
      %{
        logical_scene_id: 7_779,
        chunk_coord: {0, 0, 0},
        chunk_version: 1
      }
      |> Storage.normalize!()
      |> Storage.put_micro_block({1, 2, 3}, 1, layer_attrs, [])
      |> bump_chunk_version()

    persist_storage(7_779, {0, 0, 0}, storage)

    # world_micro = (8 + 1, 16, 24) = (9, 16, 24)
    outcome =
      VoxelDamageRouter.try_apply_damage(7_779, {9, 16, 24}, 25, object_registry: registry)

    assert outcome == {:applied, %{object_id: 42, part_id: 7}}

    [{:accumulate_damage, scene_id, oid, pid, damage, _opts}] = FakeRegistry.calls(registry)
    assert scene_id == 7_779
    assert oid == 42
    assert pid == 7
    assert damage == 25
  end

  test "surfaces ObjectRegistry's :part_destroyed cascade as :cascade outcome" do
    cascade = {:part_destroyed, %{object_id: 42, part_id: 7, remaining_parts: 0}}
    {:ok, registry} = start_supervised({FakeRegistry, [reply: cascade]})

    layer_attrs = %{
      material_id: 4,
      health: 1,
      owner_object_id: 42,
      owner_part_id: 7
    }

    storage =
      %{
        logical_scene_id: 7_780,
        chunk_coord: {0, 0, 0},
        chunk_version: 1
      }
      |> Storage.normalize!()
      |> Storage.put_micro_block({1, 2, 3}, 5, layer_attrs, [])
      |> bump_chunk_version()

    persist_storage(7_780, {0, 0, 0}, storage)

    # world_micro for macro (1,2,3) micro_slot 5 = (1*8 + 5, 2*8, 3*8) = (13, 16, 24)
    outcome =
      VoxelDamageRouter.try_apply_damage(7_780, {13, 16, 24}, 999, object_registry: registry)

    assert {:cascade, ^cascade} = outcome
  end

  defp bump_chunk_version(%{chunk_version: v} = storage), do: %{storage | chunk_version: v + 1}
end
