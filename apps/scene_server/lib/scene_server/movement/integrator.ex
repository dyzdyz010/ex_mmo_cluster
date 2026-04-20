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
    dt = max(input.dt_ms, 1) / 1000.0
    {dir_x, dir_y} = normalize_or_zero(input.input_dir)
    clamped_scale = clamp_speed_scale(input.speed_scale, profile.max_speed_scale)

    desired_velocity =
      {dir_x * profile.max_speed * clamped_scale, dir_y * profile.max_speed * clamped_scale, 0.0}

    velocity_error = sub_vec3(desired_velocity, previous.velocity)

    accel_limit =
      accel_limit(previous.velocity, desired_velocity, profile, InputFrame.braking?(input))

    accel_target = clamp_vec3(velocity_error |> div_vec3(dt), accel_limit)
    acceleration = smooth_acceleration(previous.acceleration, accel_target, profile.max_jerk, dt)

    velocity =
      clamp_vec3(add_vec3(previous.velocity, mul_vec3(acceleration, dt)), profile.max_speed)

    position = add_vec3(previous.position, mul_vec3(velocity, dt))

    %State{
      tick: input.client_tick,
      position: position,
      velocity: velocity,
      acceleration: acceleration,
      movement_mode: :grounded
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
  defp add_vec3({ax, ay, az}, {bx, by, bz}), do: {ax + bx, ay + by, az + bz}
  defp sub_vec3({ax, ay, az}, {bx, by, bz}), do: {ax - bx, ay - by, az - bz}
  defp mul_vec3({x, y, z}, scalar), do: {x * scalar, y * scalar, z * scalar}
  defp div_vec3({x, y, z}, scalar), do: {x / scalar, y / scalar, z / scalar}
end
