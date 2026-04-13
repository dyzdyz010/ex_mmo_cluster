defmodule SceneServer.Movement.Engine do
  alias SceneServer.Movement.{Ack, InputFrame, Integrator, Profile, State}

  @spec step(integer(), State.t(), InputFrame.t(), Profile.t()) :: {State.t(), Ack.t()}
  def step(cid, %State{} = state, %InputFrame{} = frame, %Profile{} = profile) do
    next_state = Integrator.step(state, frame, profile)

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
end
