defmodule SceneServer.Voxel.Field.FieldRegion do
  @moduledoc """
  Phase 6 局部场最小目标:绑定在某个 chunk 上的活跃场区域,包含 AABB、
  按 field_type 切分的 FieldLayer、tick 计数、source_points、lease_token。

  AABB 使用 inclusive 整型 macro 坐标(每个轴 0..15),不同于 Storage 半开
  `AabbI64`——FieldRegion 只服务 chunk 内的场,粒度 macro,语义对齐
  `Types.macro_index!/1`。
  """

  alias SceneServer.Voxel.Field.FieldLayer

  @field_types [:temperature, :electric_potential, :ionization]

  @type field_type :: :temperature | :electric_potential | :ionization
  @type chunk_coord :: {integer(), integer(), integer()}
  @type local_macro :: {0..15, 0..15, 0..15}
  @type aabb :: {local_macro(), local_macro()}
  @type source_point :: %{
          required(:macro_index) => 0..4095,
          required(:field_type) => field_type(),
          required(:value) => number(),
          optional(any()) => any()
        }

  @type t :: %__MODULE__{
          region_id: non_neg_integer(),
          chunk_coord: chunk_coord(),
          aabb: aabb(),
          field_types: [field_type()],
          source_points: [source_point()],
          tick_count: non_neg_integer(),
          max_ticks: nil | non_neg_integer(),
          lease_token: any(),
          layers: %{optional(field_type()) => FieldLayer.t()}
        }

  defstruct region_id: 0,
            chunk_coord: {0, 0, 0},
            aabb: {{0, 0, 0}, {0, 0, 0}},
            field_types: [:temperature],
            source_points: [],
            tick_count: 0,
            max_ticks: nil,
            lease_token: nil,
            layers: %{}

  @doc "Returns the canonical (sorted) list of recognised field types."
  @spec known_field_types() :: [field_type()]
  def known_field_types, do: @field_types

  @doc """
  Builds a new FieldRegion from a map.

  Required keys:
    * `:region_id` (u64-able integer)
    * `:chunk_coord` (`{cx, cy, cz}`)
    * `:aabb` (`{{min_x, min_y, min_z}, {max_x, max_y, max_z}}`, each axis 0..15)

  Optional keys:
    * `:field_types` (default `[:temperature]`)
    * `:source_points` (default `[]`)
    * `:max_ticks` (default `nil` = no limit)
    * `:lease_token` (default `nil`)
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    field_types = Map.get(attrs, :field_types, [:temperature])

    Enum.each(field_types, fn ft ->
      unless ft in @field_types do
        raise ArgumentError,
              "FieldRegion.new/1: unknown field_type #{inspect(ft)}; expected one of #{inspect(@field_types)}"
      end
    end)

    layers = Map.new(field_types, fn ft -> {ft, FieldLayer.new()} end)

    %__MODULE__{
      region_id: Map.fetch!(attrs, :region_id),
      chunk_coord: Map.fetch!(attrs, :chunk_coord),
      aabb: Map.fetch!(attrs, :aabb),
      field_types: field_types,
      source_points: Map.get(attrs, :source_points, []),
      tick_count: 0,
      max_ticks: Map.get(attrs, :max_ticks),
      lease_token: Map.get(attrs, :lease_token),
      layers: layers
    }
  end

  @doc "Increments `tick_count`."
  @spec increment_tick(t()) :: t()
  def increment_tick(%__MODULE__{} = region) do
    %{region | tick_count: region.tick_count + 1}
  end

  @doc "Returns true if `max_ticks` is non-nil and `tick_count >= max_ticks`."
  @spec tick_limit_reached?(t()) :: boolean()
  def tick_limit_reached?(%__MODULE__{max_ticks: nil}), do: false

  def tick_limit_reached?(%__MODULE__{tick_count: tc, max_ticks: mt}),
    do: is_integer(mt) and tc >= mt

  @doc "Returns the (inclusive) cell count covered by the AABB."
  @spec aabb_cell_count(t()) :: pos_integer()
  def aabb_cell_count(%__MODULE__{aabb: {{min_x, min_y, min_z}, {max_x, max_y, max_z}}}) do
    (max_x - min_x + 1) * (max_y - min_y + 1) * (max_z - min_z + 1)
  end

  @doc "Returns true if the given local macro coord falls inside this region's AABB."
  @spec in_aabb?(t(), local_macro()) :: boolean()
  def in_aabb?(%__MODULE__{aabb: {{min_x, min_y, min_z}, {max_x, max_y, max_z}}}, {x, y, z}) do
    x >= min_x and x <= max_x and y >= min_y and y <= max_y and z >= min_z and z <= max_z
  end

  @doc "Replaces the FieldLayer associated with the given field_type."
  @spec put_layer(t(), field_type(), FieldLayer.t()) :: t()
  def put_layer(%__MODULE__{} = region, field_type, %FieldLayer{} = layer) do
    %{region | layers: Map.put(region.layers, field_type, layer)}
  end

  @doc "Returns the FieldLayer for the given field_type (falls back to an empty layer)."
  @spec get_layer(t(), field_type()) :: FieldLayer.t()
  def get_layer(%__MODULE__{layers: layers}, field_type) do
    Map.get_lazy(layers, field_type, &FieldLayer.new/0)
  end
end
