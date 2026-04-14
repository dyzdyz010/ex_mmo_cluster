defmodule SceneServer.Native.MovementEngine do
  @moduledoc """
  Rustler binding for authoritative movement math.

  This module is intentionally tiny: it exposes the NIF surface used by
  `SceneServer.Movement.Engine` and keeps Rust implementation details out of the
  higher-level actor modules.
  """

  use Rustler, otp_app: :scene_server, crate: "movement_engine"

  alias SceneServer.Movement.{InputFrame, Profile, State}

  @doc "Advances one authoritative movement step in native code."
  @spec step(State.t(), InputFrame.t(), Profile.t()) :: State.t()
  def step(_state, _input_frame, _profile), do: error()

  @doc "Replays input frames from an authoritative anchor in native code."
  @spec replay(State.t(), [InputFrame.t()], Profile.t()) :: [State.t()]
  def replay(_anchor_state, _input_frames, _profile), do: error()

  defp error, do: :erlang.nif_error(:nif_not_loaded)
end
