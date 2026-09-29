defmodule SceneServer.Movement.FrostMovementTest do
  @moduledoc """
  分类：Test-only。Player 纯回调边界测试，可直接构造身体与时间线输入，不向在线 authority 注入状态。
  使用真实 Repair、InputSlots、CollisionUpdates 与 Native；Native 包装只记录实际步进参数，Sink 只记录下行。
  不覆盖真实 World 产伤或网络客户端。手算：基础速度 8，深冻伤 0.65 → 5.2，修复 25% → 6.6。
  """
  use ExUnit.Case, async: true

  alias SceneServer.Body
  alias SceneServer.Movement.{Player, CollisionUpdates, InputSlots}
  alias SceneServer.Native.VoximMovement, as: Physics
  alias MmoContracts.{Movement, Session, Voxel}

  defmodule Clock do
    def now(_), do: 200_000
  end

  defmodule Sink do
    def reliable(pid, identity, purpose, event), do: send(pid, {:reliable, identity, purpose, event})
    def datagram(pid, identity, event), do: send(pid, {:datagram, identity, event})
  end

  defmodule Native do
    defdelegate new_world(), to: Physics
    defdelegate set_chunks(world, operations), to: Physics
    defdelegate query_bounds(profile, state), to: Physics
    defdelegate constrain_travel(previous, next, travel), to: Physics

    def step_characters(world, profile, inputs) do
      send(self(), {:stepped, profile, inputs})
      Physics.step_characters(world, profile, inputs)
    end
  end

  defp identity, do: %Session.Identity{session_epoch: 1, scene_id: 1, scene_epoch: 1}

  defp opts do
    cells = for _z <- 0..15, y <- 0..15, _x <- 0..15, into: <<>>, do: <<if(y == 0, do: 1, else: 0)>>
    chunk = %Voxel.ChunkOccupancy{coord: {0, 0, 0}, n: 16, scale_m: 1.0, origin_m: {0.0, 0.0, 0.0}, cells: cells}
    snapshot = %Voxel.CanonicalSnapshot{content_version: 1, transaction_seq: 0, l0_min: {0, 0, 0},
      l0_max_exclusive: {1, 1, 1}, chunks: [chunk], regions: []}
    updates = CollisionUpdates.new(Native) |> CollisionUpdates.initialize(snapshot)
    domain = {{-100.0, -100.0, -100.0}, {100.0, 100.0, 100.0}}
    config = %{streaming_radius: 0, bounds: domain, travel: domain, authority: domain, neighbours: [],
      profile: %{half_height: 0.9, radius: 0.35},
      profile_tuple: {0.35, 0.9, 8.0, 20.48, 20.0, 15.0, 8.0, 2.0, 0.35, 9.8, 7.0, 1.0, 0.2, 0.01, 0.7812980937412168}}

    [id: 20, epoch: 1, kind: 1, identity: identity(), scene: self(), gate: self(), replication: self(),
      scene_id: 1, scene_epoch: 1, sink: Sink, clock: {Clock, nil}, time_origin: 0, time_mono_origin: 0,
      mono_origin: 0, updates: updates, config: config, content_version: 1, probe: {3.0, 4.0, 3.0}]
  end

  defp player do
    {:ok, state} = Player.init(opts())
    %{state | state: %Session.State{position: {3.0, 1.91, 3.0}, velocity: {8.0, 0.0, 0.0}, grounded: 1, yaw: 0},
      origin: 1, tick: 10, simulation_tick: 8, simulation_revision: 1, baseline: {0, 1}, ready: true,
      clock_ready: true, slots: %{InputSlots.new(identity(), 1) | processed_input_seq: 8},
      climate: %{"ambient_kelvin" => 293.15, "climate_zones" => []},
      body: %{Body.new() | frost_dose_k_s: 600.0, protein_g: 0.0}}
  end

  defp body_tick(state) do
    {:noreply, next} = Player.handle_info(:body_tick, state)
    next
  end

  defp input(state, seqs) do
    frames = for seq <- seqs, do: %Movement.InputFrame{input_seq: seq, axis_x: 32767, axis_z: 0, yaw: 0, jump_pressed: 0}
    # 受控入口：该批真实输入在首槽截止前一个 tick 到达；后续先入队再发布对应时间线。
    arrived = div((Enum.min(seqs) - 1) * 1_000_000, 60)
    {:noreply, next} = Player.handle_cast({:input, state.identity, %Movement.InputBatch{identity: state.identity, frames: frames}, arrived}, state)
    next
  end

  test "新身体倍率在已发布 tick + 1 生效，积压步仍使用历史速度且只修改 speed" do
    state = body_tick(player())
    assert_receive {:reliable, _, :voxel, %Movement.SpeedScale{apply_tick: 11, factor: 0.65}}
    state = input(state, [9, 10])
    for _ <- 1..2 do
      assert_receive {:stepped, profile, [{20, _, {1.0, +0.0, 0}}]}
      assert profile == state.config.profile_tuple
    end

    state = input(state, [11, 12])
    {:noreply, state} = Player.handle_info({:timeline, 12, 0, 1, [], []}, state)
    for _ <- 1..2 do
      assert_receive {:stepped, profile, [{20, _, {1.0, +0.0, 0}}]}
      assert profile == put_elem(state.config.profile_tuple, 2, 5.2)
    end
    assert state.simulation_tick == 12
    assert state.movement_scales == [{11, 0.65, 1.0}]

    state = input(state, 13..30)
    {:noreply, state} = Player.handle_info({:timeline, 30, 0, 1, [], []}, state)
    assert_in_delta elem(state.state.velocity, 0), 5.2, 1.0e-9
    {:reply, observed, _} = Player.handle_call(:observe, nil, state)
    assert observed.movement_factor == 0.65
    assert observed.movement_apply_tick == 11
    assert_in_delta observed.movement_speed, 5.2, 1.0e-12

    state = body_tick(%{state | body: %{state.body | frost_heal: 0.5}})
    assert_receive {:reliable, _, :voxel, %Movement.SpeedScale{apply_tick: 31, factor: 1.0}}
    state = input(state, 31..50)
    {:noreply, state} = Player.handle_info({:timeline, 50, 0, 1, [], []}, state)
    assert_in_delta elem(state.state.velocity, 0), 8.0, 1.0e-9
    assert state.movement_scales == [{31, 1.0, 1.0}]
  end

  test "倍率不变不重复发，同 tick 后到变化覆盖，修复恢复全速" do
    state = body_tick(player())
    assert_receive {:reliable, _, :voxel, %Movement.SpeedScale{apply_tick: 11, factor: 0.65}}
    state = body_tick(state)
    refute_receive {:reliable, _, :voxel, %Movement.SpeedScale{}}, 0
    state = body_tick(%{state | body: %{state.body | frost_heal: 0.25}})
    assert_receive {:reliable, _, :voxel, %Movement.SpeedScale{apply_tick: 11, factor: factor}}
    assert_in_delta factor, 0.825, 1.0e-12
    assert state.movement_scales == [{11, factor, 1.0}, {0, 1.0, 1.0}]
    state = body_tick(%{state | tick: 12, body: %{state.body | frost_heal: 0.5}})
    assert_receive {:reliable, _, :voxel, %Movement.SpeedScale{apply_tick: 13, factor: 1.0}}
    assert state.movement_scales == [{13, 1.0, 1.0}, {11, factor, 1.0}, {0, 1.0, 1.0}]
  end

  test "复活身体在未来 tick 发布恢复全速" do
    state = body_tick(player())
    assert_receive {:reliable, _, :voxel, %Movement.SpeedScale{factor: 0.65}}
    state = body_tick(%{state | tick: 11, body: %{state.body | status: :dead}})
    assert_receive {:reliable, _, :voxel, %Movement.SpeedScale{apply_tick: 12, factor: 1.0}}
    assert state.body.weak_s == 119.0
    assert state.body.daze_s == 39.0
  end

  test "移交封存与导入保留未消费的倍率；prepared 身体计时不提前推进或发送" do
    source = body_tick(player())
    assert_receive {:reliable, _, :voxel, %Movement.SpeedScale{apply_tick: 11, factor: 0.65}}
    {:reply, {:ok, cut}, sealed} = Player.handle_call({:seal, source.identity}, nil, %{source | transfer: :requested})
    assert cut.movement_scales == [{11, 0.65, 1.0}, {0, 1.0, 1.0}]
    assert {:noreply, ^sealed} = Player.handle_info(:body_tick, sealed)

    {:ok, target} = Player.init(Keyword.merge(opts(), import: cut, tail: [], tick: 10))
    assert target.movement_scales == cut.movement_scales
    assert {:noreply, ^target} = Player.handle_info(:body_tick, target)
    refute_receive {:reliable, _, :voxel, %Movement.SpeedScale{}}, 0
    {:reply, :ok, active} = Player.handle_call({:activate, target.identity}, nil, target)
    assert active.movement_scales == cut.movement_scales
    active = input(active, [9, 10])
    {:noreply, active} = Player.handle_info({:timeline, 11, 0, 1, [], []}, active)
    active = input(active, [11])
    assert active.movement_scales == [{11, 0.65, 1.0}]
  end
  test "真实 Native 固定步同时消费冻伤和前摇限制，原始跑跳输入不能越过约束" do
    state = player() |> body_tick() |> input([9, 10]) |> Map.put(:authority_ref, self())
    for _ <- 1..2, do: assert_receive({:stepped, _, _})
    request = %{action: 1, client_intent_seq: 1, request_id: 1, direction: {1.0, 0.0, 0.0}}
    {:noreply, state} = Player.handle_call({:spell, state.identity, request, %{}}, {self(), make_ref()}, state)
    frames = for n <- 11..40, do: %Movement.InputFrame{input_seq: n, axis_x: 32767, axis_z: 0, yaw: 0, jump_pressed: 1}
    {:noreply, state} = Player.handle_cast({:input, state.identity, %Movement.InputBatch{identity: state.identity, frames: frames}, 166_666}, state)
    {:noreply, state} = Player.handle_info({:timeline, 40, 0, 1, [], []}, state)
    for _ <- 11..40 do
      assert_receive {:stepped, profile, [{20, _, {x, z, jump}}]}
      assert {x, z, jump} == {0.35, 0.0, 0}
      assert elem(profile, 2) == 5.2
    end
    assert_in_delta elem(state.state.velocity, 0), 1.82, 1.0e-9
    assert state.state.grounded == 1
    assert_in_delta elem(state.state.position, 1), 1.91, 0.02
  end

end
