defmodule SceneServer.Movement.State do
  @moduledoc """
  Authoritative movement state for one actor at one fixed tick.

  This struct is the simulation truth used by both player and NPC actors. AOI
  snapshots and movement acknowledgements are derived from it rather than
  inventing separate transport-only state.
  """

  @enforce_keys [:position, :velocity, :acceleration, :movement_mode, :tick]
  defstruct [
    :position,
    :velocity,
    :acceleration,
    :movement_mode,
    :tick,
    ground_z: 0.0,
    server_state_ms: 0
  ]

  @type vector :: {float(), float(), float()}
  @type t :: %__MODULE__{
          position: vector(),
          velocity: vector(),
          acceleration: vector(),
          movement_mode: atom(),
          ground_z: float(),
          tick: non_neg_integer(),
          server_state_ms: non_neg_integer()
        }

  @doc """
  Builds a stationary grounded movement state at the provided position.
  """
  def idle(position) do
    %__MODULE__{
      position: position,
      velocity: {0.0, 0.0, 0.0},
      acceleration: {0.0, 0.0, 0.0},
      movement_mode: :grounded,
      ground_z: elem(position, 2),
      tick: 0,
      server_state_ms: 0
    }
  end
end
