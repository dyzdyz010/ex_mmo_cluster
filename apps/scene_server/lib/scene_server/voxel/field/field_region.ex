defmodule SceneServer.Voxel.Field.FieldRegion do
  # PERS-5:derived(物理场,解析弛豫+warm-up 重建;触发权威后果须经 AUTH-11)。见 MmoContracts.StateRegistry。
  use MmoContracts.StateClassed, class: :derived

  @moduledoc """
  Phase 6 局部场最小目标:绑定在某个 chunk 上的活跃场区域,包含 AABB、
  按 field_type 切分的 FieldLayer、tick 计数、source_points、lease_token。

  AABB 使用 inclusive 整型 macro 坐标(每个轴 0..15),不同于 Storage 半开
  `AabbI64`——FieldRegion 只服务 chunk 内的场,粒度 macro,语义对齐
  `Types.macro_index!/1`。
  """

  alias SceneServer.Voxel.Field.FieldLayer

  @field_types [
    :temperature,
    :electric_potential,
    :electric_current,
    :ionization,
    :light,
    :light_color
  ]

  @type field_type ::
          :temperature
          | :electric_potential
          | :electric_current
          | :ionization
          | :light
          | :light_color
  @type chunk_coord :: {integer(), integer(), integer()}
  @type local_macro :: {0..15, 0..15, 0..15}
  @type aabb :: {local_macro(), local_macro()}
  @type source_point :: %{
          required(:macro_index) => 0..4095,
          required(:field_type) => field_type(),
          required(:value) => number(),
          optional(any()) => any()
        }
  @type kernel_spec :: %{
          required(:id) => atom(),
          required(:module) => module(),
          optional(:opts) => map()
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
          kernels: [kernel_spec()],
          layers: %{optional(field_type()) => FieldLayer.t()}
        }

  defstruct region_id: 0,
            chunk_coord: {0, 0, 0},
            aabb: {{0, 0, 0}, {0, 0, 0}},
            field_types: [],
            source_points: [],
            tick_count: 0,
            max_ticks: nil,
            lease_token: nil,
            kernels: [],
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
    * `:kernels` (non-empty list of `%{id:, module:, opts:}`)

  Optional keys:
    * `:source_points` (default `[]`)
    * `:max_ticks` (default `nil` = no limit)
    * `:lease_token` (default `nil`)

  `:field_types` is intentionally not accepted as input. It is derived from the
  kernels' `required_layers/1`, so kernel specs are the only creation-time truth
  source.
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    if has_key?(attrs, :field_types) do
      raise ArgumentError,
            "FieldRegion.new/1: field_types are derived from kernels; pass :kernels instead"
    end

    kernels =
      attrs
      |> fetch_required_key!(:kernels)
      |> normalize_kernel_specs!()

    field_types = derive_field_types!(kernels)
    source_points = Map.get(attrs, :source_points, [])
    validate_source_points!(source_points, field_types)

    layers = Map.new(field_types, fn ft -> {ft, new_layer(ft)} end)

    %__MODULE__{
      region_id: Map.fetch!(attrs, :region_id),
      chunk_coord: Map.fetch!(attrs, :chunk_coord),
      aabb: Map.fetch!(attrs, :aabb),
      field_types: field_types,
      source_points: source_points,
      tick_count: 0,
      max_ticks: Map.get(attrs, :max_ticks),
      lease_token: Map.get(attrs, :lease_token),
      kernels: kernels,
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
    Map.get_lazy(layers, field_type, fn -> new_layer(field_type) end)
  end

  defp new_layer(:temperature),
    do: FieldLayer.new(baseline: 20, quantization: :float, threshold: 0.0001)

  defp new_layer(_field_type), do: FieldLayer.new()

  defp normalize_kernel_specs!(specs) when is_list(specs) and specs != [] do
    specs
    |> Enum.map(&normalize_kernel_spec!/1)
    |> validate_kernel_modules!()
  end

  defp normalize_kernel_specs!([]) do
    raise ArgumentError, "FieldRegion.new/1: kernels must be a non-empty list"
  end

  defp normalize_kernel_specs!(other) do
    raise ArgumentError,
          "FieldRegion.new/1: kernels must be a list of %{id: atom, module: module, opts: map}, got: #{inspect(other)}"
  end

  defp normalize_kernel_spec!(spec) when is_map(spec) do
    id = fetch_kernel_key!(spec, :id)
    module = fetch_kernel_key!(spec, :module)
    opts = fetch_kernel_key(spec, :opts, %{})

    unless is_atom(id) do
      raise ArgumentError, "FieldRegion.new/1: kernel id must be an atom, got: #{inspect(id)}"
    end

    unless is_atom(module) do
      raise ArgumentError,
            "FieldRegion.new/1: kernel module must be a module atom, got: #{inspect(module)}"
    end

    unless is_map(opts) do
      raise ArgumentError, "FieldRegion.new/1: kernel opts must be a map, got: #{inspect(opts)}"
    end

    %{id: id, module: module, opts: opts}
  end

  defp normalize_kernel_spec!(other) do
    raise ArgumentError,
          "FieldRegion.new/1: kernel spec must be a map, got: #{inspect(other)}"
  end

  defp validate_kernel_modules!(kernels) do
    Enum.each(kernels, fn %{id: id, module: module, opts: opts} ->
      unless Code.ensure_loaded?(module) and function_exported?(module, :required_layers, 1) and
               function_exported?(module, :tick, 3) do
        raise ArgumentError,
              "FieldRegion.new/1: kernel #{inspect(id)} module #{inspect(module)} must export required_layers/1 and tick/3"
      end

      required_layers = module.required_layers(opts)

      Enum.each(required_layers, fn field_type ->
        unless field_type in @field_types do
          raise ArgumentError,
                "FieldRegion.new/1: kernel #{inspect(id)} requires unknown layer #{inspect(field_type)}"
        end
      end)
    end)

    kernels
  end

  defp derive_field_types!(kernels) do
    required =
      kernels
      |> Enum.flat_map(fn %{module: module, opts: opts} -> module.required_layers(opts) end)
      |> MapSet.new()

    @field_types
    |> Enum.filter(&MapSet.member?(required, &1))
  end

  defp validate_source_points!(source_points, field_types) when is_list(source_points) do
    Enum.each(source_points, fn source_point ->
      field_type = fetch_required_key!(source_point, :field_type)

      unless field_type in field_types do
        raise ArgumentError,
              "FieldRegion.new/1: source_point field_type #{inspect(field_type)} is not produced by kernels #{inspect(field_types)}"
      end
    end)

    :ok
  end

  defp validate_source_points!(other, _field_types) do
    raise ArgumentError, "FieldRegion.new/1: source_points must be a list, got: #{inspect(other)}"
  end

  defp fetch_kernel_key!(spec, key) do
    case fetch_kernel_key(spec, key, :__missing__) do
      :__missing__ ->
        raise ArgumentError, "FieldRegion.new/1: kernel spec missing #{inspect(key)}"

      value ->
        value
    end
  end

  defp fetch_kernel_key(spec, key, default) do
    cond do
      Map.has_key?(spec, key) -> Map.fetch!(spec, key)
      Map.has_key?(spec, Atom.to_string(key)) -> Map.fetch!(spec, Atom.to_string(key))
      true -> default
    end
  end

  defp has_key?(attrs, key) when is_map(attrs) do
    Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))
  end

  defp fetch_required_key!(attrs, key) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, key) ->
        Map.fetch!(attrs, key)

      Map.has_key?(attrs, Atom.to_string(key)) ->
        Map.fetch!(attrs, Atom.to_string(key))

      true ->
        raise ArgumentError, "FieldRegion.new/1: missing required #{inspect(key)}"
    end
  end
end
