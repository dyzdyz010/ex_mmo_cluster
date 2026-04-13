defmodule SceneServer.Movement.Ack do
  @enforce_keys [
    :cid,
    :ack_seq,
    :auth_tick,
    :position,
    :velocity,
    :acceleration,
    :movement_mode,
    :correction_flags
  ]
  defstruct [
    :cid,
    :ack_seq,
    :auth_tick,
    :position,
    :velocity,
    :acceleration,
    :movement_mode,
    :correction_flags
  ]

  @type t :: %__MODULE__{
          cid: integer(),
          ack_seq: non_neg_integer(),
          auth_tick: non_neg_integer(),
          position: {float(), float(), float()},
          velocity: {float(), float(), float()},
          acceleration: {float(), float(), float()},
          movement_mode: atom(),
          correction_flags: non_neg_integer()
        }
end
