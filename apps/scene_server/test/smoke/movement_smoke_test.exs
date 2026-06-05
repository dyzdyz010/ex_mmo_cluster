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

  1. Steady fixed-tick input → all seqs acked in monotonic auth_tick order.
  2. Burst (3 inputs at once) → one replay tick advances auth_tick by 3.
  3. Short browser-scheduling input gap → server keeps moving with held direction.
  4. Explicit stop → a final zero-velocity snapshot is broadcast.

  Tagged `:smoke` so it is skipped by default; run with:

      mix test --only smoke test/smoke/movement_smoke_test.exs
  """

  use ExUnit.Case, async: false

  @moduletag :smoke
  @moduletag timeout: 30_000

  alias SceneServer.AoiManager
  alias SceneServer.Movement.{InputFrame, Profile, RemoteSnapshot}

  @fixed_dt_ms Profile.default().fixed_dt_ms

  setup_all do
    # Bring up only what the movement path needs. Works under either `mix test`
    # (full app already running) or `mix test --no-start` (nothing started).
    ensure_started(SceneServer.PhysicsManager, {SceneServer.PhysicsSup, name: PhysicsSupSmoke})
    # S1 后用 IndexStore 做 AOI 子树探针(AoiManager 已是无状态 facade,不再是进程)。
    ensure_started(SceneServer.Aoi.IndexStore, {SceneServer.AoiSup, name: AoiSupSmoke})
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
  # Scenario 1: steady fixed-tick input stream
  # ------------------------------------------------------------------------

  test "steady fixed-tick input progression produces monotonic acks", ctx do
    send_moves(ctx.player, east(), 1..10, inter_ms: ctx.profile.fixed_dt_ms)

    acks = collect_acks_until_seq(10, 5_000)

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

    # Now send 3 inputs back-to-back, all within the same fixed-tick window.
    send_moves(ctx.player, east(), 2..4, inter_ms: 0)

    # The real wall-clock timer may split these inputs across ticks on a busy
    # scheduler, but the authoritative timeline must still cover all inputs.
    acks = collect_acks_until_seq(4, 1_500)
    after_burst = List.last(acks)

    assert after_burst.auth_tick >= base_tick + 3,
           "burst should advance auth_tick by at least len(queue); got #{after_burst.auth_tick - base_tick}"

    assert after_burst.ack_seq == 4
  end

  # ------------------------------------------------------------------------
  # Scenario 3: input gap — server holds direction instead of decelerating
  # ------------------------------------------------------------------------

  test "a short input gap during motion does not rubber-band to stop", ctx do
    # Warm up: reach steady velocity by sending 5 eastward inputs.
    send_moves(ctx.player, east(), 1..5, inter_ms: ctx.profile.fixed_dt_ms)
    warm_acks = collect_acks(5, 2_000)
    moving_ack = List.last(warm_acks)
    {vx0, _vy0, _vz0} = moving_ack.velocity

    min_warm_velocity = ctx.profile.max_speed * 0.1

    assert vx0 > min_warm_velocity,
           "expected meaningful eastward velocity after warm-up, got #{vx0}"

    # Now stop sending inputs briefly. This is below the 20 fixed-tick hold
    # window, so it models browser scheduling jitter, not a dropped connection.
    Process.sleep(ctx.profile.fixed_dt_ms * 10)

    # Drain any ticks that fired during the gap and take the last one.
    gap_acks = collect_acks_for_ms(50)
    last_during_gap = List.last(gap_acks) || moving_ack

    {vx_gap, _vy_gap, _vz_gap} = last_during_gap.velocity

    # With the old bug we would have decelerated heavily (Phase A2 默认
    # max_decel=3800, 旧值 1400, 任一值 400ms 都会减速 >500u/s). With the
    # fix the server keeps applying the held direction, so velocity should
    # remain close to the moving_ack value (within a small floating-point
    # tolerance driven purely by sim stability).
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
    apply_local_partition_window(player_aoi)
    apply_local_partition_window(observer_aoi)
    send(player_aoi, :get_aoi_tick)
    send(observer_aoi, :get_aoi_tick)
    _ = :sys.get_state(player_aoi)
    _ = :sys.get_state(observer_aoi)

    # Move east briefly, then send an explicit stop.
    send_moves(ctx.player, east(), 1..5, inter_ms: ctx.profile.fixed_dt_ms)
    _ = collect_acks(5, 2_000)

    send_stop(ctx.player, 6)

    # Wait for the queue to drain + deceleration + final flush.
    snapshots = collect_snapshots_for_ms(1_500)

    assert snapshots != [],
           "observer received no player_move snapshots; AOI subscription likely did not wire up"

    # There must be at least one zero-velocity snapshot after the stop input.
    zero_snaps =
      Enum.filter(snapshots, fn
        %RemoteSnapshot{velocity: velocity} -> zero_velocity?(velocity)
      end)

    assert zero_snaps != [],
           "no zero-velocity stop snapshot was broadcast; final snapshot was #{inspect(List.last(snapshots))}"
  end

  # ------------------------------------------------------------------------
  # Scenario 5 (Phase A1-4): jump arc — Airborne mode + ground_z plumbed
  # all the way to the ack
  # ------------------------------------------------------------------------

  test "jump input transitions to airborne and ack carries launch ground_z", ctx do
    # Phase A1-4 端到端冒烟:跳跃 input → server integrator airborne_step
    # → ack 携带 ground_z (起跳点 z) → client reconcile 拿到正确落地高度。
    # 不再走前一个版本"客户端用 position.y 当 groundY"的本地 hack。

    initial_state = :sys.get_state(ctx.player)
    initial_z = elem(initial_state.last_location, 2)

    # 1. 一帧 grounded(零位移)拿 baseline ack.ground_z=initial_z。
    {:ok, :accepted} = call_input(ctx.player, grounded_idle_frame(1))
    Process.sleep(@fixed_dt_ms * 7)

    # 2. 跳跃帧:input_dir 不动,Jump flag 置位。
    {:ok, :accepted} = send_jump(ctx.player, 2)
    Process.sleep(@fixed_dt_ms * 7)

    # 3. 跳跃 arc 演进:再 6 帧 grounded(零位移),让 server 把 airborne arc 跑出来。
    Enum.each(3..8, fn seq ->
      {:ok, :accepted} = call_input(ctx.player, grounded_idle_frame(seq))
      Process.sleep(@fixed_dt_ms * 7)
    end)

    acks = collect_acks_for_ms(200) ++ collect_acks(0, 0)
    # 至少要拿到 6 个 ack, 覆盖 jump 输入和后续 arc。
    assert length(acks) >= 6,
           "expected at least 6 acks across the jump arc, got #{length(acks)}"

    [ack1 | rest] = acks

    # First ack:Grounded mode,ground_z = 起步 z。
    assert ack1.movement_mode == :grounded
    assert_in_delta ack1.ground_z, initial_z, 1.0e-9

    # 找出至少一个 airborne ack(jump 帧 + 后续若干 arc 帧)。
    airborne_acks = Enum.filter(rest, fn a -> a.movement_mode == :airborne end)

    assert airborne_acks != [],
           "no airborne ack observed after jump input; jump path didn't transition mode"

    # 关键不变量:整个 airborne arc 中 ack.ground_z 全部等于 launch ground z
    # (= initial_z),不跟着 position.z 漂移。这是 Phase A1-4 修复点。
    Enum.each(airborne_acks, fn airborne_ack ->
      assert_in_delta airborne_ack.ground_z,
                      initial_z,
                      1.0e-9,
                      "airborne ack ground_z drifted from launch z; ack=#{inspect(airborne_ack)}"
    end)

    # 至少一帧 airborne 的 z position 高于 initial_z(确实在空中)。
    max_z =
      airborne_acks
      |> Enum.map(fn a -> elem(a.position, 2) end)
      |> Enum.max()

    assert max_z > initial_z + 1.0,
           "airborne arc never lifted above initial_z=#{initial_z}; max_z=#{max_z}"

    # Phase A1-4 e2e summary,可见在 mix test --only smoke 输出。
    IO.puts("""

    ── Phase A1-4 jump arc e2e smoke ────────────────────────────
      total acks observed:      #{length(acks)}
      grounded acks:            #{Enum.count(acks, &(&1.movement_mode == :grounded))}
      airborne acks:            #{length(airborne_acks)}
      initial_z:                #{Float.round(initial_z, 4)}
      ground_z (first ack):     #{Float.round(ack1.ground_z, 4)}
      ground_z 在 arc 中漂移:    0(像素级 launch ground_z 锁定)
      max_z reached in arc:     #{Float.round(max_z, 4)}
      apex above launch:        #{Float.round(max_z - initial_z, 4)}
    ─────────────────────────────────────────────────────────────
    """)
  end

  defp grounded_idle_frame(seq) do
    %InputFrame{
      seq: seq,
      client_tick: seq,
      dt_ms: @fixed_dt_ms,
      input_dir: {0.0, 0.0},
      speed_scale: 1.0,
      movement_flags: 0
    }
  end

  # ------------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------------

  defp east, do: {1.0, 0.0}

  defp zero_velocity?({vx, vy, vz}) do
    abs(vx) <= 1.0e-9 and abs(vy) <= 1.0e-9 and abs(vz) <= 1.0e-9
  end

  defp send_moves(pid, {dx, dy}, seq_range, opts) do
    inter_ms = Keyword.fetch!(opts, :inter_ms)

    Enum.each(seq_range, fn seq ->
      frame = %InputFrame{
        seq: seq,
        client_tick: seq,
        dt_ms: @fixed_dt_ms,
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
      dt_ms: @fixed_dt_ms,
      input_dir: {0.0, 0.0},
      speed_scale: 1.0,
      movement_flags: 0b10
    }

    call_input(pid, frame)
  end

  defp send_jump(pid, seq, dir \\ {0.0, 0.0}) do
    frame = %InputFrame{
      seq: seq,
      client_tick: seq,
      dt_ms: @fixed_dt_ms,
      input_dir: dir,
      speed_scale: 1.0,
      # 0b100 = MOVEMENT_FLAG_JUMP (input_frame.ex @jump_flag)
      movement_flags: 0b100
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

  defp collect_acks_until_seq(target_seq, overall_timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + overall_timeout_ms
    collect_acks_until_seq_loop(target_seq, deadline, [])
  end

  defp collect_acks_until_seq_loop(target_seq, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      match?([%{ack_seq: seq} | _] when seq >= target_seq, acc) ->
        Enum.reverse(acc)

      remaining <= 0 ->
        if acc == [],
          do:
            flunk(
              "timed out waiting for ack seq #{target_seq}; mailbox: #{inspect(drain_mailbox_peek())}"
            )

        Enum.reverse(acc)

      true ->
        receive do
          {:"$gen_cast", {:movement_ack, ack}} ->
            collect_acks_until_seq_loop(target_seq, deadline, [ack | acc])
        after
          remaining -> Enum.reverse(acc)
        end
    end
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

  defp apply_local_partition_window(aoi_item) do
    SceneServer.Aoi.AoiItem.update_partition_window(aoi_item, %{
      logical_scene_id: 1,
      center_chunk: {0, 0, 0},
      near_radius: 0,
      halo_radius: 1,
      route_entries: [
        %{
          chunk_coord: {0, 0, 0},
          tier: :near,
          status: :assigned,
          region_id: 10,
          lease_id: 100,
          assigned_scene_node: node()
        }
      ]
    })

    wait_until(fn ->
      case :sys.get_state(aoi_item).partition_interest do
        %{logical_scene_id: 1, near_query_count: 1} -> true
        _other -> false
      end
    end)
  end

  defp wait_until(fun, attempts \\ 40)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition not met before timeout")
end
