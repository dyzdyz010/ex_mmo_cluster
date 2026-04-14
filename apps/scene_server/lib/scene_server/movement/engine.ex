defmodule SceneServer.Movement.Engine do
  @moduledoc """
  Thin authoritative facade around the movement integrator implementation.

  `SceneServer.PlayerCharacter` and `SceneServer.Npc.Actor` both step movement
  through this module so they share the same fixed-tick rules and ack shape.
  The current hot path delegates to Rustler (`SceneServer.Native.MovementEngine`)
  while preserving a small Elixir API surface.
  """

  alias SceneServer.Movement.{Ack, InputFrame, Profile, State}
  alias SceneServer.Native.MovementEngine, as: NativeMovementEngine

  @doc """
  Advances one authoritative movement tick and builds the matching ack.
  """
  @spec step(integer(), State.t(), InputFrame.t(), Profile.t()) :: {State.t(), Ack.t()}
  def step(cid, %State{} = state, %InputFrame{} = frame, %Profile{} = profile) do
    next_state = NativeMovementEngine.step(state, frame, profile)
    ack = build_ack(cid, next_state, frame.seq)

    {next_state, ack}
  end

  @doc """
  Builds a movement ack from an already-authoritative state snapshot.
  """
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

  @doc """
  Replays a list of input frames from an authoritative anchor state.
  """
  @spec replay(State.t(), [InputFrame.t()], Profile.t()) :: [State.t()]
  def replay(%State{} = anchor_state, input_frames, %Profile{} = profile)
      when is_list(input_frames) do
    NativeMovementEngine.replay(anchor_state, input_frames, profile)
  end
end
