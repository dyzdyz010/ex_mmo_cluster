defmodule SceneServer.Movement.VoxelCollision do
  @moduledoc """
  Read-only voxel terrain collision resolver for authoritative movement.

  `PlayerCharacter` owns actor movement state. `ChunkProcess` owns voxel truth.
  This module sits between them as a stateless adapter: it converts movement
  center-anchor AABBs into voxel micro samples, queries chunk authority, and
  returns a corrected movement state plus ack correction flags.
  """

  alias SceneServer.Movement.{CorrectionFlags, State}
  alias SceneServer.Voxel.{ChunkDirectory, Types}

  @default_radius_cm 30.0
  @default_height_cm 170.0
  @cm_per_macro 100.0
  @micro_per_macro 8
  @cm_per_micro @cm_per_macro / @micro_per_macro
  @epsilon 1.0e-6
  @default_max_samples 4_096

  @type summary :: map()
  @type query_fun :: (map() -> {:ok, map()} | {:error, term()})

  @doc """
  Resolves `proposed_state` against authoritative voxel occupancy.

  Positions are movement centimeters `{x, y, z}` with `z` vertical. Voxel
  storage is queried in world-micro coordinates with voxel `y` vertical. The
  movement position is treated as the avatar center.
  """
  @spec resolve(State.t(), State.t(), keyword()) :: {State.t(), CorrectionFlags.t(), summary()}
  def resolve(%State{} = previous_state, %State{} = proposed_state, opts \\ []) do
    config = config(opts)

    if config.enabled? do
      do_resolve(previous_state, proposed_state, config)
    else
      {proposed_state, CorrectionFlags.none(), unavailable_summary(:disabled, proposed_state)}
    end
  end

  @doc """
  Converts a movement centimeter AABB into voxel world-micro half-open bounds.
  """
  @spec movement_aabb_to_voxel_micro(map()) :: map()
  def movement_aabb_to_voxel_micro(%{min: {min_x, min_y, min_z}, max: {max_x, max_y, max_z}}) do
    %{
      min: {
        floor_cm_to_micro(min_x),
        floor_cm_to_micro(min_z),
        floor_cm_to_micro(min_y)
      },
      max: {
        ceil_cm_to_micro(max_x),
        ceil_cm_to_micro(max_z),
        ceil_cm_to_micro(max_y)
      }
    }
  end

  defp do_resolve(previous_state, proposed_state, config) do
    query_aabb =
      previous_state.position
      |> movement_aabb_cm(config)
      |> union_aabb(movement_aabb_cm(proposed_state.position, config))
      |> movement_aabb_to_voxel_micro()

    sample_count = micro_aabb_volume(query_aabb)

    if sample_count > config.max_samples do
      {proposed_state, CorrectionFlags.none(),
       unavailable_summary(:sample_budget_exceeded, proposed_state)
       |> Map.merge(%{
         previous_position: previous_state.position,
         proposed_position: proposed_state.position,
         sample_count: sample_count,
         max_samples: config.max_samples,
         queried_chunks: []
       })}
    else
      samples_by_chunk = samples_by_chunk(query_aabb)

      do_resolve_with_samples(
        previous_state,
        proposed_state,
        samples_by_chunk,
        sample_count,
        config
      )
    end
  end

  defp do_resolve_with_samples(
         previous_state,
         proposed_state,
         samples_by_chunk,
         sample_count,
         config
       ) do
    case query_occupied_boxes(samples_by_chunk, config) do
      {:ok, %{boxes: [], queried_chunks: queried_chunks}} ->
        {proposed_state, CorrectionFlags.none(),
         %{
           enabled?: true,
           status: :clear,
           logical_scene_id: config.logical_scene_id,
           tick: proposed_state.tick,
           previous_position: previous_state.position,
           proposed_position: proposed_state.position,
           resolved_position: proposed_state.position,
           queried_chunks: queried_chunks,
           sample_count: sample_count,
           occupied_count: 0,
           blocked_axes: [],
           correction_flags: CorrectionFlags.none()
         }}

      {:ok, %{boxes: boxes, queried_chunks: queried_chunks}} ->
        {resolved_state, blocked_axes} =
          resolve_against_boxes(previous_state, proposed_state, boxes, config)

        flags =
          if blocked_axes == [] do
            CorrectionFlags.none()
          else
            CorrectionFlags.collision_push()
          end

        {resolved_state, flags,
         %{
           enabled?: true,
           status: :resolved,
           logical_scene_id: config.logical_scene_id,
           tick: proposed_state.tick,
           previous_position: previous_state.position,
           proposed_position: proposed_state.position,
           resolved_position: resolved_state.position,
           queried_chunks: queried_chunks,
           sample_count: sample_count,
           occupied_count: length(boxes),
           blocked_axes: blocked_axes,
           correction_flags: flags
         }}

      {:error, reason} ->
        {proposed_state, CorrectionFlags.none(),
         unavailable_summary(reason, proposed_state)
         |> Map.merge(%{
           previous_position: previous_state.position,
           proposed_position: proposed_state.position,
           sample_count: sample_count,
           queried_chunks: Map.keys(samples_by_chunk)
         })}
    end
  end

  defp config(opts) do
    %{
      enabled?: Keyword.get(opts, :enabled?, true),
      logical_scene_id: Keyword.get(opts, :logical_scene_id, 1),
      radius_cm: Keyword.get(opts, :radius_cm, @default_radius_cm) * 1.0,
      height_cm: Keyword.get(opts, :height_cm, @default_height_cm) * 1.0,
      half_height_cm: Keyword.get(opts, :height_cm, @default_height_cm) * 0.5,
      max_samples: Keyword.get(opts, :max_samples, @default_max_samples),
      query_fun: Keyword.get(opts, :query_fun, &default_collision_query/1)
    }
  end

  defp unavailable_summary(reason, %State{} = state) do
    %{
      enabled?: false,
      status: :unavailable,
      reason: inspect(reason),
      tick: state.tick,
      resolved_position: state.position,
      occupied_count: 0,
      blocked_axes: [],
      correction_flags: CorrectionFlags.none()
    }
  end

  defp default_collision_query(attrs) do
    ChunkDirectory.collision_query(attrs)
  end

  defp query_occupied_boxes(samples_by_chunk, config) do
    Enum.reduce_while(samples_by_chunk, {:ok, %{boxes: [], queried_chunks: []}}, fn {chunk,
                                                                                     samples},
                                                                                    {:ok, acc} ->
      attrs = %{
        logical_scene_id: config.logical_scene_id,
        chunk_coord: chunk,
        samples: samples
      }

      case safe_query(config.query_fun, attrs) do
        {:ok, result} ->
          boxes =
            result
            |> Map.get(:occupied, [])
            |> Enum.map(&occupied_sample_to_box(chunk, &1))

          {:cont,
           {:ok,
            %{
              boxes: acc.boxes ++ boxes,
              queried_chunks: [
                %{
                  chunk_coord: chunk,
                  sample_count: length(samples),
                  occupied_count: length(boxes),
                  chunk_version: Map.get(result, :chunk_version)
                }
                | acc.queried_chunks
              ]
            }}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, %{acc | queried_chunks: Enum.reverse(acc.queried_chunks)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_query(query_fun, attrs) do
    query_fun.(attrs)
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:query_exit, reason}}
  end

  defp resolve_against_boxes(previous_state, proposed_state, boxes, config) do
    previous_position = previous_state.position
    proposed_position = proposed_state.position

    {after_x, blocked_x?} =
      try_horizontal_axis(previous_position, proposed_position, 0, boxes, config)

    {after_y, blocked_y?} =
      try_horizontal_axis(after_x, proposed_position, 1, boxes, config)

    {resolved_position, z_status} =
      try_vertical_axis(
        after_y,
        previous_position,
        proposed_position,
        proposed_state,
        boxes,
        config
      )

    blocked_axes =
      []
      |> maybe_add_axis(:x, blocked_x?)
      |> maybe_add_axis(:y, blocked_y?)
      |> maybe_add_axis(:z, z_status in [:landed, :ceiling])

    resolved_state =
      proposed_state
      |> Map.put(:position, resolved_position)
      |> maybe_zero_axis(0, blocked_x?)
      |> maybe_zero_axis(1, blocked_y?)
      |> resolve_vertical_state(z_status, resolved_position)

    {resolved_state, Enum.reverse(blocked_axes)}
  end

  defp try_horizontal_axis(current_position, proposed_position, axis, boxes, config) do
    candidate = put_elem(current_position, axis, elem(proposed_position, axis))

    if collides?(candidate, boxes, config) do
      {current_position, true}
    else
      {candidate, false}
    end
  end

  defp try_vertical_axis(
         current_position,
         previous_position,
         proposed_position,
         proposed_state,
         boxes,
         config
       ) do
    candidate = put_elem(current_position, 2, elem(proposed_position, 2))

    if collides?(candidate, boxes, config) do
      previous_z = elem(previous_position, 2)
      proposed_z = elem(proposed_position, 2)
      {_vx, _vy, vz} = proposed_state.velocity

      if proposed_z <= previous_z or vz <= 0.0 do
        landing_z =
          landing_z(candidate, previous_z, proposed_z, boxes, config) || elem(current_position, 2)

        {put_elem(current_position, 2, landing_z), :landed}
      else
        {current_position, :ceiling}
      end
    else
      {candidate, :clear}
    end
  end

  defp maybe_zero_axis(%State{} = state, axis, true) do
    %{
      state
      | velocity: put_elem(state.velocity, axis, 0.0),
        acceleration: put_elem(state.acceleration, axis, 0.0)
    }
  end

  defp maybe_zero_axis(%State{} = state, _axis, false), do: state

  defp resolve_vertical_state(%State{} = state, :landed, {_x, _y, z}) do
    %{
      state
      | velocity: put_elem(state.velocity, 2, 0.0),
        acceleration: put_elem(state.acceleration, 2, 0.0),
        movement_mode: :grounded,
        ground_z: z
    }
  end

  defp resolve_vertical_state(%State{} = state, :ceiling, _position) do
    %{
      state
      | velocity: put_elem(state.velocity, 2, 0.0),
        acceleration: put_elem(state.acceleration, 2, 0.0),
        movement_mode: :airborne
    }
  end

  defp resolve_vertical_state(%State{} = state, _status, _position), do: state

  defp maybe_add_axis(axes, axis, true), do: [axis | axes]
  defp maybe_add_axis(axes, _axis, false), do: axes

  defp landing_z({x, y, _z}, previous_z, proposed_z, boxes, config) do
    min_z = min(previous_z, proposed_z) - @epsilon
    max_z = max(previous_z, proposed_z) + @epsilon
    footprint = horizontal_footprint(x, y, config)

    boxes
    |> Enum.filter(fn box ->
      horizontal_overlap?(footprint, box) and
        elem(box.max, 2) + config.half_height_cm >= min_z and
        elem(box.max, 2) + config.half_height_cm <= max_z
    end)
    |> Enum.map(fn box -> elem(box.max, 2) + config.half_height_cm end)
    |> Enum.max(&>=/2, fn -> nil end)
  end

  defp collides?(position, boxes, config) do
    avatar = movement_aabb_cm(position, config)
    Enum.any?(boxes, &aabb_overlap?(avatar, &1))
  end

  defp movement_aabb_cm({x, y, z}, config) do
    %{
      min: {x - config.radius_cm, y - config.radius_cm, z - config.half_height_cm},
      max: {x + config.radius_cm, y + config.radius_cm, z + config.half_height_cm}
    }
  end

  defp horizontal_footprint(x, y, config) do
    %{
      min: {x - config.radius_cm, y - config.radius_cm},
      max: {x + config.radius_cm, y + config.radius_cm}
    }
  end

  defp horizontal_overlap?(%{min: {min_x, min_y}, max: {max_x, max_y}}, %{
         min: {box_min_x, box_min_y, _box_min_z},
         max: {box_max_x, box_max_y, _box_max_z}
       }) do
    min_x < box_max_x and max_x > box_min_x and
      min_y < box_max_y and max_y > box_min_y
  end

  defp aabb_overlap?(%{min: {min_x, min_y, min_z}, max: {max_x, max_y, max_z}}, %{
         min: {box_min_x, box_min_y, box_min_z},
         max: {box_max_x, box_max_y, box_max_z}
       }) do
    min_x < box_max_x and max_x > box_min_x and
      min_y < box_max_y and max_y > box_min_y and
      min_z < box_max_z and max_z > box_min_z
  end

  defp union_aabb(%{min: min_a, max: max_a}, %{min: min_b, max: max_b}) do
    %{
      min: tuple_min(min_a, min_b),
      max: tuple_max(max_a, max_b)
    }
  end

  defp tuple_min({ax, ay, az}, {bx, by, bz}), do: {min(ax, bx), min(ay, by), min(az, bz)}
  defp tuple_max({ax, ay, az}, {bx, by, bz}), do: {max(ax, bx), max(ay, by), max(az, bz)}

  defp samples_by_chunk(%{min: {min_x, min_y, min_z}, max: {max_x, max_y, max_z}}) do
    for world_x <- int_range(min_x, max_x),
        world_y <- int_range(min_y, max_y),
        world_z <- int_range(min_z, max_z),
        reduce: %{} do
      acc ->
        sample = world_micro_sample(world_x, world_y, world_z)
        Map.update(acc, sample.chunk_coord, MapSet.new([sample.key]), &MapSet.put(&1, sample.key))
    end
    |> Map.new(fn {chunk_coord, sample_keys} ->
      samples =
        sample_keys
        |> Enum.map(fn {macro, micro_slot} -> %{macro: macro, micro_slot: micro_slot} end)
        |> Enum.sort_by(fn sample -> {sample.macro, sample.micro_slot} end)

      {chunk_coord, samples}
    end)
  end

  defp micro_aabb_volume(%{min: {min_x, min_y, min_z}, max: {max_x, max_y, max_z}}) do
    max(max_x - min_x, 0) * max(max_y - min_y, 0) * max(max_z - min_z, 0)
  end

  defp world_micro_sample(world_x, world_y, world_z) do
    world_macro = {
      Types.floor_div(world_x, @micro_per_macro),
      Types.floor_div(world_y, @micro_per_macro),
      Types.floor_div(world_z, @micro_per_macro)
    }

    {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)

    local_micro = {
      Types.floor_mod(world_x, @micro_per_macro),
      Types.floor_mod(world_y, @micro_per_macro),
      Types.floor_mod(world_z, @micro_per_macro)
    }

    %{chunk_coord: chunk_coord, key: {local_macro, Types.micro_index!(local_micro)}}
  end

  defp occupied_sample_to_box(chunk_coord, sample) do
    local_macro =
      case Map.get(sample, :macro) do
        nil -> Types.macro_coord!(Map.fetch!(sample, :macro_index))
        macro -> Types.normalize_local_macro_coord!(macro)
      end

    micro_slot = Map.fetch!(sample, :micro_slot)
    {micro_x, micro_y, micro_z} = Types.micro_coord!(micro_slot)
    {chunk_x, chunk_y, chunk_z} = chunk_coord
    {macro_x, macro_y, macro_z} = local_macro

    world_micro = {
      (chunk_x * Types.chunk_size_in_macro() + macro_x) * @micro_per_macro + micro_x,
      (chunk_y * Types.chunk_size_in_macro() + macro_y) * @micro_per_macro + micro_y,
      (chunk_z * Types.chunk_size_in_macro() + macro_z) * @micro_per_macro + micro_z
    }

    world_micro_to_movement_box(world_micro)
  end

  defp world_micro_to_movement_box({world_x, world_y, world_z}) do
    min = {
      world_x * @cm_per_micro,
      world_z * @cm_per_micro,
      world_y * @cm_per_micro
    }

    max = {
      (world_x + 1) * @cm_per_micro,
      (world_z + 1) * @cm_per_micro,
      (world_y + 1) * @cm_per_micro
    }

    %{min: min, max: max}
  end

  defp int_range(min, max) when min < max, do: min..(max - 1)
  defp int_range(_min, _max), do: []

  defp floor_cm_to_micro(value) do
    value
    |> to_float()
    |> Kernel.*(@micro_per_macro)
    |> Kernel./(@cm_per_macro)
    |> Float.floor()
    |> trunc()
  end

  defp ceil_cm_to_micro(value) do
    value
    |> to_float()
    |> Kernel.*(@micro_per_macro)
    |> Kernel./(@cm_per_macro)
    |> Float.ceil()
    |> trunc()
  end

  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(value) when is_float(value), do: value
end
