defmodule SceneServer.Voxel.Field.FieldLayer do
  @moduledoc """
  Phase 6 局部场最小目标:dense f32 binary array,长度固定 4096(= chunk
  内 macro cell 数量),按 `SceneServer.Voxel.Types.macro_index!/1` 的
  `x + y * 16 + z * 256` 顺序索引。

  设计要点:
    * 一个 FieldLayer 对应单一 field type(temperature / electric_potential /
      ionization 等),由 FieldRegion 持有 layers map。
    * data 使用 little-endian f32 拼接(`4 * 4096 = 16 KiB / layer`),
      与 wire 端 `0x73 FieldRegionSnapshot` 中 cell value 字段同字节序。
    * `active_cells/2,3` 用于 codec 抽取稀疏快照(只编码 `abs(value) > ε`
      的 cell)。
  """

  alias SceneServer.Voxel.Types

  @cell_count 4096
  @bytes_per_cell 4
  @zero_cell <<0.0::float-32-little>>
  @zero_data :binary.copy(@zero_cell, @cell_count)
  @default_epsilon 0.0001

  defstruct data: @zero_data

  @type t :: %__MODULE__{data: binary()}

  @doc "Returns a fresh FieldLayer with all 4096 cells = 0.0 (f32 little-endian)."
  @spec new() :: t()
  def new, do: %__MODULE__{data: @zero_data}

  @doc "Total cell count per layer (always 4096 in v1)."
  @spec cell_count() :: 4096
  def cell_count, do: @cell_count

  @doc "Reads the f32 value at the given macro_index (0..4095)."
  @spec get(t(), 0..4095) :: float()
  def get(%__MODULE__{data: data}, macro_index)
      when is_integer(macro_index) and macro_index >= 0 and macro_index < @cell_count do
    offset = macro_index * @bytes_per_cell
    <<_::binary-size(offset), val::float-32-little, _rest::binary>> = data
    val
  end

  @doc "Writes an f32 value at the given macro_index. value must be numeric."
  @spec put(t(), 0..4095, number()) :: t()
  def put(%__MODULE__{data: data} = layer, macro_index, value)
      when is_integer(macro_index) and macro_index >= 0 and macro_index < @cell_count and
             is_number(value) do
    value_float = value * 1.0
    offset = macro_index * @bytes_per_cell
    before_part = binary_part(data, 0, offset)

    after_part =
      binary_part(
        data,
        offset + @bytes_per_cell,
        byte_size(data) - offset - @bytes_per_cell
      )

    %{layer | data: <<before_part::binary, value_float::float-32-little, after_part::binary>>}
  end

  @doc """
  Returns `[{macro_index, value}]` for cells whose `|value|` exceeds `epsilon`,
  iterating only over the cells contained in `aabb` (inclusive `{min, max}` on
  each axis, each axis in `0..15`).
  """
  @spec active_cells(t(), {{0..15, 0..15, 0..15}, {0..15, 0..15, 0..15}}, float()) ::
          [{0..4095, float()}]
  def active_cells(%__MODULE__{} = layer, aabb, epsilon \\ @default_epsilon)
      when is_number(epsilon) do
    {{min_x, min_y, min_z}, {max_x, max_y, max_z}} = aabb

    for x <- min_x..max_x,
        y <- min_y..max_y,
        z <- min_z..max_z,
        macro_index = Types.macro_index!({x, y, z}),
        val = get(layer, macro_index),
        abs(val) > epsilon do
      {macro_index, val}
    end
  end
end
