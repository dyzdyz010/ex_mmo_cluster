defmodule SceneServer.Movement.Engine do
  alias SceneServer.Movement.{Ack, InputFrame, Profile, State}
  alias SceneServer.Native.MovementEngine, as: NativeMovementEngine

  @spec step(integer(), State.t(), InputFrame.t(), Profile.t()) :: {State.t(), Ack.t()}
  def step(cid, %State{} = state, %InputFrame{} = frame, %Profile{} = profile) do
    next_state = NativeMovementEngine.step(state, frame, profile)

    ack = %Ack{
      cid: cid,
      ack_seq: frame.seq,
      auth_tick: next_state.tick,
      position: next_state.position,
      velocity: next_state.velocity,
      acceleration: next_state.acceleration,
      movement_mode: next_state.movement_mode,
      correction_flags: 0
    }

    {next_state, ack}
  end

  @spec replay(State.t(), [InputFrame.t()], Profile.t()) :: [State.t()]
  def replay(%State{} = anchor_state, input_frames, %Profile{} = profile)
      when is_list(input_frames) do
    NativeMovementEngine.replay(anchor_state, input_frames, profile)
  end
end
