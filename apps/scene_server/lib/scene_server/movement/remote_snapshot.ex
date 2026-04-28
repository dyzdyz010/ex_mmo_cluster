defmodule SceneServer.Movement.RemoteSnapshot do
  @moduledoc """
  Compact AOI broadcast snapshot for remote actor motion.

  Unlike `Movement.Ack`, this snapshot is intended for *other* clients and AOI
  subscribers. It captures the latest authoritative movement state in a form
  that clients can interpolate.
  """

  alias SceneServer.Movement.State

  @enforce_keys [:cid, :server_tick, :position, :velocity, :acceleration, :movement_mode]
  defstruct [
    :cid,
    :server_tick,
    :position,
    :velocity,
    :acceleration,
    :movement_mode,
    :priority_band,
    :priority_score,
    :observer_distance,
    :delivery_interval
  ]

  @type vector :: {float(), float(), float()}
  @type t :: %__MODULE__{
          cid: integer(),
          server_tick: non_neg_integer(),
          position: vector(),
          velocity: vector(),
          acceleration: vector(),
          movement_mode: atom(),
          priority_band: atom() | nil,
          priority_score: float() | nil,
          observer_distance: float() | nil,
          delivery_interval: pos_integer() | nil
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

  @doc """
  Returns a per-observer snapshot annotated with AOI priority metadata.

  The authoritative actor snapshot remains observer-neutral. `AoiItem` calls
  this while fanning out so each observer can receive a different priority band
  and delivery cadence without changing the owned movement state.
  """
  @spec with_priority(t(), map()) :: t()
  def with_priority(%__MODULE__{} = snapshot, %{} = priority) do
    %__MODULE__{
      snapshot
      | priority_band: Map.get(priority, :priority_band),
        priority_score: Map.get(priority, :priority_score),
        observer_distance: Map.get(priority, :observer_distance),
        delivery_interval: Map.get(priority, :delivery_interval)
    }
  end
end
