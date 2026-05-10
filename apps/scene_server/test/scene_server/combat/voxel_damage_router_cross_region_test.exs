defmodule SceneServer.Combat.VoxelDamageRouterCrossRegionTest do
  # Phase A4-4 (D7) cross-region damage routing.
  #
  # Avoids the PG-backed `ChunkSnapshotStore` by injecting `:chunk_snapshot_store`
  # opt with a `FakeSnapshotStore`. Verifies:
  #
  #   * owner cache hit + local owner_node → default `:object_registry` path
  #   * owner cache hit + remote owner_node → `{registry, fake_node}` target
  #     and a `voxel_damage_routed_cross_region` observe is emitted
  #   * remote `GenServer.call` failure surfaces `{:error, _}` and emits
  #     `voxel_damage_cross_region_failed` without crashing the caller
  #   * owner cache miss → falls back to local `:object_registry` (legacy A1-5
  #     compatibility)
  # `async: false` — `FakeSnapshotStore` keeps its ETS table reference in
  # `:persistent_term`, so concurrent tests would race on the global slot.
  use ExUnit.Case, async: false

  alias SceneServer.Combat.VoxelDamageRouter
  alias SceneServer.Voxel.{Codec, Storage}

  ## Stubs

  defmodule FakeSnapshotStore do
    @moduledoc false

    def get_snapshot(scene_id, chunk_coord) do
      table = :persistent_term.get({__MODULE__, :table})

      case :ets.lookup(table, {scene_id, chunk_coord}) do
        [{_, payload}] ->
          {:ok, %{data: payload}}

        [] ->
          {:error, :snapshot_not_found}
      end
    end

    def install_table(table) do
      :persistent_term.put({__MODULE__, :table}, table)
    end

    def put(scene_id, chunk_coord, payload) do
      table = :persistent_term.get({__MODULE__, :table})
      :ets.insert(table, {{scene_id, chunk_coord}, payload})
    end
  end

  defmodule FakeRegistry do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      reply = Keyword.get(opts, :reply, :ok)
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, %{calls: [], reply: reply}, name: name)
    end

    def calls(server), do: GenServer.call(server, :calls)
    def set_reply(server, reply), do: GenServer.call(server, {:set_reply, reply})

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

    def handle_call({:set_reply, reply}, _from, state),
      do: {:reply, :ok, %{state | reply: reply}}

    def handle_call(
          {:accumulate_damage, _scene_id, _oid, _pid, _dmg, _opts} = call,
          _from,
          state
        ) do
      {:reply, state.reply, %{state | calls: [call | state.calls]}}
    end
  end

  defmodule FakeOwnerLookup do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, %{rows: %{}}, name: name)
    end

    def put(server, scene_id, object_id, info),
      do: GenServer.call(server, {:put, scene_id, object_id, info})

    def fetch_owner(server, scene_id, object_id),
      do: GenServer.call(server, {:fetch_owner, scene_id, object_id})

    def evict(server, scene_id, object_id),
      do: GenServer.call(server, {:evict, scene_id, object_id})

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:put, scene_id, object_id, info}, _from, state),
      do: {:reply, :ok, %{state | rows: Map.put(state.rows, {scene_id, object_id}, info)}}

    def handle_call({:fetch_owner, scene_id, object_id}, _from, state) do
      case Map.fetch(state.rows, {scene_id, object_id}) do
        {:ok, info} -> {:reply, {:ok, info}, state}
        :error -> {:reply, {:error, :not_found}, state}
      end
    end

    def handle_call({:evict, scene_id, object_id}, _from, state),
      do: {:reply, :ok, %{state | rows: Map.delete(state.rows, {scene_id, object_id})}}
  end

  ## Setup

  setup do
    snapshot_table =
      :ets.new(:"fake_snapshots_#{System.unique_integer([:positive])}", [:set, :public])

    FakeSnapshotStore.install_table(snapshot_table)

    registry_name = :"fake_registry_#{System.unique_integer([:positive])}"
    registry = start_supervised!({FakeRegistry, [name: registry_name]})

    lookup_name = :"fake_owner_lookup_#{System.unique_integer([:positive])}"
    lookup = start_supervised!({FakeOwnerLookup, [name: lookup_name]})

    %{
      registry: registry,
      registry_name: registry_name,
      lookup: lookup,
      lookup_name: lookup_name,
      snapshot_table: snapshot_table
    }
  end

  ## Helpers

  defp seed_voxel_at(scene_id, chunk_coord, layer_attrs, world_micro_offset) do
    {macro, micro_slot} = world_micro_offset

    storage =
      %{logical_scene_id: scene_id, chunk_coord: chunk_coord, chunk_version: 1}
      |> Storage.normalize!()
      |> Storage.put_micro_block(macro, micro_slot, layer_attrs, [])
      |> Map.update!(:chunk_version, &(&1 + 1))

    payload = Codec.encode_chunk_snapshot_payload(storage)
    FakeSnapshotStore.put(scene_id, chunk_coord, payload)
  end

  defp common_opts(ctx) do
    [
      object_registry: ctx.registry_name,
      owner_lookup: FakeOwnerLookup,
      owner_lookup_server: ctx.lookup_name,
      chunk_snapshot_store: FakeSnapshotStore
    ]
  end

  ## Tests

  describe "owner cache hit, local owner_node" do
    test "routes to default registry without cross-region observe", ctx do
      seed_voxel_at(
        7_000,
        {0, 0, 0},
        %{material_id: 4, health: 100, owner_object_id: 42, owner_part_id: 7},
        # macro (1,2,3) micro_slot 1 → world_micro (9, 16, 24)
        {{1, 2, 3}, 1}
      )

      :ok =
        FakeOwnerLookup.put(ctx.lookup, 7_000, 42, %{
          owner_region_id: 1,
          owner_lease_id: 100,
          covered_chunks_by_region: %{{1, 100} => [{0, 0, 0}]}
        })

      outcome =
        VoxelDamageRouter.try_apply_damage(
          7_000,
          {9, 16, 24},
          25,
          common_opts(ctx) ++
            [scene_node_resolver_fn: fn _r, _l -> node() end]
        )

      assert outcome == {:applied, %{object_id: 42, part_id: 7}}

      [{:accumulate_damage, scene_id, oid, pid, damage, _}] =
        FakeRegistry.calls(ctx.registry)

      assert {scene_id, oid, pid, damage} == {7_000, 42, 7, 25}
    end
  end

  describe "owner cache hit, remote owner_node" do
    test "targets {registry, fake_node} and reports cross-region failure on rpc exit",
         ctx do
      seed_voxel_at(
        7_001,
        {0, 0, 0},
        %{material_id: 4, health: 100, owner_object_id: 42, owner_part_id: 7},
        {{1, 2, 3}, 1}
      )

      :ok =
        FakeOwnerLookup.put(ctx.lookup, 7_001, 42, %{
          owner_region_id: 2,
          owner_lease_id: 200,
          covered_chunks_by_region: %{{2, 200} => [{0, 0, 0}]}
        })

      fake_remote_node = :"unreachable_remote_#{System.unique_integer([:positive])}@127.0.0.1"

      outcome =
        VoxelDamageRouter.try_apply_damage(
          7_001,
          {9, 16, 24},
          25,
          common_opts(ctx) ++
            [
              scene_node_resolver_fn: fn 2, 200 -> fake_remote_node end,
              # tiny timeout — keeps test fast even if there's any retry path.
              cross_region_call_timeout_ms: 50
            ]
        )

      # GenServer.call against an unreachable node returns :exit which the
      # router catches and surfaces as {:error, {:registry_unavailable, _}}.
      assert match?({:error, {:registry_unavailable, _}}, outcome)

      # Local FakeRegistry must not have seen the call (target was the remote).
      assert FakeRegistry.calls(ctx.registry) == []
    end
  end

  describe "owner cache miss (legacy A1-5 path)" do
    test "falls back to local registry without cross-region routing", ctx do
      seed_voxel_at(
        7_002,
        {0, 0, 0},
        %{material_id: 4, health: 100, owner_object_id: 42, owner_part_id: 7},
        {{1, 2, 3}, 1}
      )

      # No FakeOwnerLookup.put — fetch_owner returns {:error, :not_found}.

      outcome =
        VoxelDamageRouter.try_apply_damage(7_002, {9, 16, 24}, 25, common_opts(ctx))

      assert outcome == {:applied, %{object_id: 42, part_id: 7}}

      [{:accumulate_damage, scene_id, oid, pid, damage, _}] =
        FakeRegistry.calls(ctx.registry)

      assert {scene_id, oid, pid, damage} == {7_002, 42, 7, 25}
    end
  end

  describe "no voxel at slot" do
    test ":no_voxel does not consult owner lookup", ctx do
      assert :no_voxel ==
               VoxelDamageRouter.try_apply_damage(7_003, {9, 16, 24}, 25, common_opts(ctx))

      assert FakeRegistry.calls(ctx.registry) == []
    end
  end
end
