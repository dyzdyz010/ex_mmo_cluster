defmodule SceneServer.Voxel.Field.FieldLayer do
  # PERS-5:derived(密集场数组,不落盘)。见 MmoContracts.StateRegistry。
  use MmoContracts.StateClassed, class: :derived

  @moduledoc """
  Phase 6 局部场最小目标:chunk 内 macro cell 场层。

  设计要点:
    * 一个 FieldLayer 对应单一 field type(temperature / electric_potential /
      ionization 等),由 FieldRegion 持有 layers map。
    * 层内部只保存相对 `baseline` 的稀疏 delta,未保存的 cell 读作
      baseline。
    * temperature 层可用 `quantization: :integer` 将 delta 整数化;wire
      codec 仍把 active value 作为 f32 发送,保持客户端协议兼容。
    * `active_cells/2,3` 用于 codec 抽取稀疏快照(只编码偏离 baseline
      超过阈值的 cell)。
  """

  alias SceneServer.Voxel.Types

  @cell_count 4096
  @default_baseline 0.0
  @default_threshold 0.0001
  @default_quantization :float

  defstruct values: %{},
            baseline: @default_baseline,
            threshold: @default_threshold,
            quantization: @default_quantization

  @type quantization :: :float | :integer
  @type t :: %__MODULE__{
          values: %{optional(0..4095) => number()},
          baseline: number(),
          threshold: number(),
          quantization: quantization()
        }

  @doc "Returns a fresh sparse FieldLayer."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    quantization = Keyword.get(opts, :quantization, @default_quantization)

    unless quantization in [:float, :integer] do
      raise ArgumentError,
            "FieldLayer.new/1: unknown quantization #{inspect(quantization)}; expected :float or :integer"
    end

    %__MODULE__{
      values: %{},
      baseline: quantize(Keyword.get(opts, :baseline, @default_baseline), quantization),
      threshold: Keyword.get(opts, :threshold, @default_threshold),
      quantization: quantization
    }
  end

  @doc "Total cell count per layer (always 4096 in v1)."
  @spec cell_count() :: 4096
  def cell_count, do: @cell_count

  @doc "Reads the absolute value at the given macro_index (0..4095)."
  @spec get(t(), 0..4095) :: number()
  def get(%__MODULE__{} = layer, macro_index)
      when is_integer(macro_index) and macro_index >= 0 and macro_index < @cell_count do
    layer.baseline + get_delta(layer, macro_index)
  end

  @doc "Reads the stored delta from baseline at the given macro_index."
  @spec get_delta(t(), 0..4095) :: number()
  def get_delta(%__MODULE__{values: values, quantization: quantization}, macro_index)
      when is_integer(macro_index) and macro_index >= 0 and macro_index < @cell_count do
    Map.get(values, macro_index, zero_value(quantization))
  end

  @doc "Writes an absolute value at the given macro_index. value must be numeric."
  @spec put(t(), 0..4095, number()) :: t()
  def put(%__MODULE__{} = layer, macro_index, value)
      when is_integer(macro_index) and macro_index >= 0 and macro_index < @cell_count and
             is_number(value) do
    put_delta(layer, macro_index, value - layer.baseline)
  end

  @doc "Writes a delta from baseline at the given macro_index."
  @spec put_delta(t(), 0..4095, number()) :: t()
  def put_delta(%__MODULE__{} = layer, macro_index, delta)
      when is_integer(macro_index) and macro_index >= 0 and macro_index < @cell_count and
             is_number(delta) do
    delta = quantize(delta, layer.quantization)

    values =
      if abs(delta) < layer.threshold do
        Map.delete(layer.values, macro_index)
      else
        Map.put(layer.values, macro_index, delta)
      end

    %{layer | values: values}
  end

  @doc """
  Returns `[{macro_index, value}]` for cells whose stored `|delta|` exceeds
  `epsilon`, filtered to the cells contained in `aabb` (inclusive `{min, max}`
  on each axis, each axis in `0..15`).
  """
  @spec active_cells(t(), {{0..15, 0..15, 0..15}, {0..15, 0..15, 0..15}}, number() | nil) ::
          [{0..4095, number()}]
  def active_cells(layer, aabb, epsilon \\ nil)

  def active_cells(%__MODULE__{} = layer, aabb, nil) do
    active_cells_with_threshold(layer, aabb, layer.threshold)
  end

  def active_cells(%__MODULE__{} = layer, aabb, epsilon) when is_number(epsilon) do
    active_cells_with_threshold(layer, aabb, epsilon)
  end

  defp active_cells_with_threshold(%__MODULE__{} = layer, aabb, threshold) do
    {{min_x, min_y, min_z}, {max_x, max_y, max_z}} = aabb

    layer.values
    |> Enum.filter(fn {macro_index, delta} ->
      {x, y, z} = Types.macro_coord!(macro_index)

      x >= min_x and x <= max_x and y >= min_y and y <= max_y and z >= min_z and
        z <= max_z and abs(delta) >= threshold
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {macro_index, delta} -> {macro_index, layer.baseline + delta} end)
  end

  defp quantize(value, :float), do: value * 1.0
  defp quantize(value, :integer), do: round(value)

  defp zero_value(:float), do: 0.0
  defp zero_value(:integer), do: 0
end
