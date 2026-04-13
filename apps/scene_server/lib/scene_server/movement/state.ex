defmodule SceneServer.Movement.State do
  @enforce_keys [:position, :velocity, :acceleration, :movement_mode, :tick]
  defstruct [:position, :velocity, :acceleration, :movement_mode, :tick]

  @type vector :: {float(), float(), float()}
  @type t :: %__MODULE__{
          position: vector(),
          velocity: vector(),
          acceleration: vector(),
          movement_mode: atom(),
          tick: non_neg_integer()
        }

  def idle(position) do
    %__MODULE__{
      position: position,
      velocity: {0.0, 0.0, 0.0},
      acceleration: {0.0, 0.0, 0.0},
      movement_mode: :grounded,
      tick: 0
    }
  end
end
