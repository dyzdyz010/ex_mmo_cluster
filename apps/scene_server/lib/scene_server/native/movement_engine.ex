defmodule SceneServer.Native.MovementEngine do
  use Rustler, otp_app: :scene_server, crate: "movement_engine"

  alias SceneServer.Movement.{InputFrame, Profile, State}

  @spec step(State.t(), InputFrame.t(), Profile.t()) :: State.t()
  def step(_state, _input_frame, _profile), do: error()

  @spec replay(State.t(), [InputFrame.t()], Profile.t()) :: [State.t()]
  def replay(_anchor_state, _input_frames, _profile), do: error()

  defp error, do: :erlang.nif_error(:nif_not_loaded)
end
