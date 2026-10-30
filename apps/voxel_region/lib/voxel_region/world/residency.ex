defmodule VoxelRegion.World.Residency do
  @moduledoc """
  单 World 的页驻留生命周期。需求只由观察、准备和真实活动 owner 的现有闭包派生；
  已发布页在最后需求释放后退休内存表示，持久真值与定位行不删除。
  未发布切点和当前脏单元共同阻止退休；未知活动依赖显式保留，不按窗口猜测活动资格。
  """
  require Logger
  alias VoxelRegion.CollisionSource
  alias VoxelRegion.World.{Casting, Liquids, PageLoad, Pages, Projectiles, SimulationWindows, Thermal}

  @doc "World 构造时的派生维护状态；不保存第二份页内容或活动真值。"
  def new, do: %{wanted: false, retired_pages: 0, last: %{status: :idle}}

  @doc "合法生命周期边界请求一次维护，同回合多次请求合并。"
  def request(state), do: put_in(state.residency.wanted, true)

  @doc "当前需求闭包及各原因页数；身份闭包使用现有home、整树covers和附件归属。"
  def required(state) do
    # 显式阻退先于观察／准备的整树闭包，避免明知不能退休仍分配临时页集合。
    # 各 owner 只计算一次；天然活动资格仍由 Thermal 唯一维护。
    with {:thermal, {:ok, thermal}} <- {:thermal, Thermal.residency_dependencies(state)},
         {:preparing, {:ok, preparing}} <- {:preparing, PageLoad.residency_dependencies(state)},
         {:liquid, {:ok, liquid}} <- {:liquid, Liquids.residency_dependencies(state)},
         {:projectiles, {:ok, projectiles}} <- {:projectiles, Projectiles.residency_dependencies(state)},
         {:casting, {:ok, casting}} <- {:casting, Casting.residency_dependencies(state)} do
      boxes = Map.values(state.canonical_subs) ++ Map.values(state.replica_subs)
      observations = {Enum.flat_map(boxes, fn box -> Enum.map(CollisionSource.regions(box), &{0, &1}) end),
        Enum.map(SimulationWindows.pages(state.simulation_windows), &{0, &1}), []}
      inputs = :queue.to_list(state.input_ready) ++ if(state.input_current, do: [state.input_current], else: [])
      ready = Enum.map(inputs, &PageLoad.input_dependencies(state, &1))
      sources = [observation: observations, preparing: preparing, ready: ready,
        thermal: thermal, liquid: liquid, projectiles: projectiles, casting: casting]

      Enum.reduce_while(sources, {:ok, MapSet.new(), %{}}, fn
        {owner, needs}, {:ok, pages, reasons} ->
          case project(state, needs) do
            {:ok, :all} -> {:halt, {:ok, :all, Map.put(reasons, owner, :all)}}
            {:ok, keys} -> {:cont, {:ok, MapSet.union(pages, keys), Map.put(reasons, owner, MapSet.size(keys))}}
            {:error, reason} -> {:halt, {:error, {owner, reason}}}
          end
      end)
    else
      {owner, {:error, reason}} -> {:error, {owner, reason}}
    end
  end

  defp project(_state, :none), do: {:ok, MapSet.new()}
  defp project(_state, :all), do: {:ok, :all}
  defp project(state, needs) when is_list(needs) do
    Enum.reduce_while(needs, {:ok, MapSet.new()}, fn need, {:ok, pages} ->
      case project(state, need) do
        {:ok, :all} -> {:halt, {:ok, :all}}
        {:ok, keys} -> {:cont, {:ok, MapSet.union(pages, keys)}}
        error -> {:halt, error}
      end
    end)
  end
  defp project(state, {keys, exact, ids}), do: Pages.residency_closure(state, Pages.expand(keys) ++ exact, ids)

  @doc "只投影一次维护结果，不导出canonical页、逐槽或全state。"
  def observe(state), do: Map.merge(state.residency.last, %{retired_pages: state.residency.retired_pages,
    generation_pages: map_size(state.page_generation), preparations: map_size(state.page_load.preparations)})

  @doc "有维护请求时在当前World合法回合中固定退休和generation，再开放后续输入。"
  def maintain(%{residency: %{wanted: false}} = state), do: state
  def maintain(state), do: maintain_now(put_in(state.residency.wanted, false))

  defp maintain_now(state) do
    with {:ok, required, reasons} when required != :all <- required(state),
         {:ok, blocked} <- Pages.residency_closure(state, persistence_pages(state), []) do
      # 全量迁移只在首个已发布边界转为有限页集；其后一直由装页owner登记。
      resident = if state.resident == :all, do: MapSet.union(Pages.loaded_keys(state), required), else: state.resident
      candidates = resident |> MapSet.union(state.page_load.staged) |> MapSet.difference(required) |> MapSet.difference(blocked)
      state = %{state | resident: resident}
      count = MapSet.size(candidates)
      state = if count == 0, do: state, else: state |> Pages.retire(candidates) |> Thermal.release_residency(candidates)
      if count > 0, do: Logger.info("voxel_page_retire pages=#{count} resident=#{MapSet.size(state.resident)} published=#{state.page_store.published}")
      %{state | residency: %{state.residency | retired_pages: state.residency.retired_pages + count,
        last: %{status: :ready, required_pages: MapSet.size(required), reasons: reasons,
          persistent_blocked_pages: MapSet.size(blocked), retired_last: count, resident_pages: MapSet.size(state.resident)}}}
    else
      {:ok, :all, reasons} -> put_in(state.residency.last, %{status: :blocked, reason: :all_required, reasons: reasons})
      {:error, reason} ->
        reason = inspect(reason)
        # last只记录当前维护结果：连续同因不重复告警，恢复或原因变化后重新记录。
        unless match?(%{status: :blocked, reason: ^reason}, state.residency.last),
          do: Logger.warning("voxel_page_retire_blocked reason=#{reason}")
        put_in(state.residency.last, %{status: :blocked, reason: reason})
    end
  end

  # 当前dirty和未发布cut各自拥有同一页内容的未持久版本；cut清空前不能将dirty=[]当持久确认。
  defp persistence_pages(state) do
    frozen = case state.page_store.cut do nil -> []; cut -> Pages.units_pages(cut.frozen, cut.units) end
    Enum.uniq(Pages.units_pages(state, Pages.dirty(state)) ++ frozen)
  end

end
