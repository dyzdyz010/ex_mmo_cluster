defmodule SceneServer.Movement.Profile do
  @enforce_keys [
    :max_speed,
    :max_accel,
    :max_decel,
    :max_jerk,
    :friction,
    :turn_response,
    :fixed_dt_ms,
    :max_speed_scale
  ]
  defstruct [
    :max_speed,
    :max_accel,
    :max_decel,
    :max_jerk,
    :friction,
    :turn_response,
    :fixed_dt_ms,
    :max_speed_scale
  ]

  @type t :: %__MODULE__{
          max_speed: float(),
          max_accel: float(),
          max_decel: float(),
          max_jerk: float(),
          friction: float(),
          turn_response: float(),
          fixed_dt_ms: pos_integer(),
          max_speed_scale: float()
        }

  def default do
    # TODO(vnext-stage3): keep this profile contract explicitly aligned with
    # the client predictor and Rustler movement_engine structs. If tuning starts
    # changing often, add a parity/version check so client/server behavior
    # cannot silently drift.
    %__MODULE__{
      max_speed: 220.0,
      max_accel: 1200.0,
      max_decel: 1400.0,
      max_jerk: 9000.0,
      friction: 0.0,
      turn_response: 1.0,
      fixed_dt_ms: 100,
      max_speed_scale: 1.0
    }
  end
end
