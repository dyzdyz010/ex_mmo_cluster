defmodule SceneServer.Voxel.Field.Kernels.ConductionPathKernel do
  @moduledoc """
  Phase 7.B material-aware electric conduction channel kernel.

  This kernel turns an electric source and an explicit target into one
  deterministic, chunk-local channel. It reads `electric_conductivity` and
  `dielectric_strength` through the storage effective-attribute API, refreshes
  `:electric_potential` / `:ionization` layers inside the region AABB, and
  returns no authoritative voxel or object side effects.
  """

  @behaviour SceneServer.Voxel.Field.Kernel

  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion, KernelContext}
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  @fixed32_scale 65_536.0
  @default_conductivity 0.0
  @default_dielectric_strength 3.0
  @min_conductivity 0.001
  @min_channel_conductivity 1.0
  @resistance_weight 4.0
  @breakdown_weight 0.25
  @ionization_bonus_weight 0.01
  @min_step_cost 0.05
  @default_channel_ionization 220.0
  @default_max_frontier 512
  @epsilon 0.000001

  @impl true
  def kernel_id, do: :conduction_path

  @impl true
  def required_layers(_opts), do: [:electric_potential, :ionization]

  @doc """
  Computes the material-conductive channel that `tick/3` would write.

  This pure preflight is used by `FieldRuntime` before a field region is
  allocated, so gameplay requests fail at the authority boundary instead of
  creating an empty or misleading electric overlay. The channel is intentionally
  material-gated: air and low-conductivity ground do not become conductors just
  because the potential is high.
  """
  @spec channel_path(Storage.t(), non_neg_integer(), non_neg_integer(), term(), number(), map()) ::
          {:ok, [non_neg_integer()]} | {:error, atom()}
  def channel_path(
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
        kernels: [%{id: :conduction_path, module: __MODULE__}],
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
      {:cont, write_channel(region, path, source_value, opts), []}
    else
      _ -> {:cont, refresh_empty_channel(region), []}
    end
  end

  # ---- channel search -------------------------------------------------------

  defp find_path(region, storage, source_macro_index, target_macro_index, source_value, opts) do
    cond do
      not conductive_cell?(storage, source_macro_index) ->
        {:error, :source_not_conductive}

      not conductive_cell?(storage, target_macro_index) ->
        {:error, :target_not_conductive}

      true ->
        max_frontier =
          opts
          |> integer_opt(:max_frontier, @default_max_frontier)
          |> max(1)

        queue = :gb_sets.singleton({0.0, source_macro_index})
        costs = %{source_macro_index => 0.0}

        dijkstra(queue, costs, %{}, MapSet.new(), 0, max_frontier, %{
          region: region,
          storage: storage,
          target: target_macro_index,
          source: source_macro_index,
          source_strength: abs(source_value * 1.0),
          ionization_layer: FieldRegion.get_layer(region, :ionization)
        })
    end
  end

  defp dijkstra(queue, _costs, _previous, _settled, _frontier_count, _max_frontier, _env)
       when queue == [] do
    {:error, :empty_queue}
  end

  defp dijkstra(queue, costs, previous, settled, frontier_count, max_frontier, env) do
    cond do
      :gb_sets.is_empty(queue) ->
        {:error, :unreachable}

      frontier_count >= max_frontier ->
        {:error, :frontier_exhausted}

      true ->
        {{current_cost, current_macro_index}, queue} = :gb_sets.take_smallest(queue)

        cond do
          MapSet.member?(settled, current_macro_index) ->
            dijkstra(queue, costs, previous, settled, frontier_count, max_frontier, env)

          current_macro_index == env.target ->
            {:ok, reconstruct_path(previous, env.source, env.target)}

          current_cost > Map.fetch!(costs, current_macro_index) + @epsilon ->
            dijkstra(queue, costs, previous, settled, frontier_count, max_frontier, env)

          true ->
            settled = MapSet.put(settled, current_macro_index)

            {queue, costs, previous} =
              current_macro_index
              |> neighbor_indices(env.region)
              |> Enum.filter(&conductive_cell?(env.storage, &1))
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

  defp step_cost(storage, ionization_layer, macro_index, source_strength) do
    conductivity =
      read_attribute(storage, macro_index, "electric_conductivity", @default_conductivity)

    dielectric_strength =
      read_attribute(storage, macro_index, "dielectric_strength", @default_dielectric_strength)

    resistance_cost = @resistance_weight / max(conductivity, @min_conductivity)
    breakdown_cost = breakdown_cost(dielectric_strength, source_strength)
    ionization_bonus = FieldLayer.get(ionization_layer, macro_index) * @ionization_bonus_weight

    max(@min_step_cost, 1.0 + resistance_cost + breakdown_cost - ionization_bonus)
  end

  defp breakdown_cost(dielectric_strength, source_strength) when source_strength > 0.0 do
    if source_strength >= dielectric_strength do
      @breakdown_weight * dielectric_strength / source_strength
    else
      @breakdown_weight * (dielectric_strength - source_strength) + dielectric_strength
    end
  end

  defp breakdown_cost(dielectric_strength, _source_strength), do: dielectric_strength

  defp read_attribute(%Storage{} = storage, macro_index, attr_name, fallback) do
    case Storage.effective_attribute_at_normalized(storage, macro_index, attr_name) do
      value when is_integer(value) -> value / @fixed32_scale
      _other -> fallback
    end
  end

  defp read_attribute(_storage, _macro_index, _attr_name, fallback), do: fallback

  defp conductive_cell?(storage, macro_index) do
    read_attribute(storage, macro_index, "electric_conductivity", @default_conductivity) >=
      @min_channel_conductivity
  end

  # ---- layer writes ---------------------------------------------------------

  defp write_channel(region, path, source_value, opts) do
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

  # ---- option/source helpers ------------------------------------------------

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
end
