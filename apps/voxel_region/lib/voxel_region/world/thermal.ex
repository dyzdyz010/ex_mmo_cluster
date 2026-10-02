defmodule VoxelRegion.World.Thermal do
  @moduledoc """
  全局系统功能：World 的热模拟编排——定时热提交、内核步、电路段、拟态与身体节点、辐射视线与受保护区域边界。

  温度、HP、燃料等真值仍是 World 的稀疏属性记录；本模块在 World 状态上推进模拟，只经
  `VoxelRegion.World.Canonical` 读取 canonical 占用，派生工作集在 `VoxelRegion.ThermalWork`。
  一次提交完成时把待提交的记录交回 World，由 World 写日志、下发与处理几何后果。
  """
  alias VoxelRegion.{Attachments, Combustion, Damage, Magic, Phase, Prefab, Protection, ThermalDomain, ThermalRecord,
    ThermalWork}
  import VoxelRegion.World.Canonical
  require Logger

  @micro VoxelRegion.Spatial.micro_resolution()
  # 施法留热、走火与取能损耗以有限热源落地，在一个 500 ms 热提交内放完（热源机制要求有限功率）。
  @deposit_seconds 0.5

  @doc """
  排下一次定时热提交：固定 500 ms 墙钟节拍，下一次到期 = 上次到期 + 500 ms，回调耗时不拉长周期；
  落后时立即开始、不积压补跑。任何时刻至多一个待到期节拍（新排程取消旧的）。
  """
  def schedule(state) do
    if state.thermal_timer, do: Process.cancel_timer(state.thermal_timer)
    now = System.monotonic_time(:millisecond)
    due = max((state.thermal_due || now) + 500, now)
    %{state | thermal_due: due, thermal_timer: Process.send_after(self(), :thermal_tick, due - now)}
  end

  @doc """
  事件唤醒（R8-05）：没有待到期节拍、也没有进行中的提交时排一拍；无热环境时不变。身体接触报告与
  `touch/2`（每笔事务，含热提交自己的事务）调用它；是否真的推进由下一拍的 `begin/1` 判定。
  """
  def wake(%{thermal: nil} = state), do: state
  def wake(%{thermal_timer: nil, thermal_run: nil} = state), do: schedule(state)
  def wake(state), do: state

  @doc """
  一笔事务改写了这些属性记录（`VoxelRegion.World.Log.remember_entry/2`）：记下行键供提交末增量重判热行，并唤醒。
  """
  def touch(%{thermal: nil} = state, _rows), do: state

  def touch(state, rows), do: wake(%{state | thermal_work: ThermalWork.touched(state.thermal_work, rows, state.properties)})

  @doc "节拍已到（World 处理 `:thermal_tick` 时调用）：不再有待到期节拍。"
  def fired(state), do: %{state | thermal_timer: nil}

  @doc "休眠：这一拍没有需要推进的状态，不再排下一拍，直到 `wake/1`。"
  def rest(state), do: %{state | thermal_due: nil}

  @doc "占用编辑只让受影响宏格的派生热几何与视线失效；无热环境时工作集恒为空。"
  def drop_geometry(%{thermal: nil} = state, _cells), do: state

  def drop_geometry(state, cells),
    do: %{state | thermal_work:
      ThermalWork.drop(state.thermal_work, cells, state.thermal.config["view_range_cells"])}

  @doc """
  按当前属性记录重建派生热工作集，并据此置热活动标志。工作集不写日志；缓存只含身份、材质与暴露面，
  数值批次读取当前权威记录。也是气候变化的通知点（`VoxelRegion.Climate` 契约 2）：偏离新环境的记录格即热种子，
  冷启动时资产气候区与存档时不同也走这里。
  """
  def rebuild_work(%{thermal: nil} = state),
    do: %{state | thermal_work: ThermalWork.new()}

  def rebuild_work(state) do
    rows = ThermalWork.hot_rows(state.damage, state.thermal.config)
    hot = ThermalWork.footprints(rows)

    active = state.thermal.active or MapSet.size(hot) > 0 or
      Enum.any?(state.damage, fn {_, t} -> Combustion.exhausted?(t) end)
    electric = ThermalWork.electric(Map.keys(state.damage), state.damage, state.properties)
    %{state | thermal: %{state.thermal | active: active},
      thermal_work: %{ThermalWork.new() | hot: hot, hot_rows: rows, electric: electric}}
  end

  @doc """
  开始一次 0.5 模拟秒的定时提交：先移除 2.5 s 未更新的身体接触；无热活动、拟态、身体接触，且电路要么没有种子、
  要么自上次零功率提交以来没有新事务（`thermal_quiet_seq`）时不开提交（`thermal_run` 仍为 nil）。
  电路种子（有储能的蓄能石、带温度记录的热电石）本身不推进：零功率网络的解只随事务（开关、编辑、温度写回）变化。
  """
  def begin(state) do
    now = System.monotonic_time(:millisecond)
    state = %{state | bodies: Map.filter(state.bodies, fn {_, b} -> now - b.at <= 2_500 end)}

    if state.thermal.active or semblances(state) != %{} or state.bodies != %{} or
         (state.thermal_quiet_seq != state.seq and circuit_seeds(state, []) != []) do
      run = %{ref: make_ref(), damage: state.damage, semblances: semblances(state), visited: MapSet.new(),
        remaining: 0.5, segment: nil, seq: state.seq, busy_us: 0, steps: 0,
        started: System.monotonic_time(:microsecond), powered: false, disturbed: false}
      # 燃烧行在提交之间可被工具、放置等事务改写（已由 touch 并入）或删除：首轮按当前记录过滤。
      work = state.thermal_work
      %{state | thermal_run: run, thermal_work: %{work | builds: 0, burning: ThermalWork.live_burning(work.burning, state.damage)}}
    else
      # 不推进时也把此后改写的行并入热行判定，改写键集合不随休眠期的事务增长。
      work = state.thermal_work
      %{state | thermal_work: %{work | hot_rows: ThermalWork.rehot(work.hot_rows, work.touched, state.damage,
        state.thermal.config), touched: MapSet.new()}}
    end
  end

  @doc """
  推进进行中的提交：纯热段一个内核步，电路段一整段。未完成时 `{:more, state}`；0.5 模拟秒走完时
  `{:done, state, commit}`，`commit` 是本次提交的属性记录、归零记录、相变数量与拟态变化，由 World 写成一笔事务；
  `commit.quiet` 表示本次提交的电路全程零功率、步间没有其他事务且没有改写任何记录。
  """
  def tick(state) do
    started = System.monotonic_time(:microsecond)
    run = state.thermal_run
    # 步间已有其他事务提交：燃烧行可能被改写，本步重新扫描；本次提交不能据段首的电路解判定零功率。
    {state, run} = if state.seq != run.seq,
      do: {%{state | thermal_work: %{state.thermal_work |
        burning: ThermalWork.live_burning(state.thermal_work.burning, state.damage)}}, %{run | disturbed: true}},
      else: {state, run}
    {state, run} = advance_run(state, run)
    run = %{run | seq: state.seq, steps: run.steps + 1,
      busy_us: run.busy_us + System.monotonic_time(:microsecond) - started}

    if run.remaining < 1.0e-12 do
      {state, commit} = settle_run(%{state | thermal_run: nil}, run)
      {:done, state, commit}
    else
      {:more, %{state | thermal_run: run}}
    end
  end

  # 纯热段每条消息只推进一个内核步；电路段按段起点求解的功率整段连续执行。
  defp advance_run(state, %{segment: nil} = run) do
    case circuit_seeds(state, run.visited) do
      [] ->
        advance_run(state, %{run | segment: run.remaining})

      _seeds ->
        # 电路求解读取记录里的温度与储能：先写回原生热域；段末的发光与电源观察行由这里直接写记录。
        {state, visited, duration, powered} = circuit_segment(flush(state), run.remaining, run.visited)
        {seen(state), %{run | visited: visited, remaining: run.remaining - duration, powered: run.powered or powered}}
    end
  end

  defp advance_run(state, %{segment: left} = run) do
    {state, changed, done} = thermal_step(state, left, %{})
    run = %{run | visited: MapSet.union(run.visited, changed), segment: left - done}

    if left - done < 1.0e-12 do
      # 无电路时本段用完整次提交的剩余时间。
      candidates = electric_candidates(state, run.visited)
      {damage, visited} = electric_rows(state.damage, run.visited, %{}, candidates)
      {damage, visited} = source_rows(state, damage, visited, %{}, candidates)
      {seen(%{state | damage: damage}), %{run | visited: visited, segment: nil, remaining: 0.0}}
    else
      {state, run}
    end
  end

  # 提交末尾：按当前真值收缩热域、燃尽行归零，挑出与提交开始时不同的记录。
  defp settle_run(state, run) do
    stepped = System.monotonic_time(:microsecond)
    state = flush(state)
    visited = run.visited
    # 同一提交内只扩张热域，避免容差边缘反复删添接触；批末按当前真值收缩。只重判上次的热行、本次提交改写的行
    # 与其他事务改写过的行（R8-05），其余记录自上次判定以来未变。
    hot_rows = ThermalWork.rehot(state.thermal_work.hot_rows, MapSet.union(state.thermal_work.touched, visited),
      state.damage, state.thermal.config)
    hot = ThermalWork.footprints(hot_rows)
    state = %{state | thermal_work: %{state.thermal_work | hot: hot, hot_rows: hot_rows, touched: MapSet.new()},
      thermal: %{state.thermal | active: map_size(state.thermal.sources) > 0 or MapSet.size(hot) > 0}}
    # 耗尽、相变与转化只重判上次结算后改写过的行（事务改写 + 本次提交改写，R8-05）：其余行与上次判定时相同，
    # 上次已耗尽的行已归零（重判不改变什么），上次的相变已由相变事务换掉材料；尚未派生（nil）时全量。
    pending = state.thermal_work.pending
    damage = state.damage
    exhausted = for key <- ThermalWork.settle_keys(pending, visited, damage),
      {:ok, row} <- [Map.fetch(damage, key)], Combustion.exhausted?(row), do: row
    # 燃料耗尽表示材料被消耗，不保留可重新采掘的整块木材。
    # 微格／附件沿已有最低层整件完整度语义归零，其余未燃料量记入移除账。
    {state, visited} = Enum.reduce(exhausted, {state, visited}, fn row, {s, keys} ->
      if Combustion.exhausted?(row) do
        granularity = case row.granularity do
          1 -> 2
          4 -> 3
          g -> g
        end
        target = property_state(s, %{row | granularity: granularity}
          |> Map.take([:micro, :granularity, :incarnation, :owner, :material]))
        key = Damage.key(target)
        {%{s | damage: Map.put(s.damage, key, %{target | hp: 0.0})}, MapSet.put(keys, key)}
      else
        {s, keys}
      end
    end)
    work = state.thermal_work
    scanned = System.monotonic_time(:microsecond)

    Logger.info(
      "voxel_thermal_sim steps_us=#{run.busy_us} scan_us=#{scanned - stepped} damage_rows=#{map_size(state.damage)} simulated_s=0.5 max_step_ms=50 elapsed_us=#{run.busy_us + System.monotonic_time(:microsecond) - stepped} wall_us=#{System.monotonic_time(:microsecond) - run.started} kernel_steps=#{run.steps} hot=#{MapSet.size(work.hot)} candidates=#{map_size(work.geometry)} geometry_builds=#{work.builds}"
    )

    # 步间编辑可能已删除记录；已被编辑改写的记录按当前值随本事务再发一次。
    rows =
      for key <- visited,
          {:ok, t} <- [Map.fetch(state.damage, key)],
          Map.get(run.damage, key) != t,
          do: %{t | seq: state.seq + 1, request_id: 0}

    settled = ThermalWork.settle_keys(pending, visited, state.damage)
    phase_changes = for key <- settled, {:ok, t} <- [Map.fetch(state.damage, key)], phase_target?(state,t),
      q=Map.get(state.liquid_units,Damage.macro(t),liquid_capacity(state)),
      e=Phase.energy(t,q/liquid_capacity(state),state.properties.materials[t.material],ambient_at(state,Damage.macro(t))),
      Phase.material(t.material,e,q/liquid_capacity(state),state.properties.materials)!=t.material,
      into: %{}, do: {Damage.macro(t),q}

    # 电路候选按当前记录收缩（并入本次改写的行）；待判键从此重新累计。
    work = state.thermal_work
    state = %{state | thermal_work: %{work | pending: MapSet.new(),
      electric: ThermalWork.electric(Enum.into(visited, work.electric), state.damage, state.properties)}}

    # 零功率、步间无其他事务、本次没有改写任何记录：下一次求解的输入与本次相同，电路不再自行推进。
    # `settled`：交给提交后的转化重判的行键。
    {state, %{rows: rows, phase_changes: phase_changes, settled: settled,
      quiet: not run.powered and not run.disturbed and rows == [] and phase_changes == %{},
      dead: Enum.filter(rows, &(&1.hp == 0.0 and not phase_target?(state, &1))),
      semblances: semblance_txn(run.semblances, state),
      busy_us: run.busy_us + System.monotonic_time(:microsecond) - stepped, started: run.started, steps: run.steps}}
  end

  # 一个电路段：按段起点求解功率，段内内核步连续执行，段末写入发光与电源观察行；另返回本段是否有非零功率。
  defp circuit_segment(state, remaining, visited) do
    seeds = circuit_seeds(state, visited)

    # 受保护区域：导线端点按槽的持有者分开，端点只接同一持有者的实体导体。
    protection = state.protection
    domain = if not Protection.empty?(protection),
      do: fn slot -> cells_holder(protection, Attachments.macros([slot]), slot) end
    input = VoxelRegion.Circuit.prepare(state.attachments, state.damage, state.properties, remaining,
      state.thermal.config, domain)
    {hosts, state} = Enum.map_reduce(VoxelRegion.Circuit.points(input), state, fn point, s ->
      {targets, s} = Enum.map_reduce(VoxelRegion.Circuit.near_points(point), s, &circuit_target/2)
      conductors = VoxelRegion.Circuit.conductors(targets, s.properties, s.damage, s.thermal.config)
      conductors = if domain,
        do: Enum.filter(conductors, &({:holder, Protection.holder(protection, Damage.macro(&1))} == elem(point, 2))),
        else: conductors
      {{point, conductors}, s}
    end)
    # 导体图从线端点的宿主与电动势种子（有储能的蓄能石、带温度的热电石）两头按实接触扩张。
    solids = for target <- seeds ++ for({_point, targets} <- hosts, target <- targets, do: target), into: %{},
      do: {VoxelRegion.ThermalGeometry.key(target), target}
    {contacts, state} = circuit_contacts(Map.values(solids), MapSet.new(), [], state)
    plan = VoxelRegion.Circuit.plan(input, Map.new(hosts), contacts)
    {state, visited} = thermal_steps(state, plan.duration, visited, plan.powers)
    candidates = electric_candidates(state, visited)
    {damage, visited} = electric_rows(state.damage, visited, plan.electric, candidates)
    {damage, visited} = source_rows(state, damage, visited, plan.sources, candidates)

    # 佩尔捷两键在 R8-09 片 1 引入；之前已累计热电做功的世界升级后它们从 0 起算、不补造历史值，
    # 所以“吸热 − 放热 = 热电做功”只对键引入之后的增量成立（基线 = 引入时的热电做功）。
    thermal =
      state.thermal
      |> Map.update(:circuit_supplied_j, plan.supplied_j, &(&1 + plan.supplied_j))
      |> Map.update(:circuit_charged_j, plan.charged_j, &(&1 + plan.charged_j))
      |> Map.update(:circuit_thermoelectric_j, plan.thermoelectric_j, &(&1 + plan.thermoelectric_j))
      |> Map.update(:circuit_peltier_absorbed_j, plan.peltier_absorbed_j, &(&1 + plan.peltier_absorbed_j))
      |> Map.update(:circuit_peltier_released_j, plan.peltier_released_j, &(&1 + plan.peltier_released_j))
      |> Map.update(:circuit_light_j, plan.light_j, &(&1 + plan.light_j))

    Logger.info(
      "voxel_circuit simulated_s=#{plan.duration} nodes=#{plan.nodes} edges=#{plan.edges} solve_us=#{plan.elapsed_us} supplied_j=#{plan.supplied_j} charged_j=#{plan.charged_j} thermoelectric_j=#{plan.thermoelectric_j} peltier_absorbed_j=#{plan.peltier_absorbed_j} peltier_released_j=#{plan.peltier_released_j} light_j=#{plan.light_j} luminous=#{map_size(plan.electric)} sources=#{map_size(plan.sources)} idle_networks=#{plan.idle_networks} idle_w=#{plan.idle_w}"
    )

    {%{state | damage: damage, thermal: thermal}, visited, plan.duration, plan.powers != %{}}
  end

  # 全局系统功能（R8-04 增量 3）：蓄能石的储能 `stored_j` 是格属性行上的真值；本段求解的电动势与带号电流
  # （蓄能石、热电石）是派生观察，写在同一行上随属性下发。新放置的蓄能石没有行，按需建默认行；离开所有已求解
  # 网络的行去掉两个观察字段，储能保留。值不变的记录不进提交。
  defp source_rows(state, damage, visited, sources, candidates) do
    lit =
      for {_key, view} <- sources, into: %{} do
        target = view.target
        key = Damage.key(target)
        row = Map.get_lazy(damage, key, fn -> property_state(%{state | damage: damage}, target) end)
        battery = VoxelRegion.Circuit.battery?(state.properties.materials[target.material])
        fields = %{source_emf_v: view.emf_v, source_current_a: view.current_a}
        fields = if battery, do: Map.put(fields, :stored_j, view.stored_j), else: fields
        {key, Map.merge(row, fields)}
      end

    stale = for key <- candidates, %{source_emf_v: _} = row <- [Map.get(damage, key)], not Map.has_key?(lit, key), into: %{},
      do: {key, Map.drop(row, [:source_emf_v, :source_current_a])}

    Enum.reduce(Map.merge(stale, lit), {damage, visited}, fn {key, row}, {d, v} ->
      if Map.get(d, key) == row, do: {d, v}, else: {Map.put(d, key, row), MapSet.put(v, key)}
    end)
  end

  # 全局系统功能：发光导体（目录 λ > 0）本段求解的电功率与穿过电流是派生观察，写在已有温度记录上随属性下发；
  # 不再通电的记录去掉这两个字段。值不变的记录不进提交（提交只发与提交前不同的记录）。
  defp electric_rows(damage, visited, electric, candidates) do
    lit =
      for {_key, {target, w, a}} <- electric, key <- [Damage.key(target)],
          %{temperature_kelvin: _} <- [Map.get(damage, key)], into: %{},
          do: {key, %{electric_w: w, current_a: a}}

    stale = for key <- candidates, %{electric_w: _} <- [Map.get(damage, key)], not Map.has_key?(lit, key), into: %{},
      do: {key, nil}

    Enum.reduce(Map.merge(stale, lit), {damage, visited}, fn
      {key, nil}, {d, v} -> {Map.update!(d, key, &Map.drop(&1, [:electric_w, :current_a])), MapSet.put(v, key)}
      {key, fields}, {d, v} -> {Map.update!(d, key, &Map.merge(&1, fields)), MapSet.put(v, key)}
    end)
  end

  # D6：散体格（带数量记录）不导电——不是种子、不是线端宿主、不参与实体接触。
  # 只在电路候选与本次提交改写过的行（`visited`）里判定（R8-05）：候选之外的行不是种子。
  defp circuit_seeds(state, visited),
    do: Enum.reject(VoxelRegion.Circuit.seeds(state.damage, state.properties, electric_candidates(state, visited)),
      &loose_cell?(state, &1))

  # 可能带电观察字段或是种子的行键：上次结算后的候选、此后事务改写（touch 已并入）与本次提交改写过的行。
  defp electric_candidates(state, visited), do: Enum.into(visited, state.thermal_work.electric)

  defp circuit_target(point, state) do
    {target, state} = target_at(point, state)
    {if(target && loose_cell?(state, target), do: nil, else: target), state}
  end

  # 按实际连通导体扩张 canonical 读取；不预读全世界，也不把 owner 交给计算模块。
  defp circuit_contacts([], _seen, contacts, state), do: {contacts, state}

  defp circuit_contacts([target | queue], seen, contacts, state) do
    key = VoxelRegion.ThermalGeometry.key(target)
    if MapSet.member?(seen, key) do
      circuit_contacts(queue, seen, contacts, state)
    else
      seen = MapSet.put(seen, key)
      {targets, state} = Enum.flat_map_reduce(VoxelRegion.Circuit.solid_faces(target), state, &face_targets/2)
      {queue, contacts} = Enum.reduce(VoxelRegion.Circuit.solid_contacts(targets, state.properties, state.damage,
          state.thermal.config),
        {queue, contacts}, fn {other_key, {other, area}}, {queue, contacts} ->
          if MapSet.member?(seen, other_key) or
               not Protection.same_holder?(state.protection, Damage.macro(target), Damage.macro(other)),
            do: {queue, contacts},
            else: {[other | queue], [{target, other, area} | contacts]}
        end)
      circuit_contacts(queue, seen, contacts, state)
    end
  end

  # 一个面的全部采样点都在同一个相邻宏格里时：该格未细分、没有液位（液位让同一格按高度部分为空）就对每个点给出
  # 同一个目标，只读一次（原先宏格导体每面逐点 64 次）；否则逐点读取，每点一段。
  defp face_targets([point | _] = points, state) do
    {cell, _} = Prefab.macro_slot(point)
    if length(points) > 1 and not Map.has_key?(state.refined, cell) and not Map.has_key?(state.liquid_units, cell) do
      {target, state} = circuit_target(point, state)
      {[{target, length(points)}], state}
    else
      Enum.map_reduce(points, state, fn p, s -> {t, s} = circuit_target(p, s); {{t, 1}, s} end)
    end
  end

  defp thermal_steps(state, remaining, visited, _powers) when remaining < 1.0e-12,
    do: {state, visited}

  defp thermal_steps(state, remaining, visited, powers) do
    {state, changed, done} = thermal_step(state, remaining, powers)
    thermal_steps(state, remaining - done, MapSet.union(visited, changed), powers)
  end

  defp thermal_step(state, duration, powers) do
    started = System.monotonic_time(:microsecond)
    config = state.thermal.config
    state = refresh_native(state)

    # 魔法增量 2：已落地拟态的接触候选宏格（包围立方体覆盖或贴面）与热源同为热种子（plan 只读键）。
    contacts = for {_, s} <- semblances(state), Magic.Semblance.landed?(s), cell <- Magic.Semblance.span(s),
      into: %{}, do: {cell, nil}
    # 魔法增量 4：身体接触的世界格同为热种子。
    contacts = for {_, b} <- state.bodies, {kind, _key, cell, _g} <- b.contacts, kind in [:node, :wet], into: contacts,
      do: {cell, nil}
    plan = ThermalWork.plan(state.thermal_work, Map.merge(contacts, state.thermal.sources), powers, state.damage)
    neighborhood_done = System.monotonic_time(:microsecond)

    {geometry, state} = Enum.reduce(plan.missing, {plan.geometry, state}, &thermal_cell/2)

    {plan, geometry, state} =
      if VoxelRegion.ThermalRadiation.enabled?(config),
        do: sight_domain(state, plan, geometry),
        else: {plan, geometry, state}

    geometry_done = System.monotonic_time(:microsecond)

    {work, rebuild?} = ThermalWork.refresh(state.thermal_work, plan, geometry, state.attachments)
    refreshed = System.monotonic_time(:microsecond)

    {work, state} =
      if rebuild? do
        {samples, state} = thermal_samples(state,
          VoxelRegion.ThermalAttachments.points(work.thermal_slots, state.properties), %{})
        {nodes, attachment_graph} = VoxelRegion.ThermalAttachments.add(
          work.solid_nodes, work.thermal_slots, state.properties, samples, work.attachment_graph)

        # 增量扩域只新增本次扩张宏格的节点（附件派生节点另行比较）；整域重算时与上次节点表整表比较。
        hint = if plan.grown, do: {:grown, for(cell <- plan.grown, {key, _} <- Map.fetch!(geometry, cell), do: key)},
          else: :full
        derived = attachment_graph |> elem(1) |> Map.keys()
        # 默认记录只由目录、环境和实占用派生；已有属性在装入原生热域时读取。
        # 派生字段按目录与环境标签缓存；相态宏格的默认 HP 随有限数量变化，每次重算。
        defaults = %{state | damage: %{}}
        tag = {state.properties.digest, config["ambient_kelvin"], config["climate_zones"]}
        bound = if thermal_bounded?(state), do: &node_holder(state, &1)

        augment = fn n ->
          {Map.merge(n, %{damage_key: Damage.key(n.target), cell: Damage.macro(n.target),
                          cells: ThermalWork.cells(n.target), default: property_state(defaults, n.target),
                          ignition: if(Combustion.combustible?(n.material),
                            do: n.material["ignition_kelvin"] * 1.0, else: nil)}),
           finite_target?(state, n.target)}
        end

        domain = ThermalDomain.sync(work.domain, nodes, hint, derived, tag, bound, augment, &record(state, &1))
        {%{work | domain: domain, attachment_graph: attachment_graph}, state}
      else
        {work, state}
      end

    rebuilt = System.monotonic_time(:microsecond)
    # 视线只随扩域或编辑变化；节点表或视线变了才重建原生内核边与辐射项。
    domain = ThermalDomain.sync_sights(work.domain, work.sights)

    work =
      if rebuild? or domain.sights != work.domain.sights,
        do: %{work | domain: domain} |> reindex(config),
        else: work

    ordered = work.ordered
    nodes_done = System.monotonic_time(:microsecond)

    sources =
      Map.filter(state.thermal.sources, fn {cell, source} ->
        Enum.any?(Map.get(geometry, cell, []), fn {_, n} ->
          same_target?(source.target, n.target) and source.remaining_j > 0
        end)
      end)

    semblances = Enum.sort(semblances(state))
    duration = Magic.Semblance.cap(Enum.map(semblances, &elem(&1, 1)), duration)

    # 拟态是内核外部节点：接在世界节点之后，接触边与辐射项按同一下标追加；结果按世界节点数切分。
    count = length(ordered)
    {extra, edges, radiation} = semblance_terms(state, semblances, ordered, count, {[], []})
    bodies = Enum.sort(state.bodies)
    # 身体接触的世界节点下标按键向热域查询（通常为空）。
    positions = ThermalDomain.positions(work.domain,
      for({_, b} <- bodies, key <- [b.sole | for({kind, key, _, _} <- b.contacts, kind in [:node, :wet], do: key)],
        key != nil, do: key))
    {body_nodes, body_edges} = body_terms(bodies, positions, semblances, count)
    requested = Enum.uniq(for {j, _i, _g} <- body_edges, j < count, do: j)
    # 逐节点环境温度：拟态按所在宏格，身体两节点（暴露面积 0、恒为种子）取全局值不影响数值。
    ambient =
      Enum.map(semblances, fn {_, s} -> ambient_at(state, Magic.Semblance.macro(Magic.Semblance.current(s))) * 1.0 end) ++
      Enum.flat_map(bodies, fn _ -> [config["ambient_kelvin"] * 1.0, config["ambient_kelvin"] * 1.0] end)

    prepared = System.monotonic_time(:microsecond)

    # 世界节点在原生热域里组装、演进并结算；拟态／身体的接触追加其后，拟态辐射项排在世界辐射项之前。
    {domain, step} =
      ThermalDomain.step(work.domain, duration, config["environment_w_per_m2_k"] * 1.0,
        config["tolerance_kelvin"] * 1.0,
        for({cell, source} <- sources, do: {cell, source.power_w * 1.0, source.remaining_j * 1.0}),
        powers, extra ++ body_nodes, edges ++ body_edges, ambient, radiation, requested)

    work = %{work | domain: domain}
    calculated = System.monotonic_time(:microsecond)
    done = step.elapsed
    {semblance_result, body_result} = Enum.split(step.extra, length(semblances))
    sources = for {cell, rest} <- step.sources, into: %{}, do: {cell, %{Map.fetch!(sources, cell) | remaining_j: rest}}

    # 共享完整度损失按内核次序累计到部件／附件池（同原结算的算式与次序），在部件记录上扣减。
    losses = Enum.reduce(step.losses, %{}, fn {key, before, hp}, losses ->
      micro = work.domain.table[key].target
      pool = if micro.granularity == 4, do: {3, micro.incarnation}, else: {2, micro.owner}
      Map.update(losses, pool, {micro, before - hp}, fn {row, loss} -> {row, loss + before - hp} end)
    end)

    changes =
      for {{granularity, _}, {micro, loss}} <- losses do
        target =
          property_state(state, %{
            Map.take(micro, [:micro, :granularity, :incarnation, :owner, :material])
            | granularity: granularity
          })

        target = %{target | hp: max(0.0, target.hp - loss)}
        {Damage.key(target), target}
      end

    damage = Map.merge(state.damage, Map.new(changes))
    settled = System.monotonic_time(:microsecond)
    {state, work, propagated, fresh} = ignite_heated_materials(%{state | damage: damage}, work, step.ignitions)
    damage = state.damage
    ignited = System.monotonic_time(:microsecond)
    changes = changes ++ propagated
    record_key = &Map.fetch!(work.domain.table, &1).damage_key
    changed = MapSet.new(Enum.map(step.changed, record_key) ++ Enum.map(changes, &elem(&1, 0)))
    hot = work.domain.hot

    active =
      map_size(sources) > 0 or MapSet.size(hot) > 0 or
        Enum.any?(damage, fn {_, t} -> Map.get(t, :burning, false) end)

    # 首次点燃的燃料账：只计点燃前记录没有燃料字段的节点（同原实现的求和次序）。
    initialized = Enum.reduce(propagated, 0.0, fn {key, row}, sum ->
      if MapSet.member?(fresh, key), do: sum + row.remaining_fuel_j, else: sum
    end)
    thermal_base = Map.merge(%{combustion_j: 0.0, combustion_removed_j: 0.0}, state.thermal)
      |> Map.update(:fuel_initialized_j, initialized, &(&1 + initialized))

    thermal = %{
      thermal_base
      | sources: sources,
        elapsed_s: thermal_base.elapsed_s + done,
        active: active,
        supplied_j: thermal_base.supplied_j + step.supplied,
        environment_j: thermal_base.environment_j + step.environment,
        combustion_j: thermal_base.combustion_j + step.combustion
    }

    # 燃烧行只随熄灭与点燃变化（其余变化行的燃烧标记不变）；部件记录照原规则一并登记。
    burned = Enum.map(step.extinguished, &{record_key.(&1), %{burning: false}}) ++ changes
    state = %{state | damage: damage, thermal: thermal, thermal_work: %{work | hot: hot}}

    state =
      if active,
        do: put_in(state.thermal_work, ThermalWork.burned(state.thermal_work, burned)),
        else: %{flush(state) | thermal_work: %{ThermalWork.new() | builds: work.builds, hot_rows: work.hot_rows,
          touched: work.touched, burning: %{}, pending: work.pending, due: work.due, electric: work.electric}}

    state = advance_semblances(state, semblances, semblance_result, done)
    temperatures = Map.new(Enum.zip(requested, step.temperatures) ++
      Enum.with_index(Enum.map(semblance_result, &elem(&1, 0)), &{&2 + count, &1}))
    state = exchange_bodies(state, bodies, body_edges, body_result, count + length(semblances), temperatures, positions, done)
    state = seen(state)

    Logger.info(
      "voxel_thermal_kernel simulated_s=#{done} nodes=#{count + length(extra) + length(body_nodes)} edges=#{work.domain.edges} radiation_pairs=#{work.domain.pairs + length(elem(radiation, 0))} sky_faces=#{work.domain.sky + length(elem(radiation, 1))} prepare_us=#{prepared - started} nif_us=#{calculated - prepared} accept_us=#{System.monotonic_time(:microsecond) - calculated}"
    )

    Logger.info(
      "voxel_thermal_prepare neighborhood_us=#{neighborhood_done - started} geometry_us=#{geometry_done - neighborhood_done} nodes_us=#{nodes_done - geometry_done} input_us=#{prepared - nodes_done} refresh_us=#{refreshed - geometry_done} rebuild_us=#{rebuilt - refreshed} terms_us=#{nodes_done - rebuilt} settle_us=#{settled - calculated} ignite_us=#{ignited - settled} changed=#{length(step.changed)} rebuild=#{rebuild?}"
    )

    {state, changed, done}
  end

  @doc """
  把原生热域里尚未写回的节点值写回属性记录（唯一真值）。World 在热提交进行中处理任何其他消息之前、
  以及提交结束时调用；此后外部事务对记录的改写在下一步开始时装回原生热域。
  """
  # `reason` 只进日志：触发写回的消息标签，或提交阶段。
  def flush(state, reason \\ :commit)

  def flush(%{thermal_work: %{domain: %{pending: false}}} = state, _reason), do: state

  def flush(state, reason) do
    started = System.monotonic_time(:microsecond)
    {domain, values} = ThermalDomain.flush(state.thermal_work.domain)

    rows =
      Map.new(values, fn {key, dynamic} ->
        node = Map.fetch!(domain.table, key)
        base = Map.get(state.damage, node.damage_key) || %{node.default | seq: state.seq}
        {node.damage_key, ThermalRecord.row(base, dynamic)}
      end)

    Logger.info("voxel_thermal_flush reason=#{inspect(reason)} rows=#{map_size(rows)} us=#{System.monotonic_time(:microsecond) - started}")
    seen(%{state | damage: Map.merge(state.damage, rows), thermal_work: %{state.thermal_work | domain: domain}})
  end

  # 记下已与原生热域一致的记录与有限数量；此后的改写都来自其他事务。
  defp seen(state),
    do: put_in(state.thermal_work.domain.seen, {state.damage, state.liquid_units})

  # 上次一致之后其他事务改写过的节点记录（或有限数量）按当前记录装回原生热域；热格集合按需推送。
  defp refresh_native(state) do
    domain = state.thermal_work.domain

    keys =
      case domain.seen do
        nil -> []
        {damage, liquid} when damage == state.damage and liquid == state.liquid_units -> []
        {damage, liquid} ->
          liquid? = liquid != state.liquid_units
          for {key, node} <- domain.table,
              (liquid? and MapSet.member?(domain.finite, key)) or
                not ThermalRecord.same?(Map.get(state.damage, node.damage_key), Map.get(damage, node.damage_key)),
              do: key
      end

    domain = ThermalDomain.reload(domain, for(key <- keys, do: {key, elem(record(state, domain.table[key]), 1)}))
    seen(put_in(state.thermal_work.domain, ThermalDomain.put_hot(domain, state.thermal_work.hot)))
  end

  # 节点的原生静态量与当前记录的动态量（无记录时为带当前 seq 的默认记录）。
  defp record(state, node) do
    row = Map.get(state.damage, node.damage_key) || %{node.default | seq: state.seq}
    ambient = VoxelRegion.Climate.air_k(state.thermal.config, node.cell)
    phase? = phase_target?(state, node.target)
    volume = if phase?, do: finite_volume(state, node.target)
    {ThermalRecord.static(node, ambient, phase?), ThermalRecord.dynamic(row, ambient, node.material, volume)}
  end

  # ---- 魔法增量 2：拟态作为热内核外部节点（Voxim Docs/Magic.md §3；纯规则在 Magic.Semblance）
  # 节点 {T,1,1,C,k_s,1e6,暴露面积,0,0,true}；已落地时按当前世界与本次域内每个贴面 / 重叠的实占用节点各连一条接触边
  # （面积与法向按真实几何，Magic.Semblance.contact/2；串联导热同 ThermalGeometry），与接触节点按角系数互换辐射、
  # 按接触面积比例分摊，其余对天空；受保护区域 / 气候区边界同 protected_contacts：拟态所在格与接触格持有者不同则不连。

  @doc "在册拟态（id => 拟态）。"
  def semblances(%{thermal: nil}), do: %{}

  def semblances(state), do: Map.get(state.thermal, :semblances, %{})

  defp semblance_terms(_state, [], _samples, _count, radiation), do: {[], [], radiation}

  # 世界节点的内核下标即其在内核次序节点列表中的序号；相态宏格按有限体积定盒。
  defp semblance_terms(state, semblances, ordered, count, {pairs, sky}) do
    config = state.thermal.config
    conductivity = state.magic.semblance.conductivity
    emissivity = if VoxelRegion.ThermalRadiation.enabled?(config), do: config["emissivity"] * 1.0, else: 0.0
    bounded = thermal_bounded?(state)
    # 候选宏格里的实占用节点（附件槽不与拟态接触）；有限液柱按实际液位定盒。
    wanted = for {_, s} <- semblances, Magic.Semblance.landed?(s), cell <- Magic.Semblance.span(s), into: MapSet.new(), do: cell
    by_cell = for {{_key, n}, j} <- Enum.with_index(ordered), n.target.granularity != 4,
                  MapSet.member?(wanted, n.cell),
                  volume <- [if(phase_target?(state, n.target), do: finite_volume(state, n.target))],
                  reduce: %{} do
      acc -> Map.update(acc, n.cell, [{j, n, volume}], &[{j, n, volume} | &1])
    end

    {extra, edges, pairs, sky} =
      semblances
      |> Enum.with_index(count)
      |> Enum.reduce({[], [], pairs, sky}, fn {{_id, s}, i}, {extra, edges, pairs, sky} ->
        touching =
          if Magic.Semblance.landed?(s) do
            holder = bounded and thermal_holder(state, Magic.Semblance.macro(s.rest))
            for cell <- Magic.Semblance.span(s), not bounded or thermal_holder(state, cell) == holder,
                {j, n, volume} <- Map.get(by_cell, cell, []),
                {lo, hi} = box <- [VoxelRegion.ThermalGeometry.bounds(n.target, volume || 1.0)],
                {area, axis} <- List.wrap(Magic.Semblance.contact(s, box)),
                do: {j, area, Magic.Semblance.conductance(s, conductivity, n.material["thermal_conductivity"],
                  (elem(hi, axis) - elem(lo, axis)) / 2, area)}
          else
            []
          end

        total = Enum.sum(Enum.map(touching, &elem(&1, 1))) * 1.0
        {mutual, open} = Magic.Semblance.radiation(s, emissivity, total)
        edges = Enum.reduce(touching, edges, fn {j, _area, g}, edges -> [{j, i, g} | edges] end)
        pairs = if mutual > 0, do: Enum.reduce(touching, pairs, fn {j, area, _g}, pairs -> [{i, j, mutual * area / total} | pairs] end), else: pairs
        sky = if open > 0, do: [{i, open} | sky], else: sky
        {[Magic.Semblance.node(s, conductivity, total) | extra], edges, pairs, sky}
      end)

    {Enum.reverse(extra), Enum.reverse(edges), {pairs, sky}}
  end

  # 一段演进后：写回温度、计光与流出账；到达落点转内能；寿命到期移除并把剩余能量作为有限热源释放到接触宏格。
  defp advance_semblances(state, [], _result, _done), do: state

  defp advance_semblances(state, semblances, result, done) do
    {kept, thermal} =
      Enum.zip(semblances, result)
      |> Enum.reduce({%{}, state.thermal}, fn {{id, s}, {temperature, _, _}}, {kept, thermal} ->
        {s, light, exchanged} = Magic.Semblance.step(s, temperature, done)
        thermal = thermal |> ledger(:semblance_light_j, light) |> ledger(:semblance_exchanged_j, exchanged)
        {Map.put(kept, id, s), thermal}
      end)

    state = %{state | thermal: Map.put(thermal, :semblances, kept)}

    kept
    |> Enum.filter(fn {_, s} -> Magic.Semblance.expired?(s) end)
    |> Enum.reduce(state, fn {id, s}, state -> release_semblance(state, id, s) end)
  end

  # 移除拟态（寿命到期或驱散）：剩余能量（显热 + 飞行动能 + 发光余量）记 semblance_released_j；已落地且接触宏格仍是
  # 同一未细分热节点时作为有限热源落入该格（0.5 s 放完），否则（飞行中、无接触、接触格已变）散入空气。
  defp release_semblance(state, id, s) do
    {cell, state} = release_cell(state, s)
    %{state | thermal: release(state.thermal, id, s, cell)}
  end

  @doc "移除拟态并把剩余能量记账；给出落点时作为有限热源落入该格。"
  def release(thermal, id, s, cell) do
    energy = Magic.Semblance.stored_j(s, thermal.config["ambient_kelvin"])

    thermal =
      thermal
      |> Map.update!(:semblances, &Map.delete(&1, id))
      |> ledger(:semblance_released_j, energy)

    if cell, do: deposit_heat(%{thermal | active: true}, cell, energy), else: thermal
  end

  @doc "拟态剩余能量可落入的未细分热宏格；飞行中或接触格已变时为 nil。"
  def release_cell(state, %{contact: %{target: %{granularity: 0} = target}} = s) do
    if Magic.Semblance.landed?(s) do
      {current, state} = target_at(target.micro, state)
      {if(current && same_target?(current, target) && heat_node?(state, current), do: current), state}
    else
      {nil, state}
    end
  end

  def release_cell(state, _s), do: {nil, state}

  # 拟态表的变化随同一事务下发（按 id：新值或 nil 删除）；持久化靠事务里的 thermal（含整张表）。
  @doc "相对 `before` 变化的拟态随事务下发的字段。"
  def semblance_txn(before, state) do
    after_map = semblances(state)

    delta =
      for id <- Enum.uniq(Map.keys(before) ++ Map.keys(after_map)),
          Map.get(before, id) != Map.get(after_map, id),
          into: %{},
          do: {id, Map.get(after_map, id)}

    if delta == %{}, do: %{}, else: %{semblances: delta}
  end

  # ---- 魔法增量 4：身体皮肤与局部接触组织块作为热内核外部节点（接触规则在 BodyContact；身体真值在 Scene）
  # 每个身体两节点接在拟态之后：皮肤 {T_skin, 1, 1, C_skin, 0, 1e6, 暴露 0, 0, 0, true} 与组织块 {T_tissue, …, C_tissue, …}，
  # 两者之间一条内部边（Scene 报的 G = 组织块面积 × 核心-皮肤导热）。鞋底与触碰拟态接组织块，浸没（大面积分布接触）接皮肤；
  # 接触边只连本次域内的世界节点与在册拟态。

  # 本次报告的接触：脚下偏离环境的实体格、脚所在列与身体竖向重叠的液体格（浸没比例一并回传）、碰到的已落地拟态。
  @doc "身体本次报告的热接触：脚下偏离环境的实体格、浸没液体格、碰到的已落地拟态。"
  def body_contacts(state, %{feet: {fx, fy, fz} = feet, height: height, radius: radius, area: area}) do
    config = state.thermal.config

    {sole, state} =
      case foot_target(state, %{feet: feet}) do
        {:ok, foot, state} ->
          m = state.properties.materials[foot.material]
          ambient = ambient_at(state, Damage.macro(foot))
          t = temperature(state, foot, ambient)

          if Phase.liquid?(foot.material) or abs(t - ambient) <= config["tolerance_kelvin"],
            do: {[], state},
            else: {[{:node, VoxelRegion.ThermalGeometry.key(foot), Damage.macro(foot),
                     VoxelRegion.BodyContact.sole(m["thermal_conductivity"], 0.5)}], state}

        {:error, _, state} ->
          {[], state}
      end

    {x, z} = {floor(fx), floor(fz)}

    {wet, state} =
      Enum.flat_map_reduce(floor(fy)..floor(fy + height - 1.0e-9)//1, state, fn y, state ->
        case target_at({x * @micro + 4, y * @micro, z * @micro + 4}, state) do
          {%{granularity: 0} = t, state} ->
            overlap = VoxelRegion.BodyContact.overlap(fy, height, y, finite_volume(state, t))

            if Phase.liquid?(t.material) and overlap > 0,
              do: {[{overlap, {:wet, VoxelRegion.ThermalGeometry.key(t), Damage.macro(t),
                     VoxelRegion.BodyContact.immersion(area, overlap, height)}}], state},
              else: {[], state}

          {_, state} ->
            {[], state}
        end
      end)

    touched =
      for {id, s} <- semblances(state), Magic.Semblance.landed?(s),
          VoxelRegion.BodyContact.touching?(s.rest, s.radius_m, feet, height, radius),
          do: {:semblance, id, VoxelRegion.BodyContact.touch(s.radius_m, state.magic.semblance.conductivity)}

    immersed = min(1.0, Enum.sum(Enum.map(wet, &elem(&1, 0))) / height)
    sole_key = Enum.find_value(sole, fn {:node, key, _cell, _g} -> key end)
    {sole ++ Enum.map(wet, &elem(&1, 1)) ++ touched, immersed, sole_key, state}
  end

  # 格的当前温度：热提交进行中尚未写回的节点读原生侧工作副本（只读这一格，不为它写回整个工作集），其余读记录。
  defp temperature(state, target, ambient) do
    domain = state.thermal_work.domain
    key = VoxelRegion.ThermalGeometry.key(target)

    if domain.pending and Map.has_key?(domain.table, key),
      do: elem(Map.fetch!(ThermalDomain.values(domain, [key]), key), 0),
      else: Map.get(property_state(state, target), :temperature_kelvin, ambient)
  end

  defp body_terms([], _indices, _semblances, _count), do: {[], []}

  defp body_terms(bodies, indices, semblances, count) do
    first = count + length(semblances)
    semblance_index = semblances |> Enum.with_index(count) |> Map.new(fn {{id, _}, i} -> {id, i} end)

    edges =
      for {{_cid, b}, k} <- Enum.with_index(bodies), skin <- [first + 2 * k],
          edge <- [{skin, skin + 1, b.tissue_g} |
            for(contact <- b.contacts, j = body_peer(contact, indices, semblance_index), j != nil,
              do: {j, if(elem(contact, 0) == :wet, do: skin, else: skin + 1), elem(contact, tuple_size(contact) - 1)})],
          do: edge

    nodes = for {_cid, b} <- bodies, node <- [{b.skin_k, 1.0, 1.0, b.capacity, 0.0, 1.0e6, 0.0, 0.0, 0.0, true},
      {b.tissue_k, 1.0, 1.0, b.tissue_capacity, 0.0, 1.0e6, 0.0, 0.0, 0.0, true}], do: node
    {nodes, edges}
  end

  defp body_peer({kind, key, _cell, _g}, indices, _semblances) when kind in [:node, :wet], do: Map.get(indices, key)

  defp body_peer({:semblance, id, _g}, _indices, semblances), do: Map.get(semblances, id)

  # 一段演进后：身体吸热 q = C_skin·ΔT_skin + C_tissue·ΔT_tissue（内部边两端抵消，q 即经接触边进身体的热），记
  # body_exchange_j 并回传 Scene（同一值两端各记一笔）；其中存进组织块的 tissue_j = C_tissue·ΔT_tissue 一并回传，
  # 组织块段末温度留作下一段起点（Scene 下次报告覆盖）。接触温度诊断分两路：鞋底格温度 sole_k 与其余裸接触（浸没液体、
  # 触碰拟态）最高温度 max_contact_k，某路没有接触时为 nil（只进日志，剂量读组织块温度）。
  defp exchange_bodies(state, [], _edges, _result, _others, _temperatures, _indices, _done), do: state

  # `others` 为世界节点与拟态的数目，`temperatures` 为身体接触所需下标的步末温度。
  defp exchange_bodies(state, bodies, edges, result, others, temperatures, indices, done) do
    bodies
    |> Enum.zip(Enum.chunk_every(result, 2))
    |> Enum.with_index()
    |> Enum.reduce(state, fn {{{cid, b}, [{skin, _, _}, {tissue, _, _}]}, k}, state ->
      node = others + 2 * k
      sole = b.sole && Map.get(indices, b.sole)
      touched = for {j, i, _g} <- edges, i in [node, node + 1], j < others, do: {j == sole, Map.fetch!(temperatures, j)}
      tissue_j = b.tissue_capacity * (tissue - b.tissue_k)
      q = b.capacity * (skin - b.skin_k) + tissue_j
      bare = for {false, t} <- touched, do: t
      send(b.pid, {:body_heat, %{q_j: q, tissue_j: tissue_j, tissue_k: tissue, max_contact_k: if(bare != [], do: Enum.max(bare)),
        sole_k: Enum.find_value(touched, fn {on_sole, t} -> on_sole && t end), immersed: b.immersed, dt_s: done,
        seq: state.seq}})
      %{state | bodies: Map.put(state.bodies, cid, %{b | tissue_k: tissue}),
        thermal: ledger(state.thermal, :body_exchange_j, q)}
    end)
  end

  # 一个宏格的热节点几何：canonical 读取留在 owner 内，摘要由 ThermalGeometry 纯函数生成。
  defp thermal_cell(cell, {geometry, s}) do
    faces = VoxelRegion.ThermalGeometry.faces(cell, s.refined)
    {samples, s} = thermal_samples(s, Enum.map(faces, &elem(&1, 0)), %{})
    thermal_faces = Enum.filter(faces, fn {point, _} ->
      case Map.fetch!(samples, point) do
        nil -> false
        {target, volume} -> thermal_node?(s, target, volume)
      end
    end)
    {samples, s} = thermal_samples(s, VoxelRegion.ThermalGeometry.points(thermal_faces), samples)
    nodes = VoxelRegion.ThermalGeometry.cell(thermal_faces, s.properties.materials, samples)

    {Map.put(geometry, cell, nodes), s}
  end

  # 辐射候选域：补齐候选宏格的视线（按宏格缓存），热种子视线命中的伙伴宏格一并读取几何并入域。
  # 伙伴不是种子；只有真实升温越过容差才由既有前沿规则扩张它自己的邻域和视线。
  # 计划只列出尚缺视线的格与需要核对伙伴的种子（精确域内旧种子的伙伴已在域内）。
  defp sight_domain(state, plan, geometry) do
    {state, sights} = Enum.reduce(plan.sightless, {state, state.thermal_work.sights}, &cell_sights(&1, &2, geometry))
    extra = MapSet.difference(VoxelRegion.ThermalRadiation.partners(sights, plan.fresh), plan.cells)
    {geometry, state} = Enum.reduce(extra, {geometry, state}, &thermal_cell/2)
    {state, sights} = Enum.reduce(extra, {state, sights}, &cell_sights(&1, &2, geometry))

    {%{plan | cells: MapSet.union(plan.cells, extra), missing: MapSet.union(plan.missing, extra),
       grown: plan.grown && MapSet.union(plan.grown, extra)},
     geometry, put_in(state.thermal_work.sights, sights)}
  end

  defp cell_sights(cell, {state, sights}, geometry) do
    if Map.has_key?(sights, cell) do
      {state, sights}
    else
      range = state.thermal.config["view_range_cells"] * @micro
      # 视线只在起点宏格的热分区（持有者 × 气候区）内行进；无区域且无气候区时不检查。
      holder = if thermal_bounded?(state), do: {:holder, thermal_holder(state, cell)}
      {rows, state} = Enum.flat_map_reduce(Map.fetch!(geometry, cell), state, fn {key, node}, s ->
        {hits, s} = Enum.map_reduce(node.rays, s, fn {start, axis, sign, area}, s ->
          {hit, s} = sight(s, start, axis, sign, range, holder)
          {{hit, area}, s}
        end)
        {VoxelRegion.ThermalRadiation.sights(key, hits), s}
      end)
      {state, Map.put(sights, cell, rows)}
    end
  end

  # 沿法线读取 canonical 实占用至多 range 个微格长度：refined 或有限液柱宏格内逐微格，
  # 其余空宏格整格跳过。命中热节点返回其节点键与宏格；无热容量占用或视距内全空为天空。
  defp sight(state, _point, _axis, _sign, left, _holder) when left <= 0, do: {:sky, state}

  defp sight(state, point, axis, sign, left, holder) do
    if holder != nil and
         {:holder, thermal_holder(state, elem(Prefab.macro_slot(point), 0))} != holder,
       do: {:blocked, state},
       else: sight_step(state, point, axis, sign, left, holder)
  end

  defp sight_step(state, point, axis, sign, left, holder) do
    case target_at(point, state) do
      {nil, state} ->
        {cell, _} = Prefab.macro_slot(point)
        offset = Integer.mod(elem(point, axis), @micro)

        step =
          cond do
            Map.has_key?(state.refined, cell) or Map.has_key?(state.liquid_units, cell) -> 1
            sign > 0 -> @micro - offset
            true -> offset + 1
          end

        sight(state, put_elem(point, axis, elem(point, axis) + sign * step), axis, sign, left - step, holder)

      {target, state} ->
        target = if target.granularity == 2, do: %{target | granularity: 1}, else: target

        if thermal_node?(state, target, finite_volume(state, target)),
          do: {{VoxelRegion.ThermalGeometry.key(target), Damage.macro(target)}, state},
          else: {:sky, state}
    end
  end

  # A cell without a sparse thermal record is at rest by contract. Untouched
  # phase cells whose default enthalpy maps off ambient by more than the
  # equilibrium tolerance (generated snow/ice below its transition under a
  # warmer ambient) are not at rest in the kernel: joining as a neighbour would
  # pin them at the transition and make an unbounded sink. They stay static
  # canonical truth (an adiabatic boundary, like any cell outside the domain)
  # until an authoring, tool or transfer transaction records their enthalpy.
  defp thermal_node?(state, target, volume) do
    materials = state.properties.materials
    material = materials[target.material]
    config = state.thermal.config
    # 天然温度与静止判据都按格所在气候区：寒区里的天然冰/雪默认就在区温，静止并可作邻居入域。
    ambient = VoxelRegion.Climate.air_k(config, Damage.macro(target))

    Map.has_key?(material, "heat_capacity_per_macro") and
      (not phase_target?(state, target) or
         ThermalDomain.phase_recorded?(state.thermal_work.domain, Map.get(state.damage, Damage.key(target), %{}),
           Damage.key(target)) or
         abs(
           Phase.temperature(
             target.material,
             Phase.energy(target, volume, material, ambient),
             volume,
             materials
           ) - ambient
         ) <= config["tolerance_kelvin"])
  end

  # canonical 读取留在 owner 内；计算模块仅接收当次不可变采样，不捕获 World state。
  defp thermal_samples(state, points, samples) do
    Enum.reduce(points, {samples, state}, fn point, {samples, s} ->
      if Map.has_key?(samples, point) do
        {samples, s}
      else
        {target, s} = target_at(point, s)
        target = if target && target.granularity == 2, do: %{target | granularity: 1}, else: target
        sample = if target, do: {target, finite_volume(s, target)}
        {Map.put(samples, point, sample), s}
      end
    end)
  end

  # 点燃只消费实际温度；热源、电热和燃烧热共用接触导热，不另设火种邻接真值。
  # 原生结算按内核次序给出达到点燃温度的可燃节点；按当前值组出记录，走既有 Combustion.ignite/3，
  # 写回记录并装回原生热域。返回的点燃记录与原实现同序（前插）。
  defp ignite_heated_materials(state, work, []), do: {state, work, [], MapSet.new()}

  defp ignite_heated_materials(state, work, keys) do
    values = ThermalDomain.values(work.domain, keys)

    {damage, propagated, fresh} =
      Enum.reduce(keys, {state.damage, [], MapSet.new()}, fn key, {damage, changed, fresh} ->
        node = Map.fetch!(work.domain.table, key)
        base = Map.get(damage, node.damage_key) || %{node.default | seq: state.seq}
        target = ThermalRecord.row(base, Map.fetch!(values, key))
        row = Combustion.ignite(target, node.material, combustion_volume(state, target))
        fresh = if Map.has_key?(target, :remaining_fuel_j), do: fresh, else: MapSet.put(fresh, Damage.key(row))
        {Map.put(damage, Damage.key(row), row), [{Damage.key(row), row} | changed], fresh}
      end)

    state = %{state | damage: damage}
    reloaded = for key <- keys, do: {key, elem(record(state, Map.fetch!(work.domain.table, key)), 1)}
    {state, %{work | domain: ThermalDomain.reload(work.domain, reloaded)}, propagated, fresh}
  end

  @doc "热账累加一项。"
  def ledger(thermal, key, value), do: Map.update(thermal, key, value, &(&1 + value))

  # 同格已有热源（同一施法的脚下与目标、连续施法）时并入：余量与功率相加，仍在一个热提交内放完。
  @doc "把能量作为 0.5 s 放完的有限热源落到目标宏格。"
  def deposit_heat(thermal, _target, energy) when energy <= 0, do: thermal

  def deposit_heat(thermal, target, energy) do
    cell = Damage.macro(target)
    source = Map.get(thermal.sources, cell, %{target: target, power_w: 0.0, remaining_j: 0.0})
    source = %{source | power_w: source.power_w + energy / @deposit_seconds, remaining_j: source.remaining_j + energy}
    %{thermal | sources: Map.put(thermal.sources, cell, source)}
  end

  # ---- 受保护区域：物理边界（理想绝热镜面）；无区域时全部原样返回。

  # 节点所在持有者；附件足迹跨持有者时自成一域，与两侧都不接触。
  defp cells_holder(p, cells, key) do
    case cells |> Enum.map(&Protection.holder(p, &1)) |> Enum.uniq() do
      [holder] -> {:holder, holder}
      _ -> {:mixed, key}
    end
  end

  # 热分区 = 受保护区域持有者 × 气候区：分区不同即理想绝热镜面（导热、辐射视线、拟态接触都不跨）。
  # 气候区是大气边界，两侧未记录格各在自己的环境温度静止；若允许跨区导热，边界两侧会在两个无限热库之间
  # 持续传热、不断偏离各自环境而被拉入活动集合（与“埋雪吞并”同类）。无区域且无气候区时原样返回。
  defp thermal_bounded?(state),
    do: not Protection.empty?(state.protection) or VoxelRegion.Climate.zoned?(state.thermal.config)

  defp thermal_holder(state, cell),
    do: {Protection.holder(state.protection, cell), VoxelRegion.Climate.region(state.thermal.config, cell)}

  defp node_holder(state, key) do
    case key |> ThermalWork.key_cells() |> Enum.map(&thermal_holder(state, &1)) |> Enum.uniq() do
      [holder] -> {:holder, holder}
      _ -> {:mixed, key}
    end
  end

  # 按节点表次序重建原生内核边与辐射项（辐射关闭时没有视线，ε 取 0）。
  defp reindex(work, config) do
    emissivity = if VoxelRegion.ThermalRadiation.enabled?(config), do: config["emissivity"], else: 0.0
    {domain, ordered} = ThermalDomain.index(work.domain, emissivity)
    %{work | domain: domain, ordered: ordered}
  end
end
