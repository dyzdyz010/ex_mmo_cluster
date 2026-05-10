defmodule SceneServer.Voxel.ObjectRegistryCrossRegionTest do
  # Phase A4-4 (D7):0x6C ObjectStateDelta owner-driven fan-out — covered
  # chunks split per region, each region's chunks go through its own
  # ChunkDirectory target. Cache miss falls back to the legacy single-
  # chunk_directory path so A1/A2 single-region behaviour stays intact.
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.{Codec, ObjectRegistry, PartState}

  ## Stubs

  defmodule FakeStore do
    @moduledoc false
    def list_in_scene(_scene_id, _opts), do: []
    def put_object(_attrs, _opts), do: {:ok, :upserted}
    def delete_object(_object_id, _opts), do: {:ok, :deleted}
  end

  defmodule FakeRegionChunkDirectory do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      {server_opts, init_opts} = Keyword.split(opts, [:name])
      GenServer.start_link(__MODULE__, init_opts, server_opts)
    end

    # Override `use GenServer`'s default `id: __MODULE__` so a single test
    # supervisor can host multiple instances under different `:name` opts.
    def child_spec(opts) do
      %{
        id: Keyword.fetch!(opts, :name),
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    def register_chunk(server, scene_id, chunk_coord, pid) do
      GenServer.call(server, {:register, scene_id, chunk_coord, pid})
    end

    def lookups(server) do
      GenServer.call(server, :lookups)
    end

    @impl true
    def init(_init_opts) do
      {:ok, %{chunks: %{}, lookups: []}}
    end

    @impl true
    def handle_call({:register, scene_id, chunk_coord, pid}, _from, state) do
      {:reply, :ok, %{state | chunks: Map.put(state.chunks, {scene_id, chunk_coord}, pid)}}
    end

    def handle_call({:lookup_chunk_pid, scene_id, chunk_coord}, _from, state) do
      new_state = %{state | lookups: state.lookups ++ [{scene_id, chunk_coord}]}

      case Map.get(state.chunks, {scene_id, chunk_coord}) do
        pid when is_pid(pid) -> {:reply, {:ok, pid}, new_state}
        _ -> {:reply, :not_started, new_state}
      end
    end

    def handle_call(:lookups, _from, state) do
      {:reply, state.lookups, state}
    end

    # Cleanup / destroy_part stubs — return :ok so the registry's
    # destroy/cleanup pass can complete on a fake directory.
    def handle_call({:cleanup_object_refs, _attrs}, _from, state),
      do: {:reply, :ok, state}

    def handle_call({:destroy_part, _attrs}, _from, state),
      do: {:reply, :ok, state}
  end

  defmodule FakeOwnerLookup do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      name = Keyword.get(opts, :name, __MODULE__)
      GenServer.start_link(__MODULE__, %{rows: %{}}, name: name)
    end

    def put(server, scene_id, object_id, info) do
      GenServer.call(server, {:put, scene_id, object_id, info})
    end

    def fetch_owner(server, scene_id, object_id) do
      GenServer.call(server, {:fetch_owner, scene_id, object_id})
    end

    def evict(server, scene_id, object_id) do
      GenServer.call(server, {:evict, scene_id, object_id})
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:put, scene_id, object_id, info}, _from, state) do
      {:reply, :ok, %{state | rows: Map.put(state.rows, {scene_id, object_id}, info)}}
    end

    def handle_call({:fetch_owner, scene_id, object_id}, _from, state) do
      case Map.fetch(state.rows, {scene_id, object_id}) do
        {:ok, info} -> {:reply, {:ok, info}, state}
        :error -> {:reply, {:error, :not_found}, state}
      end
    end

    def handle_call({:evict, scene_id, object_id}, _from, state) do
      {:reply, :ok, %{state | rows: Map.delete(state.rows, {scene_id, object_id})}}
    end
  end

  ## Setup

  setup do
    test_pid = self()

    fake_dir_a =
      start_supervised!(
        {FakeRegionChunkDirectory, name: :"fake_dir_a_#{System.unique_integer([:positive])}"}
      )

    fake_dir_b =
      start_supervised!(
        {FakeRegionChunkDirectory, name: :"fake_dir_b_#{System.unique_integer([:positive])}"}
      )

    fake_lookup_name = :"fake_owner_lookup_#{System.unique_integer([:positive])}"
    fake_lookup = start_supervised!({FakeOwnerLookup, name: fake_lookup_name})

    region_routing = fn
      {1, 100} -> fake_dir_a
      {2, 200} -> fake_dir_b
      # Unknown participant key falls back to local chunk_directory.
      _ -> fake_dir_a
    end

    registry =
      start_supervised!(
        {ObjectRegistry,
         name: :"object_registry_#{System.unique_integer([:positive])}",
         store: FakeStore,
         chunk_directory: fake_dir_a,
         owner_lookup: FakeOwnerLookup,
         owner_lookup_server: fake_lookup_name,
         region_routing_fn: region_routing}
      )

    %{
      registry: registry,
      fake_dir_a: fake_dir_a,
      fake_dir_b: fake_dir_b,
      fake_lookup: fake_lookup,
      fake_lookup_name: fake_lookup_name,
      test_pid: test_pid
    }
  end

  describe "owner-driven fan-out (D7)" do
    test "splits chunks across two regions, dispatching to each region's chunk_directory",
         ctx do
      # Object covers two chunks: (0,0,0) in region A, (1,0,0) in region B.
      :ok =
        ObjectRegistry.upsert_object(
          ctx.registry,
          build_instance(
            object_id: 42,
            covered_chunks: [{0, 0, 0}, {1, 0, 0}],
            owner_region_id: 1,
            owner_lease_id: 100
          )
        )

      :ok =
        FakeOwnerLookup.put(ctx.fake_lookup, 1, 42, %{
          owner_region_id: 1,
          owner_lease_id: 100,
          covered_chunks_by_region: %{
            {1, 100} => [{0, 0, 0}],
            {2, 200} => [{1, 0, 0}]
          }
        })

      register_chunk(ctx.fake_dir_a, 1, {0, 0, 0}, ctx.test_pid)
      register_chunk(ctx.fake_dir_b, 1, {1, 0, 0}, ctx.test_pid)

      assert :ok = ObjectRegistry.accumulate_damage(ctx.registry, 1, 42, 1, 10)

      # Both ChunkDirectory targets received exactly one cast each, with the
      # same encoded payload (encode-once + multi-fan-out).
      assert_received {:"$gen_cast", {:push_object_state_delta_payload, payload_a}}
      assert_received {:"$gen_cast", {:push_object_state_delta_payload, payload_b}}
      assert payload_a == payload_b

      # Both fake directories saw a lookup_chunk_pid for their respective
      # chunks(per-region split honored)。
      assert FakeRegionChunkDirectory.lookups(ctx.fake_dir_a) == [{1, {0, 0, 0}}]
      assert FakeRegionChunkDirectory.lookups(ctx.fake_dir_b) == [{1, {1, 0, 0}}]

      # Encoded payload still carries every covered chunk as `affected_chunks`
      # (wire shape unchanged so existing client decoders keep working;
      # per-region split only affects fan-out routing)。
      assert {:ok, decoded, ""} = Codec.decode_voxel_object_state_delta_payload(payload_a)
      assert Enum.sort(decoded.affected_chunks) == [{0, 0, 0}, {1, 0, 0}]
      assert decoded.object_id == 42
    end

    test "owner_lookup miss falls back to local chunk_directory for every chunk", ctx do
      :ok =
        ObjectRegistry.upsert_object(
          ctx.registry,
          build_instance(
            object_id: 99,
            covered_chunks: [{0, 0, 0}, {1, 0, 0}],
            owner_region_id: 1,
            owner_lease_id: 100
          )
        )

      # No FakeOwnerLookup.put — fetch_owner returns {:error, :not_found}.

      register_chunk(ctx.fake_dir_a, 1, {0, 0, 0}, ctx.test_pid)
      register_chunk(ctx.fake_dir_a, 1, {1, 0, 0}, ctx.test_pid)

      assert :ok = ObjectRegistry.accumulate_damage(ctx.registry, 1, 99, 1, 10)

      # Both chunks went through fake_dir_a (local fallback)。
      assert FakeRegionChunkDirectory.lookups(ctx.fake_dir_a) ==
               [{1, {0, 0, 0}}, {1, {1, 0, 0}}]

      assert FakeRegionChunkDirectory.lookups(ctx.fake_dir_b) == []
    end

    test "destroy_object evicts the owner cache", ctx do
      :ok =
        ObjectRegistry.upsert_object(
          ctx.registry,
          build_instance(object_id: 7, covered_chunks: [{0, 0, 0}])
        )

      :ok =
        FakeOwnerLookup.put(ctx.fake_lookup, 1, 7, %{
          owner_region_id: 1,
          owner_lease_id: 100,
          covered_chunks_by_region: %{{1, 100} => [{0, 0, 0}]}
        })

      register_chunk(ctx.fake_dir_a, 1, {0, 0, 0}, ctx.test_pid)

      # `run_destroy_object` reads `:chunk_directory` from the destroy_object
      # opts (not from registry state) — pass the fake_dir explicitly so
      # `cleanup_object_refs` does not try to talk to the unstarted production
      # `ChunkDirectory` atom. Mirrors how `BuildTransactionApplier.commit/3`
      # threads opts on the production path.
      assert {:object_destroyed, _} =
               ObjectRegistry.destroy_object(ctx.registry, 1, 7, chunk_directory: ctx.fake_dir_a)

      # Cache evicted: fetch_owner now misses.
      assert {:error, :not_found} = FakeOwnerLookup.fetch_owner(ctx.fake_lookup, 1, 7)
    end
  end

  defp build_instance(overrides) do
    overrides = Map.new(overrides)

    base = %{
      object_id: 42,
      logical_scene_id: 1,
      parcel_id: 13,
      blueprint_id: 7,
      blueprint_version: 2,
      anchor_world_micro: {1_000, 0, -500},
      rotation: 0,
      owner_actor_id: 1_001,
      state_flags: 0,
      object_attribute_ref: 0,
      object_tag_set_ref: 0,
      covered_chunks: [{0, 0, 0}],
      part_states: [PartState.new(part_id: 1, health: 80, state_flags: 0)],
      object_version: 1,
      owner_region_id: 1,
      owner_lease_id: 100
    }

    Map.merge(base, overrides)
  end

  defp register_chunk(server, scene_id, chunk_coord, pid) do
    FakeRegionChunkDirectory.register_chunk(server, scene_id, chunk_coord, pid)
  end
end
