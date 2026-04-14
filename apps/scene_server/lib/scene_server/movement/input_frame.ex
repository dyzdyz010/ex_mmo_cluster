defmodule SceneServer.Movement.InputFrame do
  @moduledoc """
  One fixed-step movement control sample.

  The client sends input intent, not authority over final position. The server
  sanitizes and latches these frames, then consumes them on its own fixed tick.
  """

  @enforce_keys [:seq, :client_tick, :dt_ms, :input_dir, :speed_scale, :movement_flags]
  defstruct [:seq, :client_tick, :dt_ms, :input_dir, :speed_scale, :movement_flags]

  @type t :: %__MODULE__{
          seq: non_neg_integer(),
          client_tick: non_neg_integer(),
          dt_ms: non_neg_integer(),
          input_dir: {float(), float()},
          speed_scale: float(),
          movement_flags: non_neg_integer()
        }

  @run_flag 0b0000_0001
  @brake_flag 0b0000_0010

  @doc "Returns whether the input requests the run modifier."
  def running?(%__MODULE__{movement_flags: flags}), do: Bitwise.band(flags, @run_flag) != 0

  @doc "Returns whether the input requests braking / zero-input deceleration."
  def braking?(%__MODULE__{movement_flags: flags}), do: Bitwise.band(flags, @brake_flag) != 0
end
