defmodule VoxelRegion.World.StaticL0 do
  @moduledoc """
  静态 L0 资格的纯规则：判断一个天然 L0 页能否在无人读取时从 World 内存退掉（降低 GeneratedStore 世界的常驻内存）。

  一页“静态”指：它和 26 个邻页的完整 64³ core 都没有任何记录，且其中每种源材料在当前固定均匀环境下都没有驱动力
  （雪冰液体一律不算；可燃物低于点燃温度；可相变固体处于稳定相）。粗层永不发证。规则只认完整证明，
  “空活动集”“未编辑”“可以重新生成”都不能单独代替。

  开关是 `VOXIM_STATIC_L0_RETIREMENT=true`，重启生效；证明的接纳与失效由 `StaticL0.Index` 维护。
  不支持的环境会以 `voxel_static_l0_start_failed` 日志给出原因并阻止 World 启动。
  """
  alias VoxelRegion.{Combustion, Phase, Transform, Circuit, GeneratedStore}
  alias VoxelRegion.World.Pages
  alias MmoContracts.Voxel.Payload

  # 规则版本参与证明绑定；资格规则语义变化时递增，旧证明自然不再匹配。
  @rule 1
  @double_epsilon 2.220446049250313e-16
  # 雪、冰即使处在低温也按已批准的首版范围保留；时变气候下的资格留给 Weather。
  @cold_solids for %{"id" => id, "name" => name} <- MmoContracts.VoxelMaterialCatalog.table(),
                  name in ["snow", "ice"], do: id
  # 载荷有一格 ring，证明只读取 core；ring 的事实由它真正所属页的完整 core 证明。
  @ring_width 1
  @core_edge Payload.extent() - 2 * @ring_width
  # VXR4 的 cells 每格是小端 u16 材料 id。
  @material_bits 16
  @material_bytes div(@material_bits, 8)
  @core_row_bytes @core_edge * @material_bytes
  # 资格依赖的热环境字段；这些字段的任何在线变化都必须走维护重启（见 change_error/2）。
  @environment ~w(ambient_kelvin environment_w_per_m2_k tolerance_kelvin emissivity view_range_cells circuit_min_power_w climate_zones)
  # 本规则理解这些已发布字段的默认语义；未来目录扩展必须重新审查，不按材料黑名单猜测。
  @fields ~w(material_id display_name tags responses defense max_hp_per_macro density_kg_m3
    heat_capacity_per_macro thermal_conductivity heat_resistance_kelvin ignition_kelvin
    fuel_energy_per_macro_j burn_power_per_macro_w phase_peer_material_id phase_transition_kelvin
    latent_heat_per_macro_j transform_material_id transform_kelvin transform_heat_per_macro_j
    transform_reductant_material_id transform_reductant_units_per_unit electrical_conductivity
    electrical_cutoff_kelvin battery_energy_per_macro_j battery_volts_per_m circuit_switch
    seebeck_v_per_k luminous_fraction loose_threshold_units place_units drops food recipe_inputs
    recipe_units beacon_anchor)

  @doc "仅在 World 合并存档与资产之后绑定最终环境；不支持的开启配置显式失败。"
  def context(%{
        source: GeneratedStore,
        source_state: source,
        properties: %{digest: digest, materials: materials},
        thermal: %{config: config}
      }) do
    cond do
      Map.get(config, "climate_zones", []) != [] ->
        {:error, :static_l0_nonuniform_environment}

      config["view_range_cells"] > @core_edge ->
        {:error, :static_l0_read_footprint_exceeds_halo}

      true ->
        environment = Map.take(config, @environment)

        binding =
          :crypto.hash(
            :sha256,
            :erlang.term_to_binary({@rule, source.identity, digest, environment})
          )

        {:ok,
         %{
           binding: binding,
           source: source.identity,
           catalog_digest: digest,
           environment: environment,
           material_results:
             Map.new(materials, fn {id, _} ->
               {id, material(id, materials, config["ambient_kelvin"])}
             end),
           ambient: config["ambient_kelvin"],
           rule: @rule
         }}
    end
  end

  def context(_), do: {:error, :static_l0_unsupported_source_or_environment}

  @doc "参数变更在任何装页、写回或记账前拒绝；相同环境的有限热源仍可进入正常入口。"
  def change_error(%{static_l0_retirement: true, static_l0: %{context: context}}, message)
      when context != nil do
    changed =
      case message do
        {:publish_properties, catalog} ->
          catalog.digest != context.catalog_digest

        {:publish_parameters, catalog, _expected} ->
          catalog.digest != context.catalog_digest

        {:thermal_experiment, experiment} ->
          Map.merge(context.environment, Map.take(experiment, @environment)) !=
            context.environment

        _ ->
          false
      end

    if changed, do: :static_l0_environment_change_requires_maintenance
  end

  def change_error(_, _), do: nil

  @doc "已验证的完整 66³ 材料段只提取 64³ core 的材料集合；不把 ring 归本页。"
  def core_materials(cells) do
    for z <- @ring_width..@core_edge, y <- @ring_width..@core_edge, reduce: MapSet.new() do
      materials ->
        row = binary_part(cells, Payload.cell_index({@ring_width, y, z}) * @material_bytes, @core_row_bytes)
        row_materials(row, materials)
    end
    |> Enum.sort()
  end

  # 每页 64×64 行、每行 64 格。天然地形的大多数行整行同一材料（空气或岩层），先用一次二进制比较认出这种行，
  # 只有混合行才逐格累计；结果与逐格扫描完全相同，只是避免对 26 万格逐个插入集合（装页任务里串行执行，直接计入首次装页延迟）。
  defp row_materials(<<first::unsigned-little-integer-size(@material_bits), _::binary>> = row, materials) do
    uniform_row = :binary.copy(<<first::unsigned-little-integer-size(@material_bits)>>, @core_edge)

    if row == uniform_row do
      MapSet.put(materials, first)
    else
      for <<m::unsigned-little-integer-size(@material_bits) <- row>>, reduce: materials do
        acc -> MapSet.put(acc, m)
      end
    end
  end

  @doc "消费源完整材料摘要和已接纳物性；不重复解析几何。"
  def core(materials, context) do
    Enum.find_value(materials, :ok, fn id ->
      case Map.get(context.material_results, id, :unknown_material) do
        :ok -> nil
        reason -> reason
      end
    end)
  end

  @doc "默认满格、无属性／数量／供热记录的单材料资格；浮点仅容许运算舍入。"
  def material(id, _materials, _ambient) when id in @cold_solids, do: :material_risk

  def material(id, materials, ambient) do
    # 液体的流动不能用空前沿或静止表面排除；液态身份由 Phase 单独维护。
    if Phase.liquid?(id), do: :material_risk, else: default_material(id, materials, ambient)
  end

  defp default_material(id, materials, ambient) do
    case Map.fetch(materials, id) do
      :error ->
        :unknown_material

      {:ok, m} ->
        cond do
          Enum.any?(Map.keys(m), &(&1 not in @fields)) ->
            :unknown_material_semantics

          Circuit.battery?(m) ->
            :material_risk

          is_number(m["heat_resistance_kelvin"]) and ambient >= m["heat_resistance_kelvin"] ->
            :material_risk

          Combustion.combustible?(m) and ambient >= Combustion.properties(m).ignition_kelvin ->
            :material_risk

          Transform.enabled?(m) and ambient >= m["transform_kelvin"] ->
            :material_risk

          Phase.enabled?(m) ->
            phase(id, m, materials, ambient)

          true ->
            :ok
        end
    end
  end

  defp phase(id, m, materials, ambient) do
    energy = Phase.energy(%{material: id}, 1.0, m, ambient)
    temperature = Phase.temperature(id, energy, 1.0, materials)

    transition = m["phase_transition_kelvin"]
    # 焓→温度往返经过约四次 double 运算，只容许这几次运算的舍入误差；这不是热系统的 1 K 静止容差，
    # 用它放行会把“略有温差、其实会导热”的材料误判为静态。
    rounding = 4 * @double_epsilon * max(abs(ambient), abs(transition))

    below_transition? = ambient < transition
    at_ambient? = abs(temperature - ambient) <= rounding
    keeps_material? = Phase.material(id, energy, 1.0, materials) == id

    if below_transition? and at_ambient? and keeps_material?, do: :ok, else: :material_risk
  end

  @doc "27 个 core 的单层组合；没有递归资格要求，粗层恒不发证。"
  def neighborhood({0, _} = key, cores) do
    reasons = Enum.map(Pages.expand([key]), &Map.get(cores, &1, :unknown_neighbor))
    Enum.find(reasons, :ok, &(&1 != :ok))
  end

  def neighborhood(_, _cores), do: :coarse_page
end
