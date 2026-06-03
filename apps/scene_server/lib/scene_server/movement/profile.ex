defmodule SceneServer.Movement.Profile do
  @moduledoc """
  Shared movement tuning profile for authoritative simulation and prediction.

  This profile is intentionally shared conceptually across:

  - scene-side authoritative stepping
  - client-side prediction
  - Rustler movement math
  - NPC navigation input generation

  Changes here should be mirrored carefully on the client predictor side.
  """

  @enforce_keys [
    :max_speed,
    :max_accel,
    :max_decel,
    :max_jerk,
    :friction,
    :turn_response,
    :fixed_dt_ms,
    :max_speed_scale,
    :jump_impulse,
    :gravity,
    :air_control,
    :air_accel,
    :max_fall_speed
  ]
  defstruct [
    :max_speed,
    :max_accel,
    :max_decel,
    :max_jerk,
    :friction,
    :turn_response,
    :fixed_dt_ms,
    :max_speed_scale,
    :jump_impulse,
    :gravity,
    :air_control,
    :air_accel,
    :max_fall_speed
  ]

  @type t :: %__MODULE__{
          max_speed: float(),
          max_accel: float(),
          max_decel: float(),
          max_jerk: float(),
          friction: float(),
          turn_response: float(),
          fixed_dt_ms: pos_integer(),
          max_speed_scale: float(),
          jump_impulse: float(),
          gravity: float(),
          air_control: float(),
          air_accel: float(),
          max_fall_speed: float()
        }

  @doc """
  Returns the current default movement profile used by player and NPC actors.
  """
  def default do
    # TODO(vnext-stage3): keep this profile contract explicitly aligned with
    # the client predictor and Rustler movement_engine structs. If tuning starts
    # changing often, add a parity/version check so client/server behavior
    # cannot silently drift.
    %__MODULE__{
      max_speed: 600.0,
      max_accel: 3300.0,
      max_decel: 3800.0,
      max_jerk: 24_500.0,
      friction: 0.0,
      turn_response: 1.0,
      fixed_dt_ms: 16,
      max_speed_scale: 1.0,
      jump_impulse: 900.0,
      gravity: 980.0,
      air_control: 0.35,
      air_accel: 1140.0,
      max_fall_speed: 5300.0
    }
  end
end
