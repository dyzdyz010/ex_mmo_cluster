defmodule VoxelRegion.World.StaticL0.Index do
  @moduledoc """
  为回收天然 L0 页内存维护可重建的证明：页及完整三维邻域无记录、默认态在固定环境下无驱动，才取得静态资格。
  `VOXIM_STATIC_L0_RETIREMENT=true` 在重启时开启；World 持有本索引，页的接纳、写入和退休边界负责调用本模块。
  启动失败与迟到结果看 `voxel_static_l0_*` 日志；逐页证据和内存估算只在 debug 审计中输出。
  """
  require Logger
  alias VoxelRegion.World.{Pages, StaticL0}

  @doc """
  空的派生索引，不进入持久化或线协议。

  - `context`：最终环境接纳后的规则上下文（`StaticL0.context/1`），之前为 nil；
  - `cores`：驻留／暂存 L0 页的 core 证明记录 `%{source_only, core, materials, generation, body}`；
  - `eligible`：当前取得 27 页静态资格的页集合；
  - `metrics`：累计分类页数、源生成次数与分类耗时（微秒）。
  """
  def new do
    %{context: nil, cores: %{}, eligible: MapSet.new(),
      metrics: %{classified: 0, generated: 0, classification_us: 0}}
  end

  @doc """
  World 合并存档与资产、得到最终环境之后调用一次：绑定规则上下文，并用它重新判定冷启动时已接纳的源事实。

  冷启动的同步装页发生在最终环境确定之前，那时只记录材料事实（core 结果为 `:environment_not_admitted`）；
  这里才第一次真正发证。环境不受支持时返回 `{:error, {:static_l0_start_failed, reason}}`，World 在启动 writer 前停止。
  """
  def start(%{static_l0_retirement: true} = state) do
    case StaticL0.context(state) do
      {:ok, context} ->
        cores = Map.new(state.static_l0.cores, fn {key, record} -> {key, rejudge(record, context)} end)
        state = put_in(state.static_l0, %{state.static_l0 | context: context, cores: cores})
        {:ok, resident(state, Map.keys(cores))}

      {:error, reason} ->
        Logger.error("voxel_static_l0_start_failed reason=#{inspect(reason)}",
          event: :static_l0_start_failed, reason: reason, source: state.source)
        {:error, {:static_l0_start_failed, reason}}
    end
  end

  def start(state), do: {:ok, state}

  defp rejudge(record, context),
    do: %{record | core: core_result(record.source_only, record.materials, context)}

  @doc "原页任务交付摘要；来源事实不能把同代已修改页变回原生页。"
  def adopt(%{static_l0_retirement: true, resident: resident} = state, facts) when resident != :all,
    do: Enum.reduce(facts, state, &adopt_fact/2)
  def adopt(state, _facts), do: state

  defp adopt_fact({key, generation, fact}, state) do
    cond do
      generation != Map.get(state.page_generation, key, 0) ->
        reject(state, key, :stale_generation)

      fact != :recorded_page and fact.source != state.source_state.identity ->
        reject(state, key, :source_binding_mismatch)

      true ->
        old = Map.get(state.static_l0.cores, key)
        record = source_record(fact, old, generation, state.static_l0.context)
        state = state |> put_in([:static_l0, :cores, key], record) |> record_cost(fact)
        state = if record.core == :ok, do: state, else: revoke(state, [key])
        event(state, :adopt, key, record.core)
        resident(state, [key])
    end
  end

  defp reject(state, key, reason) do
    level = if reason == :source_binding_mismatch, do: :error, else: :warning
    Logger.log(level, "voxel_static_l0_rejected page=#{inspect(key)} reason=#{reason}",
      event: :static_l0_rejected, page: key, reason: reason)
    state
  end

  defp source_record(:recorded_page, _old, generation, _context), do: changed_record(generation)
  defp source_record(fact, old, generation, context) do
    source_only = old == nil or old.source_only
    %{source_only: source_only, core: core_result(source_only, fact.materials, context),
      materials: fact.materials, generation: generation, body: fact.body}
  end

  defp changed_record(generation) do
    %{source_only: false, core: :recorded_page, materials: [], body: nil, generation: generation}
  end

  defp core_result(false, _materials, _context), do: :recorded_page
  defp core_result(true, _materials, nil), do: :environment_not_admitted
  defp core_result(true, materials, context), do: StaticL0.core(materials, context)

  defp record_cost(state, :recorded_page), do: state
  defp record_cost(state, fact) do
    update_in(state.static_l0.metrics, fn metrics ->
      %{classified: metrics.classified + 1, generated: metrics.generated + fact.generated,
        classification_us: metrics.classification_us + fact.elapsed_us}
    end)
  end

  @doc "写入或恢复段即撤销原生资格；单元归属继续使用 Pages 的唯一投影。"
  def changed(%{resident: :all, static_l0: %{context: nil}} = state, _units), do: state
  def changed(%{static_l0_retirement: true} = state, units) do
    keys = for {0, _} = key <- Pages.units_pages(state, units), do: key
    state = Enum.reduce(keys, state, &mark_changed/2)
    revoke(state, keys)
  end
  def changed(state, _units), do: state

  defp mark_changed(key, state) do
    event(state, :invalidate, key, :recorded_page)
    if tracked?(state, key) do
      generation = Map.get(state.page_generation, key, 0)
      put_in(state.static_l0.cores[key], changed_record(generation))
    else
      state
    end
  end

  # 在线维护临时用 :all 表示已经读完；只撤销原有证明，不因此给全世界分配证明条目。
  defp tracked?(%{resident: :all} = state, key), do: Map.has_key?(state.static_l0.cores, key)
  defp tracked?(state, key) do
    Pages.resident?(state, key) or Map.has_key?(state.page_load.pending, key) or
      MapSet.member?(state.page_load.staged, key)
  end

  defp revoke(state, keys) do
    affected = MapSet.new(Pages.expand(keys))
    update_in(state.static_l0.eligible, &MapSet.difference(&1, affected))
  end

  @doc "页闭合并驻留后局部组合资格；邻页退休不改变已证明的物理事实。"
  def resident(state, keys) do
    for key <- keys, Pages.resident?(state, key), do: event(state, :resident, key, :page_admitted)
    refresh(state, keys)
  end

  defp refresh(%{static_l0_retirement: true, resident: resident} = state, keys) when resident != :all,
    do: Enum.reduce(Pages.expand(keys), state, &refresh_page/2)
  defp refresh(state, _keys), do: state

  # 驻留且尚无资格的页：本页和 26 邻页的 core 结论都为 :ok 才发证。邻页未驻留或无记录即不发（不递归装页去补证据）。
  defp refresh_page(key, state) do
    candidate? = Pages.resident?(state, key) and not MapSet.member?(state.static_l0.eligible, key)

    if candidate? and neighborhood_static?(state, key),
      do: update_in(state.static_l0.eligible, &MapSet.put(&1, key)),
      else: state
  end

  defp neighborhood_static?(state, key) do
    cores = Map.new(Pages.expand([key]), &{&1, admitted_core(state, &1)})
    StaticL0.neighborhood(key, cores) == :ok
  end

  defp admitted_core(state, key) do
    case state.static_l0.cores[key] do
      nil -> :unknown_neighbor
      record -> if Pages.resident?(state, key), do: record.core, else: :unadmitted_neighbor
    end
  end

  @doc """
  给 Thermal 的保留集合：所有驻留／暂存页里**没有**静态资格的页（未知、非静态、粗层）都作为 exact pin 保留。

  只做 exact，不再向外扩一圈邻页、也不把粗层祖页向下展开——资格本身已经包含了 26 邻页，再扩会白白吞掉覆盖率。
  全量驻留（`resident: :all`）时没有逐页资格：未发布的冷迁移态直接阻退，已发布时保留全部已装入页。
  """
  def required(%{resident: :all, page_store: %{published: nil}}), do: {:error, :static_l0_unpublished_restore}

  def required(%{resident: :all} = state) do
    loaded = MapSet.to_list(Pages.loaded_keys(state))
    tracked = Map.keys(state.static_l0.cores)
    staged = MapSet.to_list(state.page_load.staged)
    {:ok, Enum.uniq(loaded ++ tracked ++ staged)}
  end

  def required(state) do
    required =
      state.resident
      |> MapSet.union(state.page_load.staged)
      |> MapSet.difference(state.static_l0.eligible)

    {:ok, MapSet.to_list(required)}
  end

  @doc "取消／失败释放尚未接纳页的证明，不修改 canonical 内容。"
  def forget(%{static_l0_retirement: true} = state, keys) do
    update_in(state.static_l0, fn index ->
      %{index | cores: Map.drop(index.cores, Enum.to_list(keys)),
        eligible: MapSet.difference(index.eligible, MapSet.new(keys))}
    end)
  end
  def forget(state, _keys), do: state

  @doc "退休边界只释放派生证明；不撤销邻页已有资格，不创建业务事务。"
  def retire(state, keys) do
    Enum.each(keys, &event(state, :retire, &1, :requirements_released))
    forget(state, keys)
  end

  @doc "装页任务放弃尚未接纳的暂存；单独标为 discard，不混入退休验收计数。"
  def discard(state, keys) do
    Enum.each(keys, &event(state, :discard, &1, :load_not_admitted))
    forget(state, keys)
  end

  @doc """
  `World.residency_status/1` 的静态 L0 字段（周期采样器会调用，所以只做计数，不遍历堆估算内存）：

  - `static_l0_eligible`：当前有资格的页数；`static_l0_core_reasons`：各 core 结论（`:ok` 或拒绝原因）的页数；
  - `static_l0_unknown`：驻留 L0 中自身 core 合格或尚无记录、但邻域证据不全的页数（装页边缘的典型状态）；
  - `resident_by_level`：按层级的驻留页数；`static_l0_metrics`：累计分类页数、源生成次数与分类耗时。

  证明表的内存估算只在限定 debug 审计（`audit/4`）里计算，这里明确标为未采样。
  """
  def observe(state) do
    index = state.static_l0

    %{
      static_l0_enabled: state.static_l0_retirement,
      static_l0_binding: index.context && Base.encode16(index.context.binding, case: :lower),
      static_l0_eligible: MapSet.size(index.eligible),
      static_l0_core_reasons: Enum.frequencies_by(index.cores, fn {_, record} -> record.core end),
      static_l0_metrics: index.metrics,
      resident_by_level: resident_counts(state.resident),
      static_l0_unknown: awaiting_neighbors_count(state),
      static_l0_metadata_bytes: nil,
      static_l0_metadata_measurement: :debug_audit_only
    }
  end

  defp resident_counts(:all), do: :all
  defp resident_counts(resident), do: Enum.frequencies_by(resident, &elem(&1, 0))

  defp awaiting_neighbors_count(%{resident: :all}), do: :all

  defp awaiting_neighbors_count(state) do
    Enum.count(state.resident, fn key ->
      match?({0, _}, key) and not MapSet.member?(state.static_l0.eligible, key) and
        core_not_rejected?(state.static_l0.cores[key])
    end)
  end

  # 没有记录（尚未接纳）或 core 自身合格：不合格只是因为邻域证据还不全，而不是本页有风险。
  defp core_not_rejected?(nil), do: true
  defp core_not_rejected?(record), do: record.core == :ok

  @doc "变化事件交给限定验收的 Logger handler；常规 info 不产生逐页日志。"
  def event(state, action, key, reason) do
    Logger.debug(fn ->
      context = state.static_l0.context
      {"voxel_static_l0", static_l0_event: %{action: action, page_key: key, reason: reason,
        at_ns: System.monotonic_time(:nanosecond),
        generation: Map.get(state.page_generation, key, 0), binding: context && context.binding,
        seq: Map.get(state, :seq), published: get_in(state, [:page_store, :published]),
        triggering_request: Map.get(state.page_load.pending, key),
        thermal_due: Map.get(state, :thermal_due), liquid_due: Map.get(state, :liquid_due)}}
    end)
    :ok
  end

  @doc "debug 审计取得同一维护回合的精确集合及堆大小，供测试侧离线判断。"
  def audit(state, required, blocked, candidates) do
    Logger.debug(fn ->
      index = state.static_l0
      bytes = :erts_debug.flat_size({index.cores, index.eligible}) * :erlang.system_info(:wordsize)
      {"voxel_static_l0_maintenance", static_l0_event: %{action: :maintenance,
        seq: state.seq, published: state.page_store.published, resident: state.resident,
        staged: state.page_load.staged, eligible: index.eligible, cores: index.cores,
        required: required, persistence_blocked: blocked, retired: candidates, metadata_bytes: bytes}}
    end)
    :ok
  end
end
