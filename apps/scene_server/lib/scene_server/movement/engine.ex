defmodule SceneServer.Movement.Engine do
  alias SceneServer.Movement.{Ack, InputFrame, Profile, State}
  alias SceneServer.Native.MovementEngine, as: NativeMovementEngine

  @spec step(integer(), State.t(), InputFrame.t(), Profile.t()) :: {State.t(), Ack.t()}
  def step(cid, %State{} = state, %InputFrame{} = frame, %Profile{} = profile) do
    next_state = NativeMovementEngine.step(state, frame, profile)
    ack = build_ack(cid, next_state, frame.seq)

    {next_state, ack}
  end

  @spec build_ack(integer(), State.t(), non_neg_integer()) :: Ack.t()
  def build_ack(cid, %State{} = state, ack_seq) do
    %Ack{
      cid: cid,
      ack_seq: ack_seq,
      auth_tick: state.tick,
      position: state.position,
      velocity: state.velocity,
      acceleration: state.acceleration,
      movement_mode: state.movement_mode,
      correction_flags: 0
    }
  end

  @spec replay(State.t(), [InputFrame.t()], Profile.t()) :: [State.t()]
  def replay(%State{} = anchor_state, input_frames, %Profile{} = profile)
      when is_list(input_frames) do
    NativeMovementEngine.replay(anchor_state, input_frames, profile)
  end
end
