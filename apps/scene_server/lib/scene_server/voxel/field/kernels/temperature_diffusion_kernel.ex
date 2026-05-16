defmodule SceneServer.Voxel.Field.Kernels.TemperatureDiffusionKernel do
  @moduledoc """
  Phase 7.A kernel wrapping the temperature diffusion algorithm.
  """

  @behaviour SceneServer.Voxel.Field.Kernel

  alias SceneServer.Voxel.Field.{FieldRegion, KernelContext, TemperatureField}

  @impl true
  def kernel_id, do: :temperature_diffusion

  @impl true
  def required_layers(_opts), do: [:temperature]

  @impl true
  def tick(%FieldRegion{} = region, %KernelContext{} = context, opts) do
    opts = opts_map(opts)

    {:cont,
     TemperatureField.tick(region, context.storage,
       dt_seconds: max(context.dt_ms, 1) / 1000.0,
       diffusion_time_scale: positive_float(get_opt(opts, :diffusion_time_scale, 1.0), 1.0),
       ambient_loss_per_second:
         non_negative_float(get_opt(opts, :ambient_loss_per_second, 0.0), 0.0),
       cell_size_meters: positive_float(get_opt(opts, :cell_size_meters, 1.0), 1.0)
     ), []}
  end

  defp opts_map(opts) when is_map(opts), do: opts
  defp opts_map(_opts), do: %{}

  defp get_opt(opts, key, default) do
    cond do
      Map.has_key?(opts, key) -> Map.fetch!(opts, key)
      Map.has_key?(opts, Atom.to_string(key)) -> Map.fetch!(opts, Atom.to_string(key))
      true -> default
    end
  end

  defp positive_float(value, _fallback) when is_integer(value) and value > 0, do: value * 1.0
  defp positive_float(value, _fallback) when is_float(value) and value > 0.0, do: value
  defp positive_float(_value, fallback), do: fallback

  defp non_negative_float(value, _fallback) when is_integer(value) and value >= 0, do: value * 1.0
  defp non_negative_float(value, _fallback) when is_float(value) and value >= 0.0, do: value
  defp non_negative_float(_value, fallback), do: fallback
end
