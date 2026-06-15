defmodule SceneServer.Voxel.Field.Kernels.ElectricDischargeKernel do
  @moduledoc """
  Chunk-local dielectric breakdown and discharge kernel.

  This kernel models a short-lived electric discharge through matter or empty
  dielectric cells. It is intentionally not a lightning spell: callers provide
  an electric source and target, while the kernel decides whether the current
  storage snapshot can support a breakdown path from material conductivity,
  dielectric strength, and existing ionization.

  Persistent closed-loop current remains owned by `CircuitCurrentKernel`.
  Material-only conductor routing remains owned by `ConductionPathKernel`.
  """

  @behaviour SceneServer.Voxel.Field.Kernel

  alias SceneServer.Voxel.Field.{
    FieldLayer,
    FieldRegion,
    KernelContext,
    ModelCard,
    NativeBackend,
    ParticipantProjection
  }

  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  @fixed32_scale 65_536.0
  @default_conductivity 0.0
  @default_dielectric_strength 3.0
  @min_conductivity 0.001
  @conductive_cost_weight 0.5
  @dielectric_cost_weight 1.0
  @ionization_threshold_weight 0.05
  @ionization_cost_weight 0.01
  @min_step_cost 0.05
  @default_channel_ionization 240.0
  @default_temperature_rise_celsius 180.0
  @default_breakdown_damage 25
  @default_max_frontier 512
  @epsilon 0.000001

  @impl true
  def kernel_id, do: :electric_discharge

  @impl true
  def required_layers(_opts), do: [:electric_potential, :ionization]

  @impl true
  def model_card do
    ModelCard.new!(
      kernel_id: :electric_discharge,
      fidelity_class: :qualitative,
      model_version: 1,
      safety_valve: %{
        type: :frontier_budget,
        max_frontier: @default_max_frontier,
        note: "介质击穿 Dijkstra max_frontier 熔断;放电热/击穿伤害回写经 system_actor 桥(梯队3 step3.8/R8)"
      },
      description: "介质击穿放电路径(Dijkstra)+ 沿路径温度上升 + 击穿伤害(降 health 毁块);权威写回经 SystemActor",
      assumptions: ["macro-cell 击穿强度近似", "chunk-local", "固定温升模型", "击穿伤害仅实心 macro 块 health>0"]
    )
  end

  @doc """
  Computes the dielectric breakdown path that `tick/3` would write.

  Unlike `ConductionPathKernel.channel_path/6`, this preflight can traverse
  empty or low-conductivity cells when the source potential exceeds their
  effective dielectric threshold. That keeps discharge behavior as a physical
  field rule instead of a material-conductor shortcut.
  """
  @spec discharge_path(Storage.t(), non_neg_integer(), non_neg_integer(), term(), number(), map()) ::
          {:ok, [non_neg_integer()]} | {:error, atom()}
  def discharge_path(
        %Storage{} = storage,
        source_macro_index,
        target_macro_index,
        aabb,
        source_value,
        opts \\ %{}
      )
      when is_integer(source_macro_index) and is_integer(target_macro_index) and
             is_number(source_value) do
    region =
      FieldRegion.new(%{
        region_id: 0,
        chunk_coord: {0, 0, 0},
        aabb: aabb,
        kernels: [%{id: :electric_discharge, module: __MODULE__}],
        source_points: [
          %{macro_index: source_macro_index, field_type: :electric_potential, value: source_value}
        ]
      })

    with true <- in_aabb?(region, source_macro_index),
         true <- in_aabb?(region, target_macro_index) do
      find_path(region, storage, source_macro_index, target_macro_index, source_value, opts)
    else
      _ -> {:error, :target_outside_region}
    end
  end

  @impl true
  def tick(%FieldRegion{} = region, %KernelContext{} = context, opts) when is_map(opts) do
    with {:ok, target_macro_index} <- target_macro_index(opts),
         {:ok, source_macro_index, source_value} <- source_point(region),
         true <- in_aabb?(region, source_macro_index),
         true <- in_aabb?(region, target_macro_index),
         {:ok, path} <-
           find_path(
             region,
             context.storage,
             source_macro_index,
             target_macro_index,
             source_value,
             opts
           ) do
      {:cont, write_discharge_channel(region, path, source_value, opts),
       discharge_heat_effects(path, source_value, context, opts) ++
         discharge_damage_effects(path, context, opts)}
    else
      _ -> {:cont, refresh_empty_channel(region), []}
    end
  end

  defp find_path(
         region,
         %Storage{} = storage,
         source_macro_index,
         target_macro_index,
         source_value,
         opts
       ) do
    max_frontier =
      opts
      |> integer_opt(:max_frontier, @default_max_frontier)
      |> max(1)

    source_strength = abs(source_value * 1.0)
    ionization_layer = FieldRegion.get_layer(region, :ionization)

    NativeBackend.find_discharge_path(
      storage,
      region.aabb,
      source_macro_index,
      target_macro_index,
      source_value,
      ionization_layer,
      max_frontier,
      backend: path_backend(opts),
      fallback: fn ->
        elixir_find_path_with_preflight(
          region,
          storage,
          source_macro_index,
          target_macro_index,
          source_strength,
          ionization_layer,
          max_frontier
        )
      end
    )
  end

  defp find_path(
         _region,
         _storage,
         _source_macro_index,
         _target_macro_index,
         _source_value,
         _opts
       ),
       do: {:error, :no_discharge_path}

  defp elixir_find_path_with_preflight(
         region,
         storage,
         source_macro_index,
         target_macro_index,
         source_strength,
         ionization_layer,
         max_frontier
       ) do
    if traversable_cell?(storage, ionization_layer, source_macro_index, source_strength) and
         traversable_cell?(storage, ionization_layer, target_macro_index, source_strength) do
      elixir_find_path(
        region,
        storage,
        source_macro_index,
        target_macro_index,
        source_strength,
        ionization_layer,
        max_frontier
      )
    else
      {:error, :no_discharge_path}
    end
  end

  defp elixir_find_path(
         region,
         storage,
         source_macro_index,
         target_macro_index,
         source_strength,
         ionization_layer,
         max_frontier
       ) do
    queue = :gb_sets.singleton({0.0, source_macro_index})
    costs = %{source_macro_index => 0.0}

    dijkstra(queue, costs, %{}, MapSet.new(), 0, max_frontier, %{
      region: region,
      storage: storage,
      target: target_macro_index,
      source: source_macro_index,
      source_strength: source_strength,
      ionization_layer: ionization_layer
    })
  end

  defp dijkstra(queue, _costs, _previous, _settled, _frontier_count, _max_frontier, _env)
       when queue == [] do
    {:error, :empty_queue}
  end

  defp dijkstra(queue, costs, previous, settled, frontier_count, max_frontier, env) do
    cond do
      :gb_sets.is_empty(queue) ->
        {:error, :no_discharge_path}

      frontier_count >= max_frontier ->
        {:error, :frontier_exhausted}

      true ->
        {{current_cost, current_macro_index}, queue} = :gb_sets.take_smallest(queue)

        cond do
          MapSet.member?(settled, current_macro_index) ->
            dijkstra(queue, costs, previous, settled, frontier_count, max_frontier, env)

          current_macro_index == env.target ->
            {:ok, reconstruct_path(previous, env.source, current_macro_index)}

          current_cost > Map.fetch!(costs, current_macro_index) + @epsilon ->
            dijkstra(queue, costs, previous, settled, frontier_count, max_frontier, env)

          true ->
            settled = MapSet.put(settled, current_macro_index)

            {queue, costs, previous} =
              current_macro_index
              |> neighbor_indices(env.region)
              |> Enum.filter(
                &traversable_cell?(
                  env.storage,
                  env.ionization_layer,
                  &1,
                  env.source_strength
                )
              )
              |> Enum.reduce({queue, costs, previous}, fn neighbor_macro_index,
                                                          {queue_acc, costs_acc, prev_acc} ->
                step_cost =
                  step_cost(
                    env.storage,
                    env.ionization_layer,
                    neighbor_macro_index,
                    env.source_strength
                  )

                candidate_cost = current_cost + step_cost
                known_cost = Map.get(costs_acc, neighbor_macro_index, :infinity)

                if better_cost?(candidate_cost, known_cost) do
                  {
                    :gb_sets.add({candidate_cost, neighbor_macro_index}, queue_acc),
                    Map.put(costs_acc, neighbor_macro_index, candidate_cost),
                    Map.put(prev_acc, neighbor_macro_index, current_macro_index)
                  }
                else
                  {queue_acc, costs_acc, prev_acc}
                end
              end)

            dijkstra(queue, costs, previous, settled, frontier_count + 1, max_frontier, env)
        end
    end
  end

  defp better_cost?(_candidate, :infinity), do: true
  defp better_cost?(candidate, known), do: candidate + @epsilon < known

  defp reconstruct_path(_previous, source, source), do: [source]

  defp reconstruct_path(previous, source, target) do
    do_reconstruct_path(target, source, previous, [target])
  end

  defp do_reconstruct_path(source, source, _previous, acc), do: acc

  defp do_reconstruct_path(current, source, previous, acc) do
    case Map.fetch(previous, current) do
      {:ok, parent} -> do_reconstruct_path(parent, source, previous, [parent | acc])
      :error -> acc
    end
  end

  defp neighbor_indices(macro_index, region) do
    macro_index
    |> Types.macro_coord!()
    |> neighbors_of(region)
    |> Enum.map(&Types.macro_index!/1)
    |> Enum.sort()
  end

  defp neighbors_of({x, y, z}, region) do
    [
      {x - 1, y, z},
      {x + 1, y, z},
      {x, y - 1, z},
      {x, y + 1, z},
      {x, y, z - 1},
      {x, y, z + 1}
    ]
    |> Enum.filter(fn coord ->
      local_macro_coord?(coord) and FieldRegion.in_aabb?(region, coord)
    end)
  end

  defp traversable_cell?(storage, ionization_layer, macro_index, source_strength) do
    conductivity =
      electric_attribute(storage, macro_index, "electric_conductivity", @default_conductivity)

    threshold = effective_breakdown_threshold(storage, ionization_layer, macro_index)

    conductivity >= @min_conductivity or source_strength >= threshold
  end

  defp step_cost(storage, ionization_layer, macro_index, source_strength) do
    conductivity =
      electric_attribute(storage, macro_index, "electric_conductivity", @default_conductivity)

    threshold = effective_breakdown_threshold(storage, ionization_layer, macro_index)
    ionization = FieldLayer.get(ionization_layer, macro_index)

    conductive_cost =
      if conductivity >= @min_conductivity do
        @conductive_cost_weight / max(conductivity, @min_conductivity)
      else
        0.0
      end

    dielectric_cost =
      if source_strength >= threshold do
        @dielectric_cost_weight * threshold / max(source_strength, @epsilon)
      else
        @dielectric_cost_weight * (threshold - source_strength + threshold)
      end

    max(
      @min_step_cost,
      1.0 + conductive_cost + dielectric_cost - ionization * @ionization_cost_weight
    )
  end

  defp effective_breakdown_threshold(storage, ionization_layer, macro_index) do
    dielectric_strength =
      electric_attribute(
        storage,
        macro_index,
        "dielectric_strength",
        @default_dielectric_strength
      )

    ionization = FieldLayer.get(ionization_layer, macro_index)
    max(0.0, dielectric_strength - ionization * @ionization_threshold_weight)
  end

  defp electric_attribute(%Storage{} = storage, macro_index, attr_name, fallback) do
    storage
    |> Storage.effective_attribute_at_normalized(macro_index, attr_name)
    |> Kernel./(@fixed32_scale)
  rescue
    _ -> fallback * 1.0
  end

  defp write_discharge_channel(region, path, source_value, opts) do
    path_length = length(path)
    channel_ionization = float_opt(opts, :channel_ionization, @default_channel_ionization)

    potential_layer =
      region
      |> FieldRegion.get_layer(:electric_potential)
      |> clear_layer_in_aabb(region.aabb)

    ionization_layer =
      region
      |> FieldRegion.get_layer(:ionization)
      |> clear_layer_in_aabb(region.aabb)

    {potential_layer, ionization_layer} =
      path
      |> Enum.with_index()
      |> Enum.reduce({potential_layer, ionization_layer}, fn {macro_index, step},
                                                             {potential_acc, ionization_acc} ->
        attenuation = (path_length - step) / path_length
        potential = source_value * attenuation

        {
          FieldLayer.put(potential_acc, macro_index, potential),
          FieldLayer.put(ionization_acc, macro_index, channel_ionization)
        }
      end)

    region
    |> FieldRegion.put_layer(:electric_potential, potential_layer)
    |> FieldRegion.put_layer(:ionization, ionization_layer)
  end

  defp discharge_heat_effects(path, source_value, %KernelContext{} = context, opts) do
    if thermal_coupling_enabled?(opts) do
      projection = participant_projection(context.storage)
      path_length = max(length(path), 1)
      voltage = voltage_for_heat(opts, source_value)
      load_current_amps = load_current_amps_for_heat(opts)
      joule_scale = thermal_coupling_float_opt(opts, :joule_scale, 1.0)
      dt_seconds = max(context.dt_ms, 1) / 1000.0
      heat_energy_joules = voltage * load_current_amps * dt_seconds * joule_scale / path_length

      if heat_energy_joules > 0.0 do
        Enum.map(path, fn macro_index ->
          attrs =
            %{
              attribute: :temperature,
              macro_index: macro_index,
              heat_energy_joules: heat_energy_joules,
              source: :electric_discharge,
              voltage: voltage,
              load_current_amps: load_current_amps,
              temperature_rise_celsius: temperature_rise(opts),
              dt_ms: context.dt_ms
            }
            |> maybe_put_object_part_targets(projection, macro_index)

          {:write_voxel_attribute, attrs}
        end)
      else
        []
      end
    else
      []
    end
  end

  # 功能完善 · 反应层 R8:击穿伤害——对击穿路径上**实心 macro 块且 health>0** 的 cell 逐 tick 发 :damage_block。
  # health=0 视为未跟踪耐久/不可电毁(kernel 端门控,避免误毁默认块);空 cell(被电离空气)无块跳过。
  # 放电模式本就显式 opt-in,故击穿伤害**默认开**;`breakdown_damage: false`/`%{enabled: false}` 关,
  # `%{damage_per_tick: n}` 调。经 SystemActor(always-commit)→ ChunkProcess(权威重校 + 毁块)。
  defp discharge_damage_effects(path, %KernelContext{storage: %Storage{} = storage}, opts) do
    case breakdown_damage_amount(opts) do
      amount when amount > 0 ->
        Enum.flat_map(path, fn macro_index ->
          if damageable_solid?(storage, macro_index) do
            [
              {:damage_block,
               %{macro_index: macro_index, amount: amount, source: :electric_discharge}}
            ]
          else
            []
          end
        end)

      _zero ->
        []
    end
  end

  defp discharge_damage_effects(_path, _context, _opts), do: []

  defp damageable_solid?(%Storage{} = storage, macro_index) do
    case Storage.normal_block_at(storage, macro_index) do
      %{health: health} when is_integer(health) and health > 0 -> true
      _other -> false
    end
  rescue
    _ -> false
  end

  defp breakdown_damage_amount(opts) do
    case fetch_opt(opts, :breakdown_damage, %{}) do
      false ->
        0

      nil ->
        0

      %{} = config ->
        if fetch_opt(config, :enabled, true) in [false, "false", 0] do
          0
        else
          config
          |> fetch_opt(:damage_per_tick, @default_breakdown_damage)
          |> positive_integer(@default_breakdown_damage)
        end

      _other ->
        @default_breakdown_damage
    end
  end

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, fallback), do: fallback

  defp refresh_empty_channel(region) do
    region
    |> FieldRegion.put_layer(
      :electric_potential,
      region |> FieldRegion.get_layer(:electric_potential) |> clear_layer_in_aabb(region.aabb)
    )
    |> FieldRegion.put_layer(
      :ionization,
      region |> FieldRegion.get_layer(:ionization) |> clear_layer_in_aabb(region.aabb)
    )
  end

  defp clear_layer_in_aabb(layer, {{min_x, min_y, min_z}, {max_x, max_y, max_z}}) do
    Enum.reduce(
      for(x <- min_x..max_x, y <- min_y..max_y, z <- min_z..max_z, do: {x, y, z}),
      layer,
      fn coord, acc ->
        FieldLayer.put(acc, Types.macro_index!(coord), 0.0)
      end
    )
  end

  defp maybe_put_object_part_targets(attrs, %ParticipantProjection{} = projection, macro_index) do
    case ParticipantProjection.electric_object_refs(projection, macro_index) do
      [] -> attrs
      targets -> Map.put(attrs, :object_part_targets, targets)
    end
  end

  defp participant_projection(%Storage{} = storage), do: ParticipantProjection.build(storage)
  defp participant_projection(_storage), do: %ParticipantProjection{}

  defp source_point(region) do
    region.source_points
    |> Enum.filter(fn source ->
      source.field_type == :electric_potential and is_number(source.value) and
        in_aabb?(region, source.macro_index)
    end)
    |> Enum.sort_by(fn source -> {-abs(source.value * 1.0), source.macro_index} end)
    |> case do
      [%{macro_index: macro_index, value: value} | _rest] -> {:ok, macro_index, value * 1.0}
      [] -> {:error, :no_source}
    end
  end

  defp target_macro_index(opts) do
    opts
    |> option(:target_macro_index, nil)
    |> case do
      nil -> option(opts, :target_local_macro, nil)
      value -> value
    end
    |> case do
      nil -> {:error, :no_target}
      value -> {:ok, Types.macro_index_or_coord!(value)}
    end
  rescue
    _ -> {:error, :invalid_target}
  end

  defp thermal_coupling_enabled?(opts) do
    case fetch_opt(opts, :thermal_coupling, nil) do
      nil -> false
      false -> false
      %{} = coupling -> fetch_opt(coupling, :enabled, true) not in [false, "false", 0]
      _other -> true
    end
  end

  defp voltage_for_heat(opts, source_value) do
    power_source = map_opt(opts, :power_source)

    power_source
    |> fetch_opt(:voltage, source_value)
    |> non_negative_float(abs(source_value * 1.0))
  end

  defp load_current_amps_for_heat(opts) do
    power_source = map_opt(opts, :power_source)

    (fetch_opt(power_source, :load_current_amps, nil) ||
       fetch_opt(power_source, :requested_current_amps, nil) ||
       fetch_opt(power_source, :current_amps, nil) ||
       fetch_opt(opts, :load_current_amps, nil) ||
       fetch_opt(power_source, :current_limit_amps, nil) ||
       1.0)
    |> non_negative_float(1.0)
  end

  defp thermal_coupling_float_opt(opts, key, fallback) do
    opts
    |> map_opt(:thermal_coupling)
    |> fetch_opt(key, fallback)
    |> non_negative_float(fallback)
  end

  defp temperature_rise(opts) do
    opts
    |> map_opt(:thermal_coupling)
    |> fetch_opt(:temperature_rise_celsius, @default_temperature_rise_celsius)
    |> non_negative_float(@default_temperature_rise_celsius)
  end

  defp map_opt(opts, key) do
    case fetch_opt(opts, key, %{}) do
      %{} = map -> map
      _other -> %{}
    end
  end

  defp fetch_opt(%{} = map, key, default) do
    cond do
      Map.has_key?(map, key) ->
        Map.fetch!(map, key)

      is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
        Map.fetch!(map, Atom.to_string(key))

      true ->
        default
    end
  end

  defp fetch_opt(_other, _key, default), do: default

  defp non_negative_float(value, _fallback) when is_integer(value) and value >= 0,
    do: value * 1.0

  defp non_negative_float(value, _fallback) when is_float(value) and value >= 0, do: value

  defp non_negative_float(value, fallback) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> fallback
    end
  end

  defp non_negative_float(_value, fallback), do: fallback

  defp in_aabb?(region, macro_index) when is_integer(macro_index) do
    FieldRegion.in_aabb?(region, Types.macro_coord!(macro_index))
  rescue
    _ -> false
  end

  defp local_macro_coord?({x, y, z}) do
    x in 0..15 and y in 0..15 and z in 0..15
  end

  defp option(opts, key, default) do
    cond do
      Map.has_key?(opts, key) -> Map.fetch!(opts, key)
      Map.has_key?(opts, Atom.to_string(key)) -> Map.fetch!(opts, Atom.to_string(key))
      true -> default
    end
  end

  defp integer_opt(opts, key, default) do
    case option(opts, key, default) do
      value when is_integer(value) -> value
      _other -> default
    end
  end

  defp float_opt(opts, key, default) do
    case option(opts, key, default) do
      value when is_number(value) -> value * 1.0
      _other -> default
    end
  end

  defp path_backend(opts) do
    case option(opts, :path_backend, :native) do
      value when value in [:elixir, "elixir"] -> :elixir
      _other -> :native
    end
  end
end
