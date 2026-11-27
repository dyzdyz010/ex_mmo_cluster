defmodule VoxelRegion.World.Projectiles do
  @moduledoc """
  全局系统功能（魔法 v2 切片 5）：飞行中结构的墙钟飞行驱动——50 ms 投射物拍逐段求地形、对 `ends_on_contact` 结构采样人物、
  在投射物提交点结算接触，并交付冻结的人物命中。

  决策稿 `docs/10-active/magic/2026-11-26-p1-closure-slices4-8.md` §5 与 §14 切片 5 答复；设计 TheWorldBook
  `docs/2026-11-19-glyph-composition-game-design.md` §5.1（飞行终点）、§5.4（〈遇〉在投射物拍命中端点求值）、§5.8（飞行沿用
  墙钟合同 `cast-phases-2026-10-05.md`）、§12.1（Harm 判定点）。

  ## 飞行规则（用户已定）

  - 所有投掷结构都不设射程终点（用户 2026-11-26 批准，覆盖决策稿早先的“路程达 `limits.range_m`”）：无质量结构
    （`flags` 第 1 位）直线匀速、有质量结构按弹道，直到接触（〈遇〉→〈散〉，live 2）、落地（之后作为静止结构接入热内核）
    或在飞行中衰竭（热拍判定，live 3）。不在端点悬停。射程与距离衰减都由能量账推导；`limits.range_m` 只作施法域。
  - 飞行中的维持照常在热提交拍步进（`World.Structures.tick/3`，跳过热内核）；位置取本驱动已推进到的墙钟飞行时长。
  - 施放时的读取闭包按报价推导的预计飞行时长预装走廊（`corridor_keys/1`）；之后的弦段由本驱动的页闸按段装入。

  ## 每拍（`:projectile_tick`，50 ms，经 World 的 `Clock`）

  ```mermaid
  sequenceDiagram
    participant W as World
    participant T as 异步采样任务
    participant B as 采样后端（WorldServer.Movement.Projectile）
    W->>T: poll：飞行体（t0、已推进时长、弹道）与冻结交付
    T->>B: ends_on_contact 且施法者是 Player：采当前人物（Harm 判定点 1）
    B-->>T: {:sample, 墙钟时长, 施法者, 命中人物 | nil, 采样时刻}；冻结交付 → Player 接纳（判定点 2）
    T-->>W: {任务引用, 结果}（过页闸：弦段两端的页先驻留）
    W->>W: accept：逐弦段求地形（含可读范围检查）→ 最早的 人物 / 地形 / 越界
    W->>W: Structures.land / hit_body / dissipate / deliver（投射物提交点，一笔事务）
  ```

  - 同一时刻只有一个任务；没有后端或不需要采样的飞行体在任务里只读服务器时间线求墙钟时长。地形与人物沿同一组 0.05 s
    弦段（`Magic.Semblance.flight_segments/2`）。没有接触的拍只改内存里的飞行进度（随下一笔带 `thermal` 的事务落盘），
    不发事务：客户端在飞行位置位时按 t0、初速自行外推。
  - 积压达 mid/hard 或模拟装页失败时不开始新的拍（与热、液体同一冻结语义）。

  ## 离开可读范围（显式终止规则；已定：实现决策，见决策稿 §11.3 #14）

  投掷结构没有射程终点，理论上可以飞很远。每段求交前，World 先确认这段弦两端所在的全部 L0 region 都能从权威 canonical 来源读出
  （`Canonical.decoded/3`：区域基底或 baseline 源）；读不出（`:missing` 等）就在这段起点以 live 3 就地散解（释放落不进格，
  全部计入辐射账），日志 `voxel_structure_flight phase=out_of_domain reason=…`。理由：canonical 求交在缺失 region 上没有
  真值，把缺失当空气会违反“不得把缺失当空气”（AGENTS 铁律 3）；也不能让飞行停在边界悬停（用户已定不悬停）。

  ## 恢复（W5-5）

  World 冷重启时仍在飞行的结构以 live 3 就地散解（一笔事务），不再采样：飞行以墙钟与当时人物为准，停机间隙不可追溯，
  恢复时 Scene 也未接入（沿 v1 `settle_restored`）。已冻结的人物命中交付照常重投同一目标（不可变收据，Player 去重）。
  """
  require Logger
  alias VoxelRegion.Magic.Semblance
  alias VoxelRegion.World.{Clock, HeatCommit, PageLoad, Pages, Structures}
  import VoxelRegion.World.Canonical, only: [decoded: 3, region_of: 1]

  # 投射物拍（ms）：设计 §5.4“投射物拍（50 ms）”。
  @beat_ms 50
  # 驻留预取（s）：飞行体未来这段弦段所在的页由本 owner 保有，避免逐拍退休再装。
  @lookahead_s 1.0

  @doc "有飞行体或（有后端时）冻结交付时排一个投射物拍；没有对象即休眠。"
  def wake(state) do
    if PageLoad.failure(state) == nil and state.projectile_timer == nil and
         state.projectile_task == nil and
         work?(state) do
      %{state | projectile_timer: Clock.send_after(state, self(), :projectile_tick, @beat_ms)}
    else
      state
    end
  end

  defp work?(state),
    do:
      Structures.flights(state) != [] or
        (state.projectile_backend != nil and Structures.deliveries(state) != [])

  @doc """
  开始一轮采样（异步任务）：需要人物采样的飞行体与冻结交付交给后端，其余飞行体只读服务器时间线。任务结果经页闸回到
  `accept/2`。已有任务在途时不重叠。
  """
  def poll(%{projectile_task: nil} = state) do
    backend = state.projectile_backend
    clock = state.server_clock

    {sampled, local} =
      Enum.split_with(Structures.flights(state), fn {_, e} ->
        backend != nil and e.body.flight.source != nil
      end)

    delivered = if backend, do: Structures.deliveries(state), else: []

    if sampled == [] and local == [] and delivered == [] do
      state
    else
      shots =
        for({id, e} <- sampled, do: {id, shot(e.body)}) ++
          for({id, e} <- delivered, do: {id, delivery_shot(e)})

      local = for {id, e} <- local, do: {id, shot(e.body)}

      task =
        Task.async(fn ->
          if(shots == [], do: [], else: backend.poll(shots, clock)) ++ local_results(local, clock)
        end)

      %{state | projectile_task: task}
    end
  end

  def poll(state), do: state

  # 交给后端的飞行体：v2 结构形状（施法者身份、弹道、已推进时长、无质量位、扫掠半径取包围盒最大半尺寸）。
  defp shot(body) do
    %{
      projectile_source: body.flight.source,
      origin: body.origin,
      velocity: body.velocity,
      t0_us: body.t0_us,
      age_s: body.flight.age_s,
      massless: body.massless,
      radius_m: body.half |> Tuple.to_list() |> Enum.max()
    }
  end

  defp delivery_shot(%{body: body, delivery: d}),
    do: %{age_s: body.flight_s, impact_delivery: receipt(d)}

  @doc "冻结交付的收据（Player `receive_effect` 与 kind14 回执的输入，沿 v1 形状；`q_j` 为进入组织的焦耳）。"
  def receipt(d),
    do: %{key: d.key, actor: d.actor, target: d.target, q_j: d.q_mj / 1000, position: d.position}

  # 不采样人物的飞行体：只求墙钟时长（服务器时间线，`MmoContracts.ServerTime`），不早于已推进的时长。
  defp local_results(shots, clock) do
    now = MmoContracts.ServerTime.server_us(clock)

    for {id, s} <- shots,
        do: {id, s.age_s, {:sample, max(s.age_s, (now - s.t0_us) / 1.0e6), nil, nil, now}}
  end

  @doc """
  投射物提交点（任务结果过页闸后）：只接纳仍存在、且飞行进度与发出时相同的结果（期间已终止或已推进的旧结果丢弃）。
  每个飞行体逐弦段求地形，与人物命中比先后，取最早的接触结算；无接触只推进飞行进度。
  """
  def accept(state, results) do
    Enum.reduce(results, state, fn {id, from, result}, state ->
      entry = Map.get(Structures.all(state), id)

      cond do
        entry == nil ->
          state

        Map.has_key?(entry, :delivery) and match?({:delivered, _}, result) ->
          delivered(state, id, entry, result)

        Map.has_key?(entry, :delivery) ->
          state

        match?(%{flight: %{age_s: ^from}}, entry.body) ->
          flown(state, id, entry.body, result)

        true ->
          state
      end
    end)
    |> wake()
  end

  defp delivered(state, _id, _entry, {:delivered, {:retry, :target_unavailable}}), do: state

  defp delivered(state, id, entry, {:delivered, result}) do
    {state, extra, accepted} = Structures.deliver(state, id, result)
    next = HeatCommit.thermal_commit(state, [], extra)
    if accepted, do: state.projectile_backend.notify(receipt(entry.delivery), next.seq)
    next
  end

  defp flown(state, id, body, {:sample, age, actor, hit, sampled_us}) do
    from = body.flight.age_s

    segments =
      Semblance.flight_segments(
        %{origin: body.origin, velocity: body.velocity, age_s: from, massless: body.massless},
        age
      )

    {terrain, state} = walk(segments, body.half, state)
    limit = if terrain, do: elem(terrain, 1), else: :infinity

    person =
      case hit do
        {fraction, target} when age > from ->
          t = from + (age - from) * fraction
          if limit == :infinity or t < limit, do: {t, target}

        _ ->
          nil
      end

    case {person, terrain} do
      {{t, target}, _} ->
        point = Semblance.position(body.origin, body.velocity, t, body.massless)

        commit(
          Structures.hit_body(state, id, t, point, %{
            actor: actor,
            target: target,
            sampled_us: sampled_us
          })
        )

      {nil, {:terrain, t, point, target}} ->
        commit(Structures.land(state, id, t, point, target))

      {nil, {:domain, t, reason}} ->
        Logger.warning(
          "voxel_structure_out_of_domain sid=#{inspect(id)} t_s=#{t} reason=#{inspect(reason)}"
        )

        state |> Structures.advance(id, t) |> Structures.dissipate(id, :out_of_domain) |> commit()

      {nil, nil} ->
        Structures.advance(state, id, age)
    end
  end

  defp commit({state, extra}), do: HeatCommit.thermal_commit(state, [], extra)

  # 逐弦段：先确认可读，再求 canonical 首接触。返回 {{:terrain, t, 中心落点, 目标} | {:domain, t, 原因} | nil, state}。
  defp walk([], _half, state), do: {nil, state}

  defp walk([{t0, t1, a, b} | rest], half, state) do
    case readable(state, a, b) do
      {:error, reason, state} ->
        {{:domain, t0, reason}, state}

      {:ok, state} ->
        case Semblance.segment(a, b, half, state, &Structures.cast/4) do
          {nil, state} ->
            walk(rest, half, state)

          {{fraction, point, target}, state} ->
            {{:terrain, t0 + (t1 - t0) * fraction, point, target}, state}
        end
    end
  end

  @doc """
  一段弦 a → b 两端所在的 L0 region 包围范围都能读出 canonical（区域基底或 baseline 源）：`{:ok, state}` 或
  `{:error, {region, 原因}, state}`。飞行驱动每段求交前与施放时的弹道预测（`Structures.predict_cast/4`）共用这一判定。
  """
  def readable(state, a, b) do
    Enum.reduce_while(regions([a, b]), {:ok, state}, fn region, {:ok, state} ->
      case decoded(state, 0, region) do
        {:ok, _payload, state} -> {:cont, {:ok, state}}
        {:error, reason, state} -> {:halt, {:error, {region, reason}, state}}
      end
    end)
  end

  # 一组点所在 L0 region 的包围范围（弦段两端，或闭包走廊里同一时段各出发点的弦段端点）。
  defp regions(points) do
    rs = Enum.map(points, &region_of(Semblance.macro(&1)))
    [xs, ys, zs] = for i <- 0..2, do: Enum.map(rs, &elem(&1, i))

    for x <- Enum.min(xs)..Enum.max(xs),
        y <- Enum.min(ys)..Enum.max(ys),
        z <- Enum.min(zs)..Enum.max(zs),
        do: {x, y, z}
  end

  @doc """
  读取闭包的飞行走廊（魔法 v2 切片 5b）：`Structures.flight_plan/5` 的计划 → 带祖页的 L0 页键。对每个出发点按
  `Magic.Semblance.flight_segments/2` 切出 0 … 预计飞行时长 T 的弦段，同一时段各出发点的弦段端点取 region 包围范围，
  全部合并。T 由报价推导（`Structures.flight_horizon_s/4`），与施放时预测同一上界；T 之后的飞行由本模块的页闸按段装入，
  读不出 canonical 时按显式规则散解，所以走廊不必覆盖整个飞行。
  """
  def corridor_keys(%{starts: starts, velocity: velocity, massless: massless, horizon_s: horizon}) do
    starts
    |> Enum.map(&Semblance.flight_segments(%{origin: &1, velocity: velocity, age_s: 0.0, massless: massless}, horizon))
    |> Enum.zip()
    |> Enum.flat_map(fn chords -> chords |> Tuple.to_list() |> Enum.flat_map(fn {_, _, a, b} -> [a, b] end) |> regions() end)
    |> Enum.uniq()
    |> Enum.map(&{0, &1})
    |> Pages.with_ancestors()
  end

  @doc """
  页闸种子：本轮任务结果要求交的弦段两端所在 region（带祖页）。只认当前任务的结果，其余引用消息返回 `:none`。
  """
  def result_keys(state, results) do
    all = Structures.all(state)

    for {id, from, {:sample, age, _, _, _}} <- results,
        %{body: %{flight: %{age_s: ^from}} = body} <- [Map.get(all, id)],
        {_, _, a, b} <-
          Semblance.flight_segments(
            %{origin: body.origin, velocity: body.velocity, age_s: from, massless: body.massless},
            age
          ),
        region <- regions([a, b]),
        uniq: true,
        do: {0, region}
  end

  @doc "驻留需求（`World.Residency` 的一个 owner）：每个飞行体自已推进处起 1 s 弦段所在的页（带祖页）。"
  def residency_dependencies(state) do
    keys =
      for {_id, %{body: body}} <- Structures.flights(state),
          f = body.flight,
          {_, _, a, b} <-
            Semblance.flight_segments(
              %{
                origin: body.origin,
                velocity: body.velocity,
                age_s: f.age_s,
                massless: body.massless
              },
              f.age_s + @lookahead_s
            ),
          region <- regions([a, b]),
          uniq: true,
          do: {0, region}

    {:ok, {Pages.with_ancestors(keys), [], []}}
  end

  @doc "可观测：每个飞行体已推进的飞行时长、墙钟应到时长、落后量与等待原因；冻结交付单列。"
  def progress(state) do
    now = MmoContracts.ServerTime.server_us(state.server_clock)

    reason =
      cond do
        PageLoad.failure(state) != nil -> :page_io_failed
        state.page_store.level in [:mid, :hard] -> :writeback
        state.projectile_task != nil -> :sampling
        true -> :timer
      end

    flights =
      for {id, %{body: body}} <- Structures.flights(state) do
        target = max((now - body.t0_us) / 1.0e6, body.flight.age_s)

        %{
          id: inspect(id),
          simulated_through_s: body.flight.age_s,
          target_through_s: target,
          lag_s: target - body.flight.age_s,
          wait_reason: reason,
          sampled: body.flight.source != nil
        }
      end

    deliveries =
      for {id, %{delivery: d}} <- Structures.deliveries(state),
          do: %{id: inspect(id), target: d.target.id, q_mj: d.q_mj}

    %{flights: flights, deliveries: deliveries}
  end

  @doc """
  World 恢复时（W5-5）：仍在飞行的结构以 live 3 就地散解，一笔事务；冻结交付保留，之后照常重投。
  """
  def settle_restored(state) do
    case Structures.flights(state) do
      [] ->
        state

      flights ->
        {state, extra} =
          Enum.reduce(flights, {state, %{}}, fn {id, _}, {state, extra} ->
            {state, more} = Structures.dissipate(state, id, :restored)
            {state, Map.merge(extra, more, fn :structures, a, b -> Map.merge(a, b) end)}
          end)

        next = HeatCommit.thermal_commit(state, [], extra)

        Logger.info(
          "voxel_projectile_restored_dissipated world_seq=#{next.seq} structures=#{inspect(Enum.map(flights, &elem(&1, 0)))}"
        )

        next
    end
  end
end
