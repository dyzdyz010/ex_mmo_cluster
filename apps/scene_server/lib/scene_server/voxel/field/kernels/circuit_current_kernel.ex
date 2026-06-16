defmodule SceneServer.Voxel.Field.Kernels.CircuitCurrentKernel do
  @moduledoc """
  Chunk-local automatic circuit kernel for source/load conductive loops.

  The kernel consumes only field-region source points plus projection-frozen
  conductor/source/load roles. When a conductive component contains a closed
  loop whose cyclic core includes at least one source point and one load
  participant, it writes:

    * `:electric_current` as the component current amplitude
    * `:electric_potential` as a hop-attenuated voltage gradient
    * `:ionization` as a derived channel-strength overlay

  Open conductors and dangling branches are cleared back to zero; this slice
  does not touch native code and stays fully chunk-local.

  Beyond the derived field layers, the kernel also emits `:set_tag` effects
  (功能完善 · 反应层 R7): every load participant that sits inside a closed,
  source-fed loop gains the `:powered` tag, and every other load in the region
  loses it. These effects flow through SystemActor → ChunkProcess and land on
  voxel truth (RULE-11/AUTH-11), giving devices an authoritative "energized"
  state to react to.
  """

  @behaviour SceneServer.Voxel.Field.Kernel

  alias SceneServer.Voxel.Field.{
    CircuitComponentAnalysis,
    FieldLayer,
    FieldRegion,
    KernelContext,
    ModelCard,
    ParticipantProjection
  }

  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.Storage

  @default_current_limit_amps MaterialCatalog.power_source_defaults().current_limit_amps
  @min_conductivity 0.001
  @base_ionization 32.0
  @current_ionization_scale 12.0
  @potential_ionization_scale 0.1

  # S1 正交架构(电磁):闭环载流的耗散元件按 I²R 产热。单 voxel 热源经守恒扩散均摊进 field 热网格,
  # 需较大增益才 gameplay 可见(同 R6d 电热洞察),定性档 game-feel,playtesting 可调。
  # heat_per_tick = I² · electric_resistance(Ω) · @joule_heat_gain。
  @joule_heat_gain 5000.0

  @impl true
  def kernel_id, do: :circuit_current

  @impl true
  def required_layers(_opts), do: [:electric_potential, :ionization, :electric_current]

  @impl true
  def model_card do
    ModelCard.new!(
      kernel_id: :circuit_current,
      fidelity_class: :qualitative,
      model_version: 1,
      safety_valve: %{
        type: :current_limit,
        current_limit_amps: @default_current_limit_amps,
        note:
          "电源 current_limit_amps 限流;电流/电位/离子化派生,负载 :powered 经 SystemActor 落权威(RULE-11/AUTH-11)"
      },
      description: "闭环电流重建(电导图分量分析)+ 电流驱动离子化(派生)+ 闭环驱动负载 :powered(派生→权威)",
      assumptions: ["macro-cell 电导图近似", "稳态闭环电流近似", "chunk-local"]
    )
  end

  @impl true
  def tick(%FieldRegion{} = region, %KernelContext{} = context, opts) when is_map(opts) do
    projection = participant_projection(context, opts)
    components = CircuitComponentAnalysis.active_circuit_components(region, projection)

    {current_layer, potential_layer, ionization_layer} =
      empty_layers(region)
      |> energize_components(components, projection, opts)

    # 功能完善 · 反应层 R7:闭环电流驱动负载——把闭合回路中的 load cell 标 :powered(权威 truth),
    # 其余 region 内 load 去 :powered(断路即失电)。经 SystemActor set_tag 落 truth,作设备激活基础。
    power_effects = power_load_effects(region, components, projection)

    # S1 正交架构(电磁):闭环载流负载按 I²R 产热(注入已有 temperature 注热原语)。发热作为「载流 ×
    # 电阻」的物理后果涌现——高电阻负载(发热元件)热、零电阻负载(门等机械执行器)不热——替代了凭空
    # 断言的 powered_heater 规则。
    heat_effects = joule_heat_effects(components, projection, opts, context)

    {:cont,
     region
     |> FieldRegion.put_layer(:electric_current, current_layer)
     |> FieldRegion.put_layer(:electric_potential, potential_layer)
     |> FieldRegion.put_layer(:ionization, ionization_layer), power_effects ++ heat_effects}
  end

  # 闭环载流负载的 I²R 焦耳热:对每个闭合回路,按其电流 I 对回路内每个有 electric_resistance>0 的
  # load cell 发 I²·R·gain 的连续注热(经 SystemActor always-commit → ChunkProcess → temperature truth)。
  defp joule_heat_effects(components, projection, opts, %KernelContext{storage: storage}) do
    Enum.flat_map(components, fn component ->
      current = component_current_amps(component, projection, opts, source_voltage(component))

      if current <= 0.0 do
        []
      else
        component.closed_loop_macro_indices
        |> Enum.filter(&ParticipantProjection.electric_role?(projection, &1, :load))
        |> Enum.flat_map(fn macro_index ->
          resistance = cell_electric_resistance(storage, macro_index)

          if resistance > 0.0 do
            joules = current * current * resistance * @joule_heat_gain

            [
              {:write_voxel_attribute,
               %{attribute: :temperature, macro_index: macro_index, heat_energy_joules: joules}}
            ]
          else
            []
          end
        end)
      end
    end)
  end

  defp cell_electric_resistance(storage, macro_index) when is_map(storage) do
    case Storage.normal_block_at(storage, macro_index) do
      %{material_id: material_id} ->
        MaterialCatalog.default_attribute_value(material_id, "electric_resistance", 0) /
          MaterialCatalog.fixed32_scale()

      _other ->
        0.0
    end
  end

  defp cell_electric_resistance(_storage, _macro_index), do: 0.0

  defp power_load_effects(%FieldRegion{} = region, components, projection) do
    powered =
      components
      |> Enum.flat_map(& &1.closed_loop_macro_indices)
      |> MapSet.new()

    region
    |> load_cells(projection)
    |> Enum.map(fn macro_index ->
      if MapSet.member?(powered, macro_index) do
        {:set_tag, %{macro_index: macro_index, add: [:powered], remove: []}}
      else
        {:set_tag, %{macro_index: macro_index, add: [], remove: [:powered]}}
      end
    end)
  end

  defp load_cells(%FieldRegion{aabb: {{min_x, min_y, min_z}, {max_x, max_y, max_z}}}, projection) do
    for x <- min_x..max_x,
        y <- min_y..max_y,
        z <- min_z..max_z,
        macro_index = SceneServer.Voxel.Types.macro_index!({x, y, z}),
        ParticipantProjection.electric_role?(projection, macro_index, :load) do
      macro_index
    end
  end

  defp energize_components(
         {current_layer, potential_layer, ionization_layer},
         components,
         projection,
         opts
       ) do
    Enum.reduce(components, {current_layer, potential_layer, ionization_layer}, fn component,
                                                                                   layers ->
      write_component(layers, component, projection, opts)
    end)
  end

  defp write_component(
         {current_layer, potential_layer, ionization_layer},
         component,
         projection,
         opts
       ) do
    voltage = source_voltage(component)
    distances = bfs_distances(component.segment_graph, component.source_segment_ids)

    max_distance =
      component.closed_loop_segment_ids
      |> Enum.map(&Map.get(distances, &1, 0))
      |> Enum.max(fn -> 0 end)

    current_amps = component_current_amps(component, projection, opts, voltage)

    component.closed_loop_segment_ids
    |> Enum.map(&Map.fetch!(component.segments, &1))
    |> Enum.reduce({current_layer, potential_layer, ionization_layer}, fn segment,
                                                                          {current_acc,
                                                                           potential_acc,
                                                                           ionization_acc} ->
      hop = Map.get(distances, segment.id, max_distance)
      attenuation = attenuation_for(hop, max_distance)
      potential = voltage * attenuation

      ionization =
        min(
          255.0,
          @base_ionization + current_amps * @current_ionization_scale +
            abs(potential) * @potential_ionization_scale
        )

      {
        put_max(current_acc, segment.macro_index, current_amps),
        put_max_abs(potential_acc, segment.macro_index, potential),
        put_max(ionization_acc, segment.macro_index, ionization)
      }
    end)
  end

  defp component_current_amps(component, projection, opts, voltage) do
    avg_conductivity =
      component.closed_loop_macro_indices
      |> Enum.map(
        &ParticipantProjection.electric_attribute(projection, &1, "electric_conductivity", 0.0)
      )
      |> average()

    current_limit_amps = current_limit_amps(opts)

    effective_resistance =
      max(length(component.closed_loop_segment_ids), 1) / max(avg_conductivity, @min_conductivity)

    min(current_limit_amps, abs(voltage) / max(effective_resistance, 1.0))
  end

  defp source_voltage(component) do
    component.source_points
    |> Enum.max_by(fn source_point -> abs(source_point.value * 1.0) end, fn -> %{value: 0.0} end)
    |> Map.get(:value, 0.0)
    |> Kernel.*(1.0)
  end

  defp current_limit_amps(opts) do
    case option(opts, :current_limit_amps, @default_current_limit_amps) do
      value when is_integer(value) and value > 0 -> value * 1.0
      value when is_float(value) and value > 0 -> value
      _other -> @default_current_limit_amps
    end
  end

  defp participant_projection(%KernelContext{storage: storage}, opts) do
    case option(opts, :participant_projection, nil) do
      %ParticipantProjection{} = projection -> projection
      _other when is_map(storage) -> ParticipantProjection.build(storage)
      _other -> %ParticipantProjection{}
    end
  end

  defp empty_layers(region) do
    {
      region |> FieldRegion.get_layer(:electric_current) |> clear_layer_in_aabb(region.aabb),
      region |> FieldRegion.get_layer(:electric_potential) |> clear_layer_in_aabb(region.aabb),
      region |> FieldRegion.get_layer(:ionization) |> clear_layer_in_aabb(region.aabb)
    }
  end

  defp clear_layer_in_aabb(layer, {{min_x, min_y, min_z}, {max_x, max_y, max_z}}) do
    Enum.reduce(
      for(x <- min_x..max_x, y <- min_y..max_y, z <- min_z..max_z, do: {x, y, z}),
      layer,
      fn coord, acc ->
        FieldLayer.put(acc, SceneServer.Voxel.Types.macro_index!(coord), 0.0)
      end
    )
  end

  defp bfs_distances(graph, source_segment_ids) do
    initial_queue = Enum.map(source_segment_ids, &{&1, 0})
    do_bfs_distances(initial_queue, graph, %{})
  end

  defp do_bfs_distances([], _graph, distances), do: distances

  defp do_bfs_distances([{segment_id, hop} | rest], graph, distances) do
    if Map.has_key?(distances, segment_id) do
      do_bfs_distances(rest, graph, distances)
    else
      neighbors =
        graph
        |> Map.get(segment_id, MapSet.new())
        |> MapSet.to_list()
        |> Enum.map(&{&1, hop + 1})

      do_bfs_distances(rest ++ neighbors, graph, Map.put(distances, segment_id, hop))
    end
  end

  defp attenuation_for(_hop, 0), do: 1.0
  defp attenuation_for(hop, max_distance), do: (max_distance - hop + 1) / (max_distance + 1)

  defp put_max(layer, macro_index, value) do
    FieldLayer.put(layer, macro_index, max(FieldLayer.get(layer, macro_index), value))
  end

  defp put_max_abs(layer, macro_index, value) do
    current = FieldLayer.get(layer, macro_index)

    if abs(value) > abs(current) do
      FieldLayer.put(layer, macro_index, value)
    else
      layer
    end
  end

  defp average([]), do: 0.0
  defp average(values), do: Enum.sum(values) / length(values)

  defp option(opts, key, default) do
    cond do
      Map.has_key?(opts, key) -> Map.fetch!(opts, key)
      Map.has_key?(opts, Atom.to_string(key)) -> Map.fetch!(opts, Atom.to_string(key))
      true -> default
    end
  end
end
