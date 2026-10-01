defmodule VoxelRegion.World.Catalogs do
  @moduledoc """
  全局系统功能：目录与环境加载：属性、魔法、热环境、发布与损伤目录校验。

  由 `VoxelRegion.World` 拆出的状态函数：输入与返回都是 World 状态，真值归属与调用时机仍由 World 决定。
  """
  require Logger
  alias VoxelRegion.Damage
  alias VoxelRegion.Magic
  alias VoxelRegion.World.Thermal
  alias VoxelRegion.World.{Observation, Log, Liquids, AttachmentOps}

  def load_properties(opts) do
    case Keyword.get(
           opts,
           :property_catalog_path,
           Application.get_env(:voxel_region, :property_catalog_path)
         ) do
      nil -> nil
      path -> Damage.load(path)
    end
  end

  def load_magic(opts) do
    case Keyword.get(opts, :magic_catalog_path, Application.get_env(:voxel_region, :magic_catalog_path)) do
      nil -> nil
      path -> Magic.Catalog.load(path)
    end
  end

  # 全局系统功能：平衡容差是求解分辨率，辐射参数与电路零功率阈值随各自变更引入、旧存档没有，均以环境资产为准；
  # 回放的热账（环境温度、换热系数、能量账）保持存档值。
  # 气候区同理以资产为准：资产没有该字段时回放后也没有（与引入前的配置逐字节相同）。
  def environment_tolerance(%{thermal: %{config: config} = thermal} = state, %{config: asset}),
    do: %{state | thermal: %{thermal | config: config
      |> Map.merge(Map.take(asset, ~w(tolerance_kelvin emissivity view_range_cells circuit_min_power_w climate_zones)))
      |> then(&if(Map.has_key?(asset, "climate_zones"), do: &1, else: Map.delete(&1, "climate_zones")))}}

  def environment_tolerance(state, _), do: state

  # 辐射环境字段必须显式发布：发射率 ∈ [0, 1]（0 = 关闭辐射），视距为正整数宏格。
  def radiation_config?(config) do
    is_number(config["emissivity"]) and config["emissivity"] >= 0 and config["emissivity"] <= 1 and
      is_integer(config["view_range_cells"]) and config["view_range_cells"] > 0
  end

  # 全局环境不包含测试源；玩家设施只从已经支付的燃料获得能量。
  def load_thermal_environment(opts) do
    case Keyword.get(
           opts,
           :thermal_environment_path,
           Application.get_env(:voxel_region, :thermal_environment_path)
         ) do
      nil ->
        nil

      path ->
        config =
          Jason.decode!(File.read!(path))
          |> Map.take(~w(ambient_kelvin environment_w_per_m2_k tolerance_kelvin emissivity view_range_cells
            circuit_min_power_w climate_zones))

        # circuit_min_power_w：电路零功率判据（W），电源输出功率低于它的连通网络视为断流（`VoxelRegion.Circuit`）。
        true =
          Enum.all?(
            ~w(ambient_kelvin environment_w_per_m2_k tolerance_kelvin circuit_min_power_w),
            &is_number(config[&1])
          ) and config["circuit_min_power_w"] >= 0 and
            config["ambient_kelvin"] > 0 and config["environment_w_per_m2_k"] >= 0 and
            config["tolerance_kelvin"] > 0 and radiation_config?(config) and
            VoxelRegion.Climate.valid?(config)

        %{
          config: config,
          sources: %{},
          elapsed_s: 0.0,
          supplied_j: 0.0,
          environment_j: 0.0,
          combustion_j: 0.0,
          combustion_removed_j: 0.0,
          active: false
        }
    end
  end

  # 参数只改变下一次计算；实例温度、HP、源预算与相变焓不改写；
  # 已点燃行的余燃料与功率由调用方按新目录保比例重标后传入。
  # 复用既有同步落盘后广播边界；失败时目录与所有实例状态一起保持旧值。
  # migration：退役设备迁移后的附件槽、改了材料的槽（其区域 afterimage 同笔写出）与旧槽热行的删除记录。
  def publish_property_catalog(state, catalog, thermal, damage, migration) do
    if state.properties.digest == catalog.digest do
      {:reply, :ok, Liquids.enable_liquid(state, Thermal.rebuild_work(%{state | properties: catalog}))}
    else
      rows = for {_, t} <- damage,
        do: %{t | digest: catalog.digest, seq: state.seq + 1, request_id: 0}
      tombstones = for t <- migration.tombstones,
        do: %{t | digest: catalog.digest, seq: state.seq + 1, request_id: 0, flags: 1}
      next = %{state | properties: catalog, thermal: thermal, seq: state.seq + 1, attachments: migration.attachments,
        damage: Map.new(rows, &{Damage.key(&1), &1})} |> Thermal.rebuild_work()
      # 步进参数或散体休止阈值改变：全部有限格重新接受新参数的平衡（只改下一步，不改已提交数量）。
      next = if state.properties.liquid != catalog.liquid or loose_thresholds(state.properties) != loose_thresholds(catalog),
        do: Liquids.wake_liquid(next, Map.keys(next.liquid_units)), else: next
      {txn, keys, next} = if migration.slots == [],
        do: {%{seq: next.seq, entries: [], coarse: []}, [], next},
        else: AttachmentOps.attachment_geometry(state, next, migration.slots)
      txn = Map.merge(txn, %{property_states: tombstones ++ rows, thermal: thermal})
      case Log.append_log(next, txn) do
        :ok ->
          next = Log.remember_entry(next, txn)
          Observation.fanout(next, txn)
          Observation.fanout_canonical(next, txn, [], keys, state)
          Logger.info("voxel_parameter_publication seq=#{next.seq} retired_slots=#{length(migration.slots)} old=#{Base.encode16(state.properties.digest, case: :lower)} new=#{Base.encode16(catalog.digest, case: :lower)} rebase_j=#{if thermal, do: Map.get(thermal, :parameter_rebase_j, 0.0), else: 0.0} fuel_rebase_j=#{if thermal, do: Map.get(thermal, :fuel_rebase_j, 0.0), else: 0.0}")
          {:reply, :ok, Liquids.schedule_liquid(Liquids.enable_liquid(state, next))}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end
  end

  def loose_thresholds(catalog),
    do: for({id, m} <- catalog.materials, Map.has_key?(m, "loose_threshold_units"), into: %{}, do: {id, m["loose_threshold_units"]})

  def validate_damage_catalog(state) do
    if map_size(state.damage) > 0 do
      true =
        state.properties != nil and
          Enum.all?(state.damage, fn {_, t} -> t.digest == state.properties.digest end)
    end
  end
end
