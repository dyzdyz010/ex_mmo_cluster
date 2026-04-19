defmodule SceneServer.MovementSmokeTest do
  @moduledoc """
  End-to-end smoke for client-to-authoritative movement sync.

  Exercises the full in-process pipeline:

      test process (pretend TCP connection)
        └── GenServer.call(:movement_input, ...)
            └── PlayerCharacter GenServer
                  ├── input queue
                  ├── movement_tick timer (real wall-clock)
                  ├── NIF physics step
                  ├── AoiItem (real GenServer)
                  └── cast {:movement_ack, ...} back to us

  Validates:

  1. Steady 10Hz input → all seqs acked in monotonic auth_tick order.
  2. Burst (3 inputs at once) → one replay tick advances auth_tick by 3.
  3. Input gap up to 1s → server keeps moving with held direction
     (no 300ms-timeout rubber-band).
  4. Explicit stop → a final zero-velocity snapshot is broadcast.

  Tagged `:smoke` so it is skipped by default; run with:

      mix test --only smoke test/smoke/movement_smoke_test.exs
  """

  use ExUnit.Case, async: false

  @moduletag :smoke
  @moduletag timeout: 30_000

  alias SceneServer.AoiManager
  alias SceneServer.Movement.{InputFrame, Profile, RemoteSnapshot}

  setup_all do
    # Bring up only what the movement path needs. Works under either `mix test`
    # (full app already running) or `mix test --no-start` (nothing started).
    ensure_started(SceneServer.PhysicsManager, {SceneServer.PhysicsSup, name: PhysicsSupSmoke})
    ensure_started(SceneServer.AoiManager, {SceneServer.AoiSup, name: AoiSupSmoke})
    ensure_started(SceneServer.PlayerManager, {SceneServer.PlayerSup, name: PlayerSupSmoke})
    :ok
  end

  defp ensure_started(name_to_check, spec) do
    case Process.whereis(name_to_check) do
      nil ->
        case start_supervised(spec) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      pid ->
        pid
    end
  end

  setup do
    # Each test gets its own player/AOI entry; cleanup on exit.
    cid = System.unique_integer([:positive])

    profile = %{
      name: "smoke-#{cid}",
      position: {1000.0, 1000.0, 90.0}
    }

    {:ok, player_pid} =
      GenServer.call(
        SceneServer.PlayerManager,
        {:add_player, cid, self(), :os.system_time(:millisecond), profile}
      )

    on_exit(fn ->
      if Process.alive?(player_pid) do
        try do
          GenServer.call(player_pid, :exit, 2_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {:ok, cid: cid, player: player_pid, profile: Profile.default()}
  end

  # ------------------------------------------------------------------------
  # Scenario 1: steady 10Hz input stream
  # ------------------------------------------------------------------------

  test "steady 10Hz input progression produces monotonic acks", ctx do
    send_moves(ctx.player, east(), 1..10, inter_ms: 100)

    acks = collect_acks(10, 2_500)

    assert length(acks) == 10
    seqs = Enum.map(acks, & &1.ack_seq)
    auth_ticks = Enum.map(acks, & &1.auth_tick)

    assert seqs == Enum.sort(seqs), "ack seqs must arrive in monotonic order"
    assert auth_ticks == Enum.sort(auth_ticks), "auth_ticks must be monotonic"
    # Every submitted seq should eventually be covered by some ack.
    assert List.last(seqs) == 10
  end

  # ------------------------------------------------------------------------
  # Scenario 2: burst (3 inputs enqueued within one wall-clock tick)
  # ------------------------------------------------------------------------

  test "a 3-input burst is replayed in one tick, advancing auth_tick by 3", ctx do
    # Drain any pending idle acks first.
    _ = collect_acks_for_ms(300)

    # Capture baseline auth_tick.
    send_moves(ctx.player, east(), 1..1, inter_ms: 0)
    [baseline] = collect_acks(1, 1_500)
    base_tick = baseline.auth_tick

    # Now send 3 inputs back-to-back, all within the same 100ms window.
    send_moves(ctx.player, east(), 2..4, inter_ms: 0)

    # Next tick should carry a single ack with auth_tick = base_tick + 3.
    acks = collect_acks(1, 500)
    [after_burst] = acks

    assert after_burst.auth_tick == base_tick + 3,
           "burst should advance auth_tick by len(queue); got #{after_burst.auth_tick - base_tick}"

    assert after_burst.ack_seq == 4
  end

  # ------------------------------------------------------------------------
  # Scenario 3: input gap — server holds direction instead of decelerating
  # ------------------------------------------------------------------------

  test "a 700ms input gap during motion does not rubber-band to stop", ctx do
    # Warm up: reach steady velocity by sending 5 eastward inputs.
    send_moves(ctx.player, east(), 1..5, inter_ms: 100)
    warm_acks = collect_acks(5, 2_000)
    moving_ack = List.last(warm_acks)
    {vx0, _vy0, _vz0} = moving_ack.velocity

    assert vx0 > 100.0,
           "expected meaningful eastward velocity after warm-up, got #{vx0}"

    # Now stop sending inputs for 700ms (well past the old 300ms timeout, under
    # our new 2000ms hold window).
    Process.sleep(700)

    # Drain any ticks that fired during the gap and take the last one.
    gap_acks = collect_acks_for_ms(50)
    last_during_gap = List.last(gap_acks) || moving_ack

    {vx_gap, _vy_gap, _vz_gap} = last_during_gap.velocity

    # With the old bug we would have decelerated heavily (max_decel=1400, so
    # within 400ms past the 300ms timeout we should have bled >500u/s worth of
    # speed). With the fix the server keeps applying the held direction, so
    # velocity should remain close to the moving_ack value (within a small
    # floating-point tolerance driven purely by sim stability).
    assert vx_gap >= vx0 * 0.9,
           "server decelerated during brief gap: vx went #{vx0} -> #{vx_gap}"
  end

  # ------------------------------------------------------------------------
  # Scenario 4: explicit stop produces a final zero-velocity snapshot
  # ------------------------------------------------------------------------

  test "explicit stop input yields a zero-velocity snapshot to AOI", ctx do
    # The player's AoiItem was created during setup; its subscriber list is
    # refreshed on a 1000ms timer, so we grab its pid and kick it manually to
    # avoid a race with the scenario timing.
    player_state = :sys.get_state(ctx.player)
    player_aoi = Map.fetch!(player_state, :aoi_ref)

    observer_cid = System.unique_integer([:positive])

    {:ok, observer_aoi} =
      AoiManager.add_aoi_item(
        observer_cid,
        :os.system_time(:millisecond),
        {1005.0, 1000.0, 90.0},
        self(),
        self(),
        %{kind: :player, name: "observer-#{observer_cid}"}
      )

    on_exit(fn ->
      if Process.alive?(observer_aoi) do
        try do
          GenServer.call(observer_aoi, :exit, 2_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    # Force both sides to refresh so player AoiItem sees observer as a
    # subscriber (that's who `:player_move` casts are fanned out to).
    send(player_aoi, :get_aoi_tick)
    send(observer_aoi, :get_aoi_tick)
    :timer.sleep(150)

    # Move east briefly, then send an explicit stop.
    send_moves(ctx.player, east(), 1..5, inter_ms: 100)
    _ = collect_acks(5, 2_000)

    send_stop(ctx.player, 6)

    # Wait for the queue to drain + deceleration + final flush.
    Process.sleep(800)

    snapshots = collect_snapshots_for_ms(100)

    assert snapshots != [],
           "observer received no player_move snapshots; AOI subscription likely did not wire up"

    # There must be at least one zero-velocity snapshot after the stop input.
    zero_snaps =
      Enum.filter(snapshots, fn
        %RemoteSnapshot{velocity: {0.0, 0.0, 0.0}} -> true
        _ -> false
      end)

    assert zero_snaps != [],
           "no zero-velocity stop snapshot was broadcast; final snapshot was #{inspect(List.last(snapshots))}"
  end

  # ------------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------------

  defp east, do: {1.0, 0.0}

  defp send_moves(pid, {dx, dy}, seq_range, opts) do
    inter_ms = Keyword.fetch!(opts, :inter_ms)

    Enum.each(seq_range, fn seq ->
      frame = %InputFrame{
        seq: seq,
        client_tick: seq,
        dt_ms: 100,
        input_dir: {dx * 1.0, dy * 1.0},
        speed_scale: 1.0,
        movement_flags: 0
      }

      {:ok, :accepted} = call_input(pid, frame)
      if inter_ms > 0, do: Process.sleep(inter_ms)
    end)
  end

  defp send_stop(pid, seq) do
    frame = %InputFrame{
      seq: seq,
      client_tick: seq,
      dt_ms: 100,
      input_dir: {0.0, 0.0},
      speed_scale: 1.0,
      movement_flags: 0b10
    }

    call_input(pid, frame)
  end

  defp call_input(pid, frame) do
    GenServer.call(pid, {:movement_input, frame}, 2_000)
  end

  defp collect_acks(count, overall_timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + overall_timeout_ms
    collect_acks_loop(count, deadline, [])
  end

  defp collect_acks_loop(0, _deadline, acc), do: Enum.reverse(acc)

  defp collect_acks_loop(n, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      if acc == [],
        do:
          flunk(
            "timed out waiting for ack; needed #{n} more, mailbox: #{inspect(drain_mailbox_peek())}"
          )

      Enum.reverse(acc)
    else
      receive do
        {:"$gen_cast", {:movement_ack, ack}} ->
          collect_acks_loop(n - 1, deadline, [ack | acc])
      after
        remaining -> collect_acks_loop(0, deadline, acc)
      end
    end
  end

  defp collect_acks_for_ms(window_ms) do
    deadline = System.monotonic_time(:millisecond) + window_ms
    collect_until_deadline(deadline, [], :ack)
  end

  defp collect_snapshots_for_ms(window_ms) do
    deadline = System.monotonic_time(:millisecond) + window_ms
    collect_until_deadline(deadline, [], :snapshot)
  end

  defp collect_until_deadline(deadline, acc, kind) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      receive do
        {:"$gen_cast", {:movement_ack, ack}} when kind == :ack ->
          collect_until_deadline(deadline, [ack | acc], kind)

        {:"$gen_cast", {:player_move, %RemoteSnapshot{} = snap}} when kind == :snapshot ->
          collect_until_deadline(deadline, [snap | acc], kind)

        _other ->
          collect_until_deadline(deadline, acc, kind)
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end

  defp drain_mailbox_peek do
    {:messages, messages} = Process.info(self(), :messages)
    Enum.take(messages, 5)
  end
end
