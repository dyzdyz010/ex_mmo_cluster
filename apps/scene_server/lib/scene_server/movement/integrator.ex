defmodule SceneServer.Movement.Integrator do
  @moduledoc """
  参考实现，非运行时路径 / Reference-only Elixir movement integrator.

  The authoritative kinematics live in the shared Rust crate
  `apps/scene_server/native/movement_core/` and are exposed through the
  `movement_engine` NIF (`SceneServer.Native.MovementEngine`). This Elixir
  module is kept for:

    * readable documentation of the integrator contract;
    * cross-implementation parity tests (`test/.../integrator_golden_test.exs`).

  Nothing in the production hot path should call this module — use
  `SceneServer.Native.MovementEngine.step/3` / `replay/3` instead.
  """

  alias SceneServer.Movement.{InputFrame, Profile, State}

  @doc """
  Advances one movement step from a previous state and a sanitized input frame.
  """
  @spec step(State.t(), InputFrame.t(), Profile.t()) :: State.t()
  def step(%State{} = previous, %InputFrame{} = input, %Profile{} = profile) do
    mode = transition(previous.movement_mode, input)

    case mode do
      :grounded -> grounded_step(previous, input, profile, mode)
      :airborne -> airborne_step(previous, input, profile)
      :scripted -> scripted_step(previous, input, mode)
      :disabled -> disabled_step(previous, input, mode)
      _ -> grounded_step(previous, input, profile, :grounded)
    end
  end

  defp transition(:grounded, %InputFrame{} = input) do
    if InputFrame.jumping?(input), do: :airborne, else: :grounded
  end

  defp transition(previous_mode, _input), do: previous_mode

  defp grounded_step(%State{} = previous, %InputFrame{} = input, %Profile{} = profile, mode) do
    dt = max(input.dt_ms, 1) / 1000.0
    {dir_x, dir_y} = normalize_or_zero(input.input_dir)
    clamped_scale = clamp_speed_scale(input.speed_scale, profile.max_speed_scale)

    desired_velocity =
      {dir_x * profile.max_speed * clamped_scale, dir_y * profile.max_speed * clamped_scale, 0.0}

    velocity_error = sub_vec3(desired_velocity, previous.velocity)

    accel_limit =
      accel_limit(previous.velocity, desired_velocity, profile, InputFrame.braking?(input))

    braking? = InputFrame.braking?(input) or magnitude_sq(desired_velocity) <= 1.0e-6

    {velocity, acceleration} =
      if braking? do
        apply_braking(previous.velocity, profile.max_decel, dt)
      else
        accel_target = clamp_vec3(velocity_error |> div_vec3(dt), accel_limit)

        acceleration =
          smooth_acceleration(previous.acceleration, accel_target, profile.max_jerk, dt)

        velocity =
          clamp_vec3(add_vec3(previous.velocity, mul_vec3(acceleration, dt)), profile.max_speed)

        {velocity, acceleration}
      end

    position = add_vec3(previous.position, mul_vec3(velocity, dt))

    %State{
      tick: input.client_tick,
      position: position,
      velocity: velocity,
      acceleration: acceleration,
      movement_mode: mode,
      ground_z: elem(position, 2)
    }
  end

  defp airborne_step(%State{} = previous, %InputFrame{} = input, %Profile{} = profile) do
    dt = max(input.dt_ms, 1) / 1000.0
    {dir_x, dir_y} = normalize_or_zero(input.input_dir)
    clamped_scale = clamp_speed_scale(input.speed_scale, profile.max_speed_scale)

    desired_horizontal =
      {dir_x * profile.max_speed * clamped_scale, dir_y * profile.max_speed * clamped_scale, 0.0}

    current_horizontal = {elem(previous.velocity, 0), elem(previous.velocity, 1), 0.0}
    horizontal_error = sub_vec3(desired_horizontal, current_horizontal)
    air_accel_limit = profile.air_accel * (profile.air_control |> max(0.0) |> min(1.0))
    horizontal_delta = clamp_vec3(horizontal_error, air_accel_limit * dt)

    launch_tick = previous.movement_mode == :grounded and InputFrame.jumping?(input)
    ground_z = if launch_tick, do: elem(previous.position, 2), else: previous.ground_z
    start_vz = if launch_tick, do: profile.jump_impulse, else: elem(previous.velocity, 2)
    next_vz = max(start_vz - profile.gravity * dt, -profile.max_fall_speed)

    velocity = {
      elem(previous.velocity, 0) + elem(horizontal_delta, 0),
      elem(previous.velocity, 1) + elem(horizontal_delta, 1),
      next_vz
    }

    acceleration = {
      elem(horizontal_delta, 0) / dt,
      elem(horizontal_delta, 1) / dt,
      -profile.gravity
    }

    position = add_vec3(previous.position, mul_vec3(velocity, dt))

    {position, velocity, acceleration, movement_mode} =
      if elem(position, 2) <= ground_z and elem(velocity, 2) <= 0.0 do
        {
          put_elem(position, 2, ground_z),
          put_elem(velocity, 2, 0.0),
          put_elem(acceleration, 2, 0.0),
          :grounded
        }
      else
        {position, velocity, acceleration, :airborne}
      end

    %State{
      tick: input.client_tick,
      position: position,
      velocity: velocity,
      acceleration: acceleration,
      movement_mode: movement_mode,
      ground_z: ground_z
    }
  end

  defp scripted_step(%State{} = previous, %InputFrame{} = input, mode) do
    %State{
      tick: input.client_tick,
      position: previous.position,
      velocity: previous.velocity,
      acceleration: previous.acceleration,
      movement_mode: mode,
      ground_z: previous.ground_z
    }
  end

  defp disabled_step(%State{} = previous, %InputFrame{} = input, mode) do
    %State{
      tick: input.client_tick,
      position: previous.position,
      velocity: {0.0, 0.0, 0.0},
      acceleration: {0.0, 0.0, 0.0},
      movement_mode: mode,
      ground_z: previous.ground_z
    }
  end

  defp clamp_speed_scale(scale, max_scale) do
    scale |> max(0.0) |> min(max_scale)
  end

  defp accel_limit(current_velocity, desired_velocity, profile, braking?) do
    cond do
      braking? -> profile.max_decel
      magnitude_sq(desired_velocity) <= 1.0e-6 -> profile.max_decel
      magnitude(desired_velocity) < magnitude(current_velocity) -> profile.max_decel
      true -> profile.max_accel
    end
  end

  defp apply_braking(velocity, max_decel, dt) do
    speed_sq = magnitude_sq(velocity)

    if speed_sq <= 1.0e-12 do
      {{0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}}
    else
      speed = :math.sqrt(speed_sq)
      unit = div_vec3(velocity, speed)
      new_velocity = sub_vec3(velocity, mul_vec3(unit, max_decel * dt))
      dot = dot_vec3(new_velocity, velocity)

      if dot <= 0.0 or magnitude_sq(new_velocity) <= 9.0 do
        {{0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}}
      else
        {new_velocity, {0.0, 0.0, 0.0}}
      end
    end
  end

  defp smooth_acceleration(current, target, max_jerk, dt) do
    delta = sub_vec3(target, current)
    max_delta = max_jerk * dt

    if magnitude(delta) <= max_delta do
      target
    else
      add_vec3(current, mul_vec3(normalize_vec3(delta), max_delta))
    end
  end

  defp normalize_or_zero({x, y}) do
    magnitude = :math.sqrt(x * x + y * y)

    if magnitude <= 1.0e-6 do
      {0.0, 0.0}
    else
      {x / magnitude, y / magnitude}
    end
  end

  defp clamp_vec3(vector, max_length) do
    if magnitude(vector) <= max_length do
      vector
    else
      mul_vec3(normalize_vec3(vector), max_length)
    end
  end

  defp normalize_vec3(vector) do
    mag = magnitude(vector)
    if mag <= 1.0e-6, do: {0.0, 0.0, 0.0}, else: div_vec3(vector, mag)
  end

  defp magnitude_sq({x, y, z}), do: x * x + y * y + z * z
  defp magnitude(vector), do: :math.sqrt(magnitude_sq(vector))
  defp dot_vec3({ax, ay, az}, {bx, by, bz}), do: ax * bx + ay * by + az * bz
  defp add_vec3({ax, ay, az}, {bx, by, bz}), do: {ax + bx, ay + by, az + bz}
  defp sub_vec3({ax, ay, az}, {bx, by, bz}), do: {ax - bx, ay - by, az - bz}
  defp mul_vec3({x, y, z}, scalar), do: {x * scalar, y * scalar, z * scalar}
  defp div_vec3({x, y, z}, scalar), do: {x / scalar, y / scalar, z / scalar}
end
