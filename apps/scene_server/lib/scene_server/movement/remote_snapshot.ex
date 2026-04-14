defmodule SceneServer.Movement.RemoteSnapshot do
  @moduledoc """
  Compact AOI broadcast snapshot for remote actor motion.

  Unlike `Movement.Ack`, this snapshot is intended for *other* clients and AOI
  subscribers. It captures the latest authoritative movement state in a form
  that clients can interpolate.
  """

  alias SceneServer.Movement.State

  @enforce_keys [:cid, :server_tick, :position, :velocity, :acceleration, :movement_mode]
  defstruct [:cid, :server_tick, :position, :velocity, :acceleration, :movement_mode]

  @type vector :: {float(), float(), float()}
  @type t :: %__MODULE__{
          cid: integer(),
          server_tick: non_neg_integer(),
          position: vector(),
          velocity: vector(),
          acceleration: vector(),
          movement_mode: atom()
        }

  @doc """
  Projects an authoritative movement state into a remote AOI snapshot.
  """
  @spec from_state(integer(), State.t()) :: t()
  def from_state(cid, %State{} = state) do
    %__MODULE__{
      cid: cid,
      server_tick: state.tick,
      position: state.position,
      velocity: state.velocity,
      acceleration: state.acceleration,
      movement_mode: state.movement_mode
    }
  end
end
