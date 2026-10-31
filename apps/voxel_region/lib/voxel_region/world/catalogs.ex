defmodule VoxelRegion.World.Catalogs do
  @moduledoc """
  全局系统功能：目录与环境加载：属性、魔法、热环境、发布与损伤目录校验。

  由 `VoxelRegion.World` 拆出的状态函数：输入与返回都是 World 状态，真值归属与调用时机仍由 World 决定。
  """
  require Logger
  alias VoxelRegion.Damage
  alias VoxelRegion.{Climate, GeneratedStore}
  alias VoxelRegion.Climate.Source
  alias VoxelRegion.Magic
  alias VoxelRegion.World.Thermal
  alias VoxelRegion.World.{Observation, Log, Liquids, AttachmentOps}

  @snow_material MmoContracts.VoxelMaterialCatalog.table()
    |> Enum.find_value(fn %{"id" => id, "name" => name} -> if name == "snow", do: id end)
  @solver_fields ~w(tolerance_kelvin emissivity view_range_cells circuit_min_power_w)

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

  @doc "组合边界接纳生成气候；恢复须与资产同身份，既有热账保留，只更新求解分辨率参数。"
  def environment_tolerance(state, %{config: asset}) do
    with {:ok, state} <- accept_generated_climate(state, asset) do
      case state.thermal do
        %{config: config} = thermal ->
          config = Map.merge(config, Map.take(asset, @solver_fields))
          # 旧手工气候区沿用历史资产合同；新生成源已经一次接纳，不能由区表覆盖。
          config =
            if Map.has_key?(config, "climate_source") do
              config
            else
              if Map.has_key?(asset, "climate_zones"),
                do: Map.put(config, "climate_zones", asset["climate_zones"]),
                else: Map.delete(config, "climate_zones")
            end
          {:ok, %{state | thermal: %{thermal | config: config}}}

        nil ->
          {:ok, state}
      end
    end
  end

  def environment_tolerance(state, nil) do
    if climate_source(state), do: {:error, :climate_migration_required}, else: {:ok, state}
  end

  defp accept_generated_climate(state, asset) do
    previous = climate_source(state)

    case Map.fetch(asset, "generated_climate") do
      :error ->
        if previous, do: {:error, :climate_migration_required}, else: {:ok, state}

      {:ok, parameters} ->
        with {:ok, source} <- generated_source(state, parameters),
             {:ok, config} <- Climate.bind(Map.delete(asset, "generated_climate"), source),
             :ok <- accept_identity(state, previous, source),
             :ok <- accept_initial_preset(state, previous, source) do
          if previous,
            do: {:ok, state},
            else: {:ok, %{state | thermal: %{state.thermal | config: config}}}
        end
    end
  end

  defp generated_source(%{source: GeneratedStore, source_state: store}, parameters),
    do: GeneratedStore.climate_source(store, parameters)
  defp generated_source(_, _), do: {:error, :generated_climate_requires_generated_store}

  defp climate_source(%{thermal: %{config: config}}), do: Map.get(config, "climate_source")
  defp climate_source(_), do: nil

  defp accept_identity(%{seq: 0, page_store: %{published: nil}}, nil, _), do: :ok
  defp accept_identity(_, %Source{identity: identity}, %Source{identity: identity}), do: :ok
  defp accept_identity(_, _, _), do: {:error, :climate_migration_required}

  # 这是默认新世界冷雪preset与当前材料的组合校验，不是通用Source的数值限制。
  defp accept_initial_preset(%{properties: %{materials: materials}}, nil,
      %Source{kelvin_config: {cold, _, _, _}}) do
    case Map.get(materials, @snow_material) do
      %{"phase_transition_kelvin" => transition} when cold < transition -> :ok
      _ -> {:error, :invalid_snow_climate_preset}
    end
  end
  defp accept_initial_preset(_, nil, _), do: {:error, :invalid_snow_climate_preset}
  defp accept_initial_preset(_, _, _), do: :ok

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
            circuit_min_power_w climate_zones generated_climate))

        # circuit_min_power_w：电路零功率判据（W），电源输出功率低于它的连通网络视为断流（`VoxelRegion.Circuit`）。
        true =
          Enum.all?(
            ~w(ambient_kelvin environment_w_per_m2_k tolerance_kelvin circuit_min_power_w),
            &is_number(config[&1])
          ) and config["circuit_min_power_w"] >= 0 and
            config["ambient_kelvin"] > 0 and config["environment_w_per_m2_k"] >= 0 and
            config["tolerance_kelvin"] > 0 and radiation_config?(config) and
            VoxelRegion.Climate.valid?(config)

        empty_thermal(config)
    end
  end

  @doc "空热账：环境配置、无热源、时钟与各账为 0、静止。环境资产加载与无热环境时的 Test-only 实验共用。"
  def empty_thermal(config),
    do: %{config: config, sources: %{}, elapsed_s: 0.0, supplied_j: 0.0, environment_j: 0.0, combustion_j: 0.0,
      combustion_removed_j: 0.0, active: false}

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
        damage: Map.new(rows, &{Damage.key(&1), &1})} |> VoxelRegion.World.Canonical.index_attachments() |> Thermal.rebuild_work()
      # 步进参数或散体休止阈值改变：全部有限格重新接受新参数的平衡（只改下一步，不改已提交数量）。
      next = if state.properties.liquid != catalog.liquid or loose_thresholds(state.properties) != loose_thresholds(catalog),
        do: Liquids.wake_liquid(next, Map.keys(next.liquid_units)), else: next
      {txn, keys, next} = if migration.slots == [],
        do: {%{seq: next.seq, entries: [], coarse: []}, [], next},
        else: AttachmentOps.attachment_geometry(state, next, migration.slots)
      txn = Map.merge(txn, %{property_states: tombstones ++ rows, thermal: thermal})
      case Log.append_log(state, next, txn) do
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
