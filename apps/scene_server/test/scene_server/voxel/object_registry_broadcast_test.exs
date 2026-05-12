defmodule SceneServer.Voxel.ObjectRegistryBroadcastTest do
  # Phase 4-bis Step 4-bis-5: ObjectRegistry 在 emit_damage / emit_part_destroyed
  # / emit_object_destroyed 之后 dispatch 0x6C ObjectStateDelta broadcast (D4)。
  use ExUnit.Case, async: false

  alias DataService.Voxel.SceneObjectStore
  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.ObjectRegistry
  alias SceneServer.Voxel.PartState

  setup do
    SceneObjectStore.reset()

    test_pid = self()
    fake_dir_name = :"fake_dir_#{System.unique_integer([:positive])}"
    fake_dir = start_supervised!({FakeChunkDirectory, name: fake_dir_name, test_pid: test_pid})

    registry =
      start_supervised!(
        {ObjectRegistry,
         name: :"object_registry_#{System.unique_integer([:positive])}", chunk_directory: fake_dir}
      )

    # Empty fake ChunkDirectory map → all dispatches will see :not_started
    # by default unless a test explicitly registers a "chunk pid" via
    # FakeChunkDirectory.register_chunk/3.
    %{registry: registry, fake_dir: fake_dir}
  end

  describe "dispatch on accumulate_damage health > 0 (Phase 4-bis D4)" do
    test "emits one 0x6C with flag_damaged when damage doesn't kill the part", ctx do
      register_chunks(ctx.fake_dir, 1, [{0, 0, 0}, {0, 0, 1}])

      :ok = ObjectRegistry.upsert_object(ctx.registry, build_instance())

      assert :ok = ObjectRegistry.accumulate_damage(ctx.registry, 1, 42, 1, 30)

      # Each affected chunk receives one cast — assertions per chunk_coord.
      assert_receive {:"$gen_cast", {:push_object_state_delta_payload, p1}}
      assert_receive {:"$gen_cast", {:push_object_state_delta_payload, p2}}

      [decoded1, decoded2] =
        for p <- [p1, p2] do
          {:ok, d, ""} = Codec.decode_voxel_object_state_delta_payload(p)
          d
        end

      # Same payload binary across chunks (encode-once + multi-fan-out).
      assert p1 == p2
      assert decoded1.object_id == 42
      assert decoded1.state_flags == PartState.flag_damaged()
      # object_version was bumped from 1 → 2 by accumulate_damage.
      assert decoded1.object_version == 2
      assert Enum.sort(decoded1.affected_chunks) == [{0, 0, 0}, {0, 0, 1}]
      assert decoded2 == decoded1
    end
  end

  describe "dispatch on emit_part_destroyed (Phase 4-bis D4)" do
    test "emits flag_part_destroyed on direct destroy_part call", ctx do
      register_chunks(ctx.fake_dir, 1, [{0, 0, 0}, {0, 0, 1}])

      :ok = ObjectRegistry.upsert_object(ctx.registry, build_instance())

      assert {:part_destroyed, _} = ObjectRegistry.destroy_part(ctx.registry, 1, 42, 1)

      # Two chunks → two casts.
      assert_receive {:"$gen_cast", {:push_object_state_delta_payload, p}}
      assert_receive {:"$gen_cast", {:push_object_state_delta_payload, ^p}}

      assert {:ok, decoded, ""} = Codec.decode_voxel_object_state_delta_payload(p)
      assert decoded.state_flags == PartState.flag_part_destroyed()
      assert decoded.object_version == 2
    end

    test "cascading damage → 2 0x6C messages: part_destroyed then destroyed", ctx do
      register_chunks(ctx.fake_dir, 1, [{0, 0, 0}])

      single_part_instance =
        build_instance(
          covered_chunks: [{0, 0, 0}],
          part_states: [PartState.new(part_id: 1, health: 10, state_flags: 0)]
        )

      :ok = ObjectRegistry.upsert_object(ctx.registry, single_part_instance)

      # Damage > health → cascade into destroy_part (last part) → destroy_object.
      assert {:object_destroyed, _} = ObjectRegistry.accumulate_damage(ctx.registry, 1, 42, 1, 50)

      # Expect two casts(part_destroyed flag + destroyed flag),delivered in order.
      assert_receive {:"$gen_cast", {:push_object_state_delta_payload, p_first}}
      assert_receive {:"$gen_cast", {:push_object_state_delta_payload, p_second}}

      assert {:ok, decoded_first, ""} = Codec.decode_voxel_object_state_delta_payload(p_first)
      assert {:ok, decoded_second, ""} = Codec.decode_voxel_object_state_delta_payload(p_second)

      assert decoded_first.state_flags == PartState.flag_part_destroyed()
      assert decoded_second.state_flags == PartState.flag_destroyed()

      # Versions are monotonic across the two messages (D5 / D3 dedupe).
      assert decoded_first.object_version < decoded_second.object_version
    end
  end

  describe "dispatch on emit_object_destroyed (Phase 4-bis D4)" do
    test "emits flag_destroyed on direct destroy_object call", ctx do
      register_chunks(ctx.fake_dir, 1, [{0, 0, 0}])

      :ok =
        ObjectRegistry.upsert_object(ctx.registry, build_instance(covered_chunks: [{0, 0, 0}]))

      assert {:object_destroyed, _} = ObjectRegistry.destroy_object(ctx.registry, 1, 42)

      assert_receive {:"$gen_cast", {:push_object_state_delta_payload, p}}

      assert {:ok, decoded, ""} = Codec.decode_voxel_object_state_delta_payload(p)
      assert decoded.state_flags == PartState.flag_destroyed()
      # destroy_object bumps object_version 1 → 2 in run_destroy_object.
      assert decoded.object_version == 2
    end
  end

  describe "dispatch failures do not block (Phase 4-bis D4)" do
    test "lookup :not_started silently swallows + does not crash registry", ctx do
      # Don't register any chunks — every lookup will return :not_started.
      :ok = ObjectRegistry.upsert_object(ctx.registry, build_instance())

      # accumulate_damage path completes successfully despite no chunks.
      assert :ok = ObjectRegistry.accumulate_damage(ctx.registry, 1, 42, 1, 30)

      # Registry is still usable.
      assert obj = ObjectRegistry.lookup_object(ctx.registry, 1, 42)
      assert obj.object_version == 2

      # No cast was delivered (every coord lookup was :not_started).
      refute_receive {:"$gen_cast", {:push_object_state_delta_payload, _}}, 50
    end
  end

  defp register_chunks(fake_dir, scene_id, coords) do
    test_pid = self()

    Enum.each(coords, fn coord ->
      FakeChunkDirectory.register_chunk(fake_dir, scene_id, coord, test_pid)
    end)
  end

  defp build_instance(overrides \\ []) do
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
      covered_chunks: [{0, 0, 0}, {0, 0, 1}],
      part_states: [
        PartState.new(part_id: 1, health: 80, state_flags: 0),
        PartState.new(part_id: 2, health: 40, state_flags: 0)
      ],
      object_version: 1,
      owner_region_id: 1,
      owner_lease_id: 100
    }

    Map.merge(base, overrides)
  end
end

defmodule FakeChunkDirectory do
  # Test fake that mimics SceneServer.Voxel.ChunkDirectory.lookup_chunk_pid/3.
  # Registered chunks return {:ok, pid_for_test_assert};unregistered return
  # :not_started. The directory itself is also a real GenServer so it can be
  # passed by name to ObjectRegistry init opts.
  use GenServer

  def start_link(opts) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def register_chunk(server, scene_id, chunk_coord, pid) do
    GenServer.call(server, {:register, scene_id, chunk_coord, pid})
  end

  @impl true
  def init(_init_opts) do
    {:ok, %{chunks: %{}}}
  end

  @impl true
  def handle_call({:register, scene_id, chunk_coord, pid}, _from, state) do
    {:reply, :ok, %{state | chunks: Map.put(state.chunks, {scene_id, chunk_coord}, pid)}}
  end

  @impl true
  def handle_call({:lookup_chunk_pid, scene_id, chunk_coord}, _from, state) do
    case Map.get(state.chunks, {scene_id, chunk_coord}) do
      pid when is_pid(pid) -> {:reply, {:ok, pid}, state}
      _ -> {:reply, :not_started, state}
    end
  end

  @impl true
  def handle_call({:destroy_part, _attrs}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:cleanup_object_refs, _attrs}, _from, state) do
    {:reply, :ok, state}
  end
end
