defmodule VoxelRegion.World.Projectiles do
  @moduledoc "全局系统功能：World 独占的短段飞行、当前人物采样与持久热交付。异步工作只查人物和交付不可变收据，不持有世界真值。"
  alias VoxelRegion.Magic.Semblance
  alias VoxelRegion.World.{Casting, HeatCommit, Thermal}
  require Logger

  @doc "有实时拟态时只排一个 50ms 节拍；没有对象即休眠。"
  def wake(state) do
    if state.projectile_timer == nil and state.projectile_task == nil and shots(state) != [] do
      %{state | projectile_timer: Process.send_after(self(), :projectile_tick, 50)}
    else
      state
    end
  end

  defp shots(state), do: Enum.filter(Thermal.semblances(state), fn {_, s} -> Map.has_key?(s, :projectile_source) end)

  @doc "同一轮只有一个异步工作；下一轮在本轮提交以后采样，不缓存人物位置。"
  def poll(%{projectile_task: nil} = state) do
    case shots(state) do
      [] -> state
      shots ->
        backend = state.projectile_backend
        cv = state.cv
        %{state | projectile_task: Task.async(fn -> backend.poll(shots, cv) end)}
    end
  end
  def poll(state), do: state

  @doc "只接纳仍存活且年龄匹配的采样；施法后驱散的旧工作不能复活对象。"
  def accept(state, results) do
    Enum.reduce(results, state, fn {id, age, result}, state ->
      case Map.get(Thermal.semblances(state), id) do
        %{age_s: ^age} = s -> apply_result(state, id, s, result)
        _ -> state
      end
    end) |> wake()
  end

  defp apply_result(state, _id, %{impact_delivery: _}, {:delivered, {:retry, :target_unavailable}}), do: state

  defp apply_result(state, id, %{impact_delivery: hit} = s, {:delivered, result}) do
    accepted = match?({:ok, _}, result)
    thermal = Thermal.release(state.thermal, id, s, nil)
    thermal = Thermal.ledger(thermal, if(accepted, do: :projectile_body_j, else: :projectile_rejected_j), hit.q_j)
    thermal = if accepted, do: Thermal.ledger(thermal, :body_exchange_j, hit.q_j), else: thermal
    next = %{state | thermal: thermal}
      |> HeatCommit.thermal_commit([], %{semblances: %{id => Map.put(s, :live, 2)}})
    Logger.info("voxel_projectile_hit projectile=#{inspect(id)} world_seq=#{next.seq} target=#{hit.target.id} target_life=#{hit.target.life_generation} q_j=#{hit.q_j} result=#{inspect(result)}")
    if accepted, do: state.projectile_backend.notify(hit, next.seq)
    next
  end

  defp apply_result(state, id, s, {:sample, age, actor, target, sampled_us}) do
    {terrain, state} = Enum.reduce_while(Semblance.flight_segments(s, age), {nil, state}, fn {t0, t1, a, b}, {_, state} ->
      case Semblance.segment(a, b, s.radius_m, state, &Casting.semblance_cast/4) do
        {nil, state} -> {:cont, {nil, state}}
        {{fraction, point, node}, state} ->
          t = (t0 + (t1 - t0) * fraction - s.age_s) / (age - s.age_s)
          {:halt, {{t, point, node}, state}}
      end
    end)
    terrain_fraction = if terrain, do: elem(terrain, 0), else: 1.0
    target = if target && elem(target, 0) < terrain_fraction, do: target
    fraction = cond do target -> elem(target, 0); terrain -> terrain_fraction; true -> 1.0 end
    dt = (age - s.age_s) * fraction
    {s, thermal} = cool(s, state.thermal, dt)
    state = %{state | thermal: thermal}

    cond do
      Semblance.expired?(s) ->
        state = %{state | thermal: Thermal.release(state.thermal, id, s, nil)}
        HeatCommit.thermal_commit(state, [], %{semblances: %{id => nil}})
      target ->
        {_, target} = target
        point = Semblance.position(s.origin, s.velocity, s.age_s)
        s = %{s | age_s: s.age_s, flight_s: s.age_s, rest: point, contact: nil}
        hit = %{key: {state.cv, elem(id, 0), elem(id, 1)}, actor: actor,
          target: Map.take(target, [:id, :identity, :life_generation, :position, :velocity]),
          q_j: Semblance.stored_j(s, state.thermal.config["ambient_kelvin"]), position: point,
          sampled_us: sampled_us}
        s = Map.put(s, :impact_delivery, hit)
        Logger.info("voxel_projectile_contact projectile=#{inspect(id)} sampled_us=#{sampled_us} age_s=#{s.age_s} target=#{target.id} target_life=#{target.life_generation} target_position=#{inspect(target.position)} target_velocity=#{inspect(target.velocity)} q_j=#{hit.q_j}")
        next = put_in(state.thermal.semblances[id], s)
        # 先持久冻结交付对象；重启后仍重投同一目标，不再次求交。
        HeatCommit.thermal_commit(next, [], %{semblances: %{id => s}})
      terrain ->
        s = if terrain do
          {_, rest, target} = terrain
          node = if target.granularity == 2, do: %{target | granularity: 1}, else: target
          %{s | flight_s: s.age_s, rest: rest, contact: %{target: target,
            key: VoxelRegion.ThermalGeometry.key(node), cell: VoxelRegion.Damage.macro(target)}}
        else
          s
        end
        {cell, state} = Thermal.release_cell(state, s)
        state = %{state | thermal: Thermal.release(state.thermal, id, s, cell)}
        HeatCommit.thermal_commit(state, [], %{semblances: %{id => Map.put(s, :live, 2)}})
      true ->
        state = put_in(state.thermal.semblances[id], s)
        HeatCommit.thermal_commit(state, [], %{semblances: %{id => s}})
    end
  end

  @doc "复用原热 NIF，只推进实际飞行短段；飞行换热、光预算与世界热流程不重复。"
  def cool(s, thermal, dt) when dt <= 0.0, do: {s, thermal}
  def cool(s, thermal, dt) do
    config = thermal.config
    emissivity = if VoxelRegion.ThermalRadiation.enabled?(config), do: config["emissivity"], else: 0.0
    {_, open} = Semblance.radiation(s, emissivity, 0.0)
    {done, [{temperature, _, _}], _, environment} = VoxelRegion.ThermalNative.advance(
      [Semblance.node(s, 0.0, 0.0)], [], config["ambient_kelvin"] * 1.0,
      config["environment_w_per_m2_k"] * 1.0, config["tolerance_kelvin"] * 1.0, dt, {[], [{0, open}]})
    {s, light, exchanged} = Semblance.step(s, temperature, done)
    thermal = thermal |> Thermal.ledger(:semblance_light_j, light)
      |> Thermal.ledger(:semblance_exchanged_j, exchanged) |> Thermal.ledger(:environment_j, environment)
    {s, thermal}
  end

end
