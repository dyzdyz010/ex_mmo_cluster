defmodule SceneServer.Movement.VoxelCollisionTest do
  use ExUnit.Case, async: false

  alias SceneServer.Movement.{CorrectionFlags, State, VoxelCollision}
  alias SceneServer.Voxel.ChunkDirectory
  alias SceneServer.Voxel.Types

  setup do
    SceneServer.TestVoxelRuntime.ensure_started!()
    :ok
  end

  test "resolve leaves movement unchanged when queried terrain is clear" do
    previous = State.idle({100.0, 100.0, 185.0})
    proposed = %{previous | position: {140.0, 100.0, 185.0}, velocity: {40.0, 0.0, 0.0}, tick: 1}

    {resolved, flags, summary} =
      VoxelCollision.resolve(previous, proposed,
        query_fun: fn _attrs ->
          {:ok, %{chunk_version: 0, occupied: []}}
        end
      )

    assert resolved == proposed
    assert flags == CorrectionFlags.none()
    assert summary.status == :clear
  end

  test "resolve forwards a collision query timeout to the terrain query" do
    previous = State.idle({100.0, 100.0, 185.0})
    proposed = %{previous | position: {140.0, 100.0, 185.0}, velocity: {40.0, 0.0, 0.0}, tick: 1}
    parent = self()

    {resolved, _flags, summary} =
      VoxelCollision.resolve(previous, proposed,
        query_timeout_ms: 25,
        query_fun: fn attrs ->
          send(parent, {:collision_query_timeout_ms, attrs.collision_query_timeout_ms})
          {:ok, %{chunk_version: 0, occupied: []}}
        end
      )

    assert resolved == proposed
    assert summary.status == :clear
    assert_receive {:collision_query_timeout_ms, 25}
  end

  test "resolve can use the default chunk directory collision query" do
    scene_id = unique_scene_id()

    assert {:ok, chunk_pid} =
             ChunkDirectory.ensure_chunk(%{
               logical_scene_id: scene_id,
               chunk_coord: {0, 0, 0}
             })

    _ = :sys.get_state(chunk_pid)

    previous = State.idle({100.0, 100.0, 185.0})
    proposed = %{previous | position: {140.0, 100.0, 185.0}, velocity: {40.0, 0.0, 0.0}, tick: 1}

    {resolved, flags, summary} =
      VoxelCollision.resolve(previous, proposed,
        logical_scene_id: scene_id,
        query_timeout_ms: 50
      )

    assert resolved == proposed
    assert flags == CorrectionFlags.none()
    assert summary.status == :clear
    assert [%{chunk_coord: {0, 0, 0}}] = summary.queried_chunks
  end

  test "resolve blocks horizontal penetration into occupied micro terrain" do
    previous = State.idle({100.0, 100.0, 185.0})

    proposed = %{
      previous
      | position: {150.0, 100.0, 185.0},
        velocity: {100.0, 0.0, 0.0},
        acceleration: {100.0, 0.0, 0.0},
        tick: 1
    }

    target = target_sample({12, 8, 8})

    {resolved, flags, summary} =
      VoxelCollision.resolve(previous, proposed, query_fun: query_fun_for(target))

    assert elem(resolved.position, 0) == elem(previous.position, 0)
    assert elem(resolved.velocity, 0) == 0.0
    assert elem(resolved.acceleration, 0) == 0.0
    assert CorrectionFlags.collision_push?(flags)
    assert summary.status == :resolved
    assert summary.blocked_axes == [:x]
    assert summary.occupied_count == 1
  end

  test "resolve snaps descending actor center to terrain top plus half height" do
    previous = State.idle({100.0, 100.0, 235.0})

    proposed = %{
      previous
      | position: {100.0, 100.0, 135.0},
        velocity: {0.0, 0.0, -400.0},
        acceleration: {0.0, 0.0, -980.0},
        movement_mode: :airborne,
        tick: 1
    }

    floor = target_sample({8, 7, 8})

    {resolved, flags, summary} =
      VoxelCollision.resolve(previous, proposed, query_fun: query_fun_for(floor))

    assert resolved.position == {100.0, 100.0, 185.0}
    assert resolved.velocity == {0.0, 0.0, 0.0}
    assert resolved.acceleration == {0.0, 0.0, 0.0}
    assert resolved.movement_mode == :grounded
    assert resolved.ground_z == 185.0
    assert CorrectionFlags.collision_push?(flags)
    assert summary.blocked_axes == [:z]
  end

  defp query_fun_for(target) do
    fn attrs ->
      occupied =
        if attrs.chunk_coord == target.chunk_coord and target.sample in attrs.samples do
          [target.sample]
        else
          []
        end

      {:ok, %{chunk_version: 1, occupied: occupied}}
    end
  end

  defp target_sample({world_x, world_y, world_z}) do
    world_macro = {
      Types.floor_div(world_x, Types.micro_resolution()),
      Types.floor_div(world_y, Types.micro_resolution()),
      Types.floor_div(world_z, Types.micro_resolution())
    }

    {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)

    local_micro = {
      Types.floor_mod(world_x, Types.micro_resolution()),
      Types.floor_mod(world_y, Types.micro_resolution()),
      Types.floor_mod(world_z, Types.micro_resolution())
    }

    %{
      chunk_coord: chunk_coord,
      sample: %{macro: local_macro, micro_slot: Types.micro_index!(local_micro)}
    }
  end

  defp unique_scene_id do
    System.unique_integer([:positive])
  end
end
