defmodule SceneServer.Movement.Ack do
  @moduledoc """
  Authoritative movement acknowledgement sent back to the controlling client.

  The local client uses this struct to reconcile predicted movement against the
  server's fixed-tick truth.
  """

  @enforce_keys [
    :cid,
    :ack_seq,
    :auth_tick,
    :position,
    :velocity,
    :acceleration,
    :movement_mode,
    :correction_flags,
    :fixed_dt_ms,
    :ground_z
  ]
  defstruct [
    :cid,
    :ack_seq,
    :auth_tick,
    :server_state_ms,
    :position,
    :velocity,
    :acceleration,
    :movement_mode,
    :correction_flags,
    :fixed_dt_ms,
    :ground_z
  ]

  @type t :: %__MODULE__{
          cid: integer(),
          ack_seq: non_neg_integer(),
          auth_tick: non_neg_integer(),
          server_state_ms: non_neg_integer(),
          position: {float(), float(), float()},
          velocity: {float(), float(), float()},
          acceleration: {float(), float(), float()},
          movement_mode: atom(),
          correction_flags: non_neg_integer(),
          # Audit B-M2: server's authoritative fixed-tick interval (ms),
          # echoed so the client can detect MovementProfile.fixed_dt_ms
          # drift before it accumulates into prediction error.
          fixed_dt_ms: pos_integer(),
          # Phase A1-4: jump arc reconciliation needs the launch ground level
          # echoed back so the client predictor's stepAirborne can land at
          # the correct z. Without ground_z on the wire, client falls back to
          # ack.position.z, which during airborne ticks is the in-air position
          # and would cause "永不落地" prediction drift.
          ground_z: float()
        }
end
