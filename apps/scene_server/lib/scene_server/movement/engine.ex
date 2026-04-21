defmodule SceneServer.Movement.Engine do
  @moduledoc """
  Thin authoritative facade around the movement integrator implementation.

  `SceneServer.PlayerCharacter` and `SceneServer.Npc.Actor` both step movement
  through this module so they share the same fixed-tick rules and ack shape.
  The current hot path delegates to Rustler (`SceneServer.Native.MovementEngine`)
  while preserving a small Elixir API surface.
  """

  alias SceneServer.Movement.{Ack, CorrectionFlags, InputFrame, Profile, State}
  alias SceneServer.Native.MovementEngine, as: NativeMovementEngine

  @doc """
  Advances one authoritative movement tick and builds the matching ack.

  `flags` is an optional `CorrectionFlags` bitfield to OR into the ack
  (teleport, status override, anti-cheat). Collision-push detection is
  derived from the step outcome itself in `build_ack_with_intent/4`.
  """
  @spec step(integer(), State.t(), InputFrame.t(), Profile.t(), CorrectionFlags.t()) ::
          {State.t(), Ack.t()}
  def step(cid, %State{} = state, %InputFrame{} = frame, %Profile{} = profile, flags \\ 0) do
    next_state = NativeMovementEngine.step(state, frame, profile)
    ack = build_ack_with_intent(cid, next_state, frame, flags)

    {next_state, ack}
  end

  @doc """
  Builds a movement ack from an already-authoritative state snapshot.

  Emits `correction_flags: 0` — prefer `build_ack_with_intent/4` when you
  have the input frame that produced the state so collision push can be
  auto-detected.
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
  Builds an ack, OR-ing the explicit `flags` with any auto-detected
  collision-push signal from the step outcome.
  """
  @spec build_ack_with_intent(
          integer(),
          State.t(),
          InputFrame.t(),
          CorrectionFlags.t()
        ) :: Ack.t()
  def build_ack_with_intent(cid, %State{} = state, %InputFrame{} = frame, flags)
      when is_integer(flags) and flags >= 0 do
    auto_flags = detect_collision_push(frame, state)

    %Ack{
      cid: cid,
      ack_seq: frame.seq,
      auth_tick: state.tick,
      position: state.position,
      velocity: state.velocity,
      acceleration: state.acceleration,
      movement_mode: state.movement_mode,
      correction_flags: CorrectionFlags.combine([flags, auto_flags])
    }
  end

  # Collision-push heuristic:
  #   - player asked for motion (non-zero input_dir),
  #   - but the resulting horizontal velocity opposes the ask
  #     (dot-product ≤ 0 once we normalise).
  # This catches being pressed into a wall, knocked back, or held in place.
  defp detect_collision_push(%InputFrame{input_dir: {ix, iy}} = _frame, %State{
         velocity: {vx, vy, _vz}
       }) do
    input_len_sq = ix * ix + iy * iy

    cond do
      input_len_sq < 1.0e-6 ->
        CorrectionFlags.none()

      vx * ix + vy * iy <= 0.0 and vx * vx + vy * vy < 1.0 ->
        CorrectionFlags.collision_push()

      true ->
        CorrectionFlags.none()
    end
  end

  defp detect_collision_push(_frame, _state), do: CorrectionFlags.none()

  @doc """
  Replays a list of input frames from an authoritative anchor state.
  """
  @spec replay(State.t(), [InputFrame.t()], Profile.t()) :: [State.t()]
  def replay(%State{} = anchor_state, input_frames, %Profile{} = profile)
      when is_list(input_frames) do
    NativeMovementEngine.replay(anchor_state, input_frames, profile)
  end
end
