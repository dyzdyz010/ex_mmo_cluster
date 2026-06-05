defmodule SceneServer.Voxel.Field.TemperatureField do
  @moduledoc """
  Phase 6 局部场最小目标:7-stencil 温度场 tick。

  每个 tick:
    1. 温度层只保存相对环境温度的 float delta;未保存 cell 视为 `@env_temp`。
    2. 只对当前异常 cell、热源 cell 及其 6-邻居 halo 计算扩散,避免把
       背景温度写满整个 chunk。
    3. `new_delta = current_delta + α * (neighbor_avg_delta - current_delta)`,
       α 使用真实 SI 单位显式步进:
       `thermal_diffusivity * dt / cell_size²`,其中
       `thermal_diffusivity = thermal_conductivity / (density * specific_heat_capacity)`。
       结果 clamp 到 `@alpha_max` 以满足显式扩散稳定性。
    4. 不再使用调试期固定 β 回冷;热量只通过邻接扩散和有限 region 边界向环境流出。
       绝对值小于 layer threshold 的 cell 自动退出 layer。
    5. `source_mode: :impulse` 的 source_points 只在下一 tick 注入一次;
       其他 `:temperature` source_points 在 tick 末重新写回(热源持续)。
  """

  alias SceneServer.Voxel.Field.{Constants, FieldLayer, FieldRegion, NativeBackend}
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  # 共享物理常量唯一真相源:native/field_kernel/src/field_constants.rs
  # (经 SceneServer.Voxel.Field.Constants 在编译期烘焙)。
  @alpha_max Constants.temperature_alpha_max()
  @fixed32_scale Constants.fixed32_scale()
  @default_tc_raw Constants.default_tc_raw()
  @default_density_raw Constants.default_density_raw()
  @default_specific_heat_capacity_raw Constants.default_specific_heat_capacity_raw()
  @min_density_float Constants.min_density_float()
  @min_specific_heat_capacity_float Constants.min_specific_heat_capacity_float()
  # kernel 本地常量(无 Rust 副本:dt/cell_size 以参数传入 native,env_temp 仅 Elixir 基线):
  @default_dt_seconds 0.1
  @cell_size_meters 1.0
  @env_temp 20

  @doc """
  Runs one tick of the temperature field for the given region.
  """
  @spec tick(FieldRegion.t(), Storage.t() | nil) :: FieldRegion.t()
  @spec tick(FieldRegion.t(), Storage.t() | nil, keyword()) :: FieldRegion.t()
  def tick(%FieldRegion{} = region, storage, opts \\ []) do
    storage = normalize_storage(storage)

    dt_seconds =
      positive_float(Keyword.get(opts, :dt_seconds, @default_dt_seconds), @default_dt_seconds)

    diffusion_time_scale =
      positive_float(Keyword.get(opts, :diffusion_time_scale, 1.0), 1.0)

    ambient_loss_per_second =
      non_negative_float(Keyword.get(opts, :ambient_loss_per_second, 0.0), 0.0)

    cell_size_meters =
      positive_float(Keyword.get(opts, :cell_size_meters, @cell_size_meters), @cell_size_meters)

    {impulse_sources, persistent_region} = take_temperature_impulses(region)

    layer =
      region
      |> FieldRegion.get_layer(:temperature)
      |> apply_source_points(region, impulse_sources)

    candidate_indices = candidate_indices(layer, persistent_region)

    new_layer =
      diffuse_layer(
        layer,
        persistent_region,
        storage,
        candidate_indices,
        dt_seconds * diffusion_time_scale,
        dt_seconds,
        ambient_loss_per_second,
        cell_size_meters,
        Keyword.get(opts, :temperature_backend, :native)
      )

    # 热源点(temperature)在每 tick 末重写,保证热源持续。
    new_layer =
      apply_source_points(
        new_layer,
        persistent_region,
        persistent_temperature_sources(persistent_region)
      )

    FieldRegion.put_layer(persistent_region, :temperature, new_layer)
  end

  # ---- helpers --------------------------------------------------------------

  defp diffuse_layer(
         layer,
         region,
         storage,
         candidate_indices,
         diffusion_seconds,
         ambient_dt_seconds,
         ambient_loss_per_second,
         cell_size_meters,
         backend
       ) do
    fallback = fn ->
      {:ok,
       elixir_diffusion_cells(
         layer,
         region,
         storage,
         candidate_indices,
         diffusion_seconds,
         ambient_dt_seconds,
         ambient_loss_per_second,
         cell_size_meters
       )}
    end

    case NativeBackend.diffuse_temperature(
           layer,
           region.aabb,
           candidate_indices,
           storage,
           diffusion_seconds,
           ambient_dt_seconds,
           ambient_loss_per_second,
           cell_size_meters,
           backend: backend,
           fallback: fallback
         ) do
      {:ok, delta_cells} ->
        apply_delta_cells(layer, delta_cells)

      {:error, _reason} ->
        {:ok, delta_cells} = fallback.()
        apply_delta_cells(layer, delta_cells)
    end
  end

  defp elixir_diffusion_cells(
         layer,
         region,
         storage,
         candidate_indices,
         diffusion_seconds,
         ambient_dt_seconds,
         ambient_loss_per_second,
         cell_size_meters
       ) do
    Enum.map(candidate_indices, fn idx ->
      current_delta = FieldLayer.get_delta(layer, idx)
      neighbor_avg_delta = neighbor_avg_delta(layer, region, idx)

      alpha = alpha_for(storage, idx, diffusion_seconds, cell_size_meters)

      new_delta =
        current_delta
        |> Kernel.+(alpha * (neighbor_avg_delta - current_delta))
        |> apply_ambient_loss(ambient_dt_seconds, ambient_loss_per_second)

      {idx, new_delta}
    end)
  end

  defp apply_delta_cells(layer, delta_cells) do
    Enum.reduce(delta_cells, layer, fn {idx, delta}, acc ->
      FieldLayer.put_delta(acc, idx, delta)
    end)
  end

  defp take_temperature_impulses(%FieldRegion{} = region) do
    {impulses, rest} =
      Enum.split_with(region.source_points, fn sp ->
        sp.field_type == :temperature and source_mode(sp) == :impulse
      end)

    {impulses, %{region | source_points: rest}}
  end

  defp persistent_temperature_sources(%FieldRegion{} = region) do
    Enum.filter(region.source_points, fn sp ->
      sp.field_type == :temperature and source_mode(sp) != :impulse
    end)
  end

  defp apply_source_points(%FieldLayer{} = layer, %FieldRegion{} = region, source_points) do
    Enum.reduce(source_points, layer, fn sp, acc ->
      coord = Types.macro_coord!(sp.macro_index)

      if FieldRegion.in_aabb?(region, coord) do
        FieldLayer.put(acc, sp.macro_index, sp.value * 1.0)
      else
        acc
      end
    end)
  end

  defp source_mode(source_point),
    do: Map.get(source_point, :source_mode, Map.get(source_point, "source_mode", :persistent))

  defp candidate_indices(layer, region) do
    active_indices =
      layer
      |> FieldLayer.active_cells(region.aabb, 0)
      |> Enum.map(&elem(&1, 0))

    source_indices =
      region.source_points
      |> Enum.filter(fn sp ->
        sp.field_type == :temperature and
          FieldRegion.in_aabb?(region, Types.macro_coord!(sp.macro_index))
      end)
      |> Enum.map(& &1.macro_index)

    (active_indices ++ source_indices)
    |> Enum.flat_map(fn idx -> [idx | neighbor_indices(region, idx)] end)
    |> Enum.uniq()
  end

  defp neighbor_avg_delta(layer, region, macro_index) do
    macro_index
    |> Types.macro_coord!()
    |> neighbor_coords()
    |> Enum.map(fn coord ->
      if coord_in_region?(region, coord) do
        coord
        |> Types.macro_index!()
        |> then(&FieldLayer.get_delta(layer, &1))
      else
        0
      end
    end)
    |> Enum.sum()
    |> Kernel./(6.0)
  end

  defp neighbor_indices(region, macro_index) do
    macro_index
    |> Types.macro_coord!()
    |> neighbor_coords()
    |> Enum.filter(&coord_in_region?(region, &1))
    |> Enum.map(&Types.macro_index!/1)
  end

  defp neighbor_coords({x, y, z}) do
    [
      {x - 1, y, z},
      {x + 1, y, z},
      {x, y - 1, z},
      {x, y + 1, z},
      {x, y, z - 1},
      {x, y, z + 1}
    ]
  end

  defp coord_in_region?(region, {x, y, z} = coord) do
    x in 0..15 and y in 0..15 and z in 0..15 and FieldRegion.in_aabb?(region, coord)
  end

  defp alpha_for(storage, macro_index, dt_seconds, cell_size_meters) do
    tc_float = fixed32_to_float(read_thermal_conductivity(storage, macro_index))
    density_float = max(fixed32_to_float(read_density(storage, macro_index)), @min_density_float)

    specific_heat_capacity_float =
      max(
        fixed32_to_float(read_specific_heat_capacity(storage, macro_index)),
        @min_specific_heat_capacity_float
      )

    diffusivity = tc_float / (density_float * specific_heat_capacity_float)

    diffusivity
    |> Kernel.*(dt_seconds)
    |> Kernel./(cell_size_meters * cell_size_meters)
    |> max(0.0)
    |> min(@alpha_max)
  end

  defp fixed32_to_float(raw) when is_integer(raw), do: raw / @fixed32_scale

  defp positive_float(value, _fallback) when is_integer(value) and value > 0, do: value * 1.0
  defp positive_float(value, _fallback) when is_float(value) and value > 0.0, do: value
  defp positive_float(_value, fallback), do: fallback

  defp non_negative_float(value, _fallback) when is_integer(value) and value >= 0, do: value * 1.0
  defp non_negative_float(value, _fallback) when is_float(value) and value >= 0.0, do: value
  defp non_negative_float(_value, fallback), do: fallback

  defp apply_ambient_loss(delta, _dt_seconds, loss_per_second) when loss_per_second <= 0.0,
    do: delta

  defp apply_ambient_loss(delta, dt_seconds, loss_per_second) do
    delta * :math.exp(-loss_per_second * dt_seconds)
  end

  defp read_thermal_conductivity(nil, _macro_index), do: @default_tc_raw

  defp read_thermal_conductivity(%Storage{} = storage, macro_index) do
    Storage.effective_attribute_at_normalized(storage, macro_index, "thermal_conductivity")
  rescue
    _ -> @default_tc_raw
  end

  defp read_thermal_conductivity(_other, _macro_index), do: @default_tc_raw

  defp read_density(nil, _macro_index), do: @default_density_raw

  defp read_density(%Storage{} = storage, macro_index) do
    Storage.effective_attribute_at_normalized(storage, macro_index, "density")
  rescue
    _ -> @default_density_raw
  end

  defp read_density(_other, _macro_index), do: @default_density_raw

  defp read_specific_heat_capacity(nil, _macro_index), do: @default_specific_heat_capacity_raw

  defp read_specific_heat_capacity(%Storage{} = storage, macro_index) do
    Storage.effective_attribute_at_normalized(storage, macro_index, "specific_heat_capacity")
  rescue
    _ -> @default_specific_heat_capacity_raw
  end

  defp read_specific_heat_capacity(_other, _macro_index), do: @default_specific_heat_capacity_raw

  defp normalize_storage(nil), do: nil
  defp normalize_storage(%Storage{} = storage), do: storage
  defp normalize_storage(storage) when is_map(storage), do: Storage.normalize!(storage)
  defp normalize_storage(_other), do: nil

  @doc "Returns the integer environment temperature used by the sparse delta layer."
  @spec env_temperature() :: integer()
  def env_temperature, do: @env_temp
end
