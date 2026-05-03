defmodule SceneServer.Voxel.Types do
  @moduledoc """
  Canonical voxel coordinate helpers.

  `ChunkCoord` is represented as `{cx, cy, cz}` with signed 32-bit wire bounds.
  `AabbI64` uses world-micro coordinates and always follows the half-open
  `[min, max)` rule. Negative world coordinates use floor division and
  Euclidean remainders so local coordinates are always non-negative.
  """

  alias SceneServer.Voxel.AabbI64

  @chunk_size_in_macro 16
  @micro_resolution 8
  @macro_cell_count @chunk_size_in_macro * @chunk_size_in_macro * @chunk_size_in_macro
  @micro_cell_count @micro_resolution * @micro_resolution * @micro_resolution

  @i32_min -2_147_483_648
  @i32_max 2_147_483_647
  @i64_min -9_223_372_036_854_775_808
  @i64_max 9_223_372_036_854_775_807

  @type chunk_coord :: {integer(), integer(), integer()}
  @type world_micro_coord :: {integer(), integer(), integer()}
  @type local_macro_coord :: {0..15, 0..15, 0..15}
  @type local_micro_coord :: {0..7, 0..7, 0..7}

  @doc "Returns the v1 macro edge length per chunk."
  @spec chunk_size_in_macro() :: 16
  def chunk_size_in_macro, do: @chunk_size_in_macro

  @doc "Returns the v1 micro edge length per macro cell."
  @spec micro_resolution() :: 8
  def micro_resolution, do: @micro_resolution

  @doc "Returns the fixed v1 macro-header count per chunk."
  @spec macro_cell_count() :: 4096
  def macro_cell_count, do: @macro_cell_count

  @doc "Returns the fixed v1 micro-cell count per refined macro cell."
  @spec micro_cell_count() :: 512
  def micro_cell_count, do: @micro_cell_count

  @doc "Normalizes a chunk coordinate to `{cx, cy, cz}` and validates i32 bounds."
  @spec normalize_chunk_coord!(term()) :: chunk_coord()
  def normalize_chunk_coord!(value) do
    value
    |> coord_tuple!(:chunk_coord, [:cx, :cy, :cz])
    |> validate_coord_range!(@i32_min, @i32_max, :chunk_coord)
  end

  @doc "Normalizes a world-micro coordinate to `{x, y, z}` and validates i64 bounds."
  @spec normalize_world_micro_coord!(term()) :: world_micro_coord()
  def normalize_world_micro_coord!(value) do
    value
    |> coord_tuple!(:world_micro_coord, [:x, :y, :z])
    |> validate_coord_range!(@i64_min, @i64_max, :world_micro_coord)
  end

  @doc "Normalizes a local macro coordinate and validates the inclusive `0..15` range."
  @spec normalize_local_macro_coord!(term()) :: local_macro_coord()
  def normalize_local_macro_coord!(value) do
    value
    |> coord_tuple!(:local_macro_coord, [:x, :y, :z])
    |> validate_coord_range!(0, @chunk_size_in_macro - 1, :local_macro_coord)
  end

  @doc "Normalizes a local macro range endpoint and validates the inclusive `0..16` range."
  @spec normalize_local_macro_bound!(term()) :: {0..16, 0..16, 0..16}
  def normalize_local_macro_bound!(value) do
    value
    |> coord_tuple!(:local_macro_bound, [:x, :y, :z])
    |> validate_coord_range!(0, @chunk_size_in_macro, :local_macro_bound)
  end

  @doc "Normalizes a local micro coordinate and validates the inclusive `0..7` range."
  @spec normalize_local_micro_coord!(term()) :: local_micro_coord()
  def normalize_local_micro_coord!(value) do
    value
    |> coord_tuple!(:local_micro_coord, [:x, :y, :z])
    |> validate_coord_range!(0, @micro_resolution - 1, :local_micro_coord)
  end

  @doc "Normalizes a local macro half-open AABB and validates `min <= max` per axis."
  @spec normalize_local_macro_aabb!(term(), term()) ::
          {{0..16, 0..16, 0..16}, {0..16, 0..16, 0..16}}
  def normalize_local_macro_aabb!(min_macro, max_macro) do
    min_macro = normalize_local_macro_bound!(min_macro)
    max_macro = normalize_local_macro_bound!(max_macro)

    validate_min_lte_max!(min_macro, max_macro, :local_macro_aabb)

    {min_macro, max_macro}
  end

  @doc "Normalizes an `AabbI64` struct or compatible map/tuple."
  @spec normalize_aabb_i64!(term()) :: AabbI64.t()
  def normalize_aabb_i64!(%AabbI64{} = aabb) do
    normalize_aabb_i64!({aabb.min_world_micro, aabb.max_world_micro})
  end

  def normalize_aabb_i64!(%{} = attrs) do
    min_world_micro =
      fetch_any!(attrs, [:min_world_micro, "min_world_micro"], :aabb_i64_min_world_micro)

    max_world_micro =
      fetch_any!(attrs, [:max_world_micro, "max_world_micro"], :aabb_i64_max_world_micro)

    normalize_aabb_i64!({min_world_micro, max_world_micro})
  end

  def normalize_aabb_i64!({min_world_micro, max_world_micro}) do
    min_world_micro = normalize_world_micro_coord!(min_world_micro)
    max_world_micro = normalize_world_micro_coord!(max_world_micro)

    validate_min_lte_max!(min_world_micro, max_world_micro, :aabb_i64)

    %AabbI64{min_world_micro: min_world_micro, max_world_micro: max_world_micro}
  end

  def normalize_aabb_i64!([min_world_micro, max_world_micro]) do
    normalize_aabb_i64!({min_world_micro, max_world_micro})
  end

  def normalize_aabb_i64!(value) do
    raise ArgumentError, "expected AabbI64 data, got: #{inspect(value)}"
  end

  @doc "Returns true when the world-micro point is inside the half-open AABB."
  @spec aabb_contains?(term(), term()) :: boolean()
  def aabb_contains?(aabb, point) do
    %AabbI64{min_world_micro: {min_x, min_y, min_z}, max_world_micro: {max_x, max_y, max_z}} =
      normalize_aabb_i64!(aabb)

    {x, y, z} = normalize_world_micro_coord!(point)

    x >= min_x and x < max_x and y >= min_y and y < max_y and z >= min_z and z < max_z
  end

  @doc "Returns true when any axis has equal min and max in a half-open AABB."
  @spec empty_aabb?(term()) :: boolean()
  def empty_aabb?(aabb) do
    %AabbI64{min_world_micro: {min_x, min_y, min_z}, max_world_micro: {max_x, max_y, max_z}} =
      normalize_aabb_i64!(aabb)

    min_x == max_x or min_y == max_y or min_z == max_z
  end

  @doc "Returns the fixed `x + y * 16 + z * 16 * 16` macro index."
  @spec macro_index!(term()) :: 0..4095
  def macro_index!(coord) do
    {x, y, z} = normalize_local_macro_coord!(coord)
    x + y * @chunk_size_in_macro + z * @chunk_size_in_macro * @chunk_size_in_macro
  end

  @doc "Returns the local macro coordinate for a `0..4095` macro index."
  @spec macro_coord!(integer()) :: local_macro_coord()
  def macro_coord!(index) do
    index = validate_integer_range!(index, 0, @macro_cell_count - 1, :macro_index)

    z = div(index, @chunk_size_in_macro * @chunk_size_in_macro)
    rem_after_z = rem(index, @chunk_size_in_macro * @chunk_size_in_macro)
    y = div(rem_after_z, @chunk_size_in_macro)
    x = rem(rem_after_z, @chunk_size_in_macro)

    {x, y, z}
  end

  @doc "Normalizes either a macro index or a local macro coordinate to an index."
  @spec macro_index_or_coord!(integer() | term()) :: 0..4095
  def macro_index_or_coord!(index) when is_integer(index) do
    validate_integer_range!(index, 0, @macro_cell_count - 1, :macro_index)
  end

  def macro_index_or_coord!(coord), do: macro_index!(coord)

  @doc "Returns the fixed `x + y * 8 + z * 8 * 8` micro index."
  @spec micro_index!(term()) :: 0..511
  def micro_index!(coord) do
    {x, y, z} = normalize_local_micro_coord!(coord)
    x + y * @micro_resolution + z * @micro_resolution * @micro_resolution
  end

  @doc "Returns the local micro coordinate for a `0..511` micro index."
  @spec micro_coord!(integer()) :: local_micro_coord()
  def micro_coord!(index) do
    index = validate_integer_range!(index, 0, @micro_cell_count - 1, :micro_index)

    z = div(index, @micro_resolution * @micro_resolution)
    rem_after_z = rem(index, @micro_resolution * @micro_resolution)
    y = div(rem_after_z, @micro_resolution)
    x = rem(rem_after_z, @micro_resolution)

    {x, y, z}
  end

  @doc "Converts a world macro coordinate to `{chunk_coord, local_macro_coord}`."
  @spec chunk_and_local_macro!(term()) :: {chunk_coord(), local_macro_coord()}
  def chunk_and_local_macro!(world_macro_coord) do
    {x, y, z} =
      world_macro_coord
      |> coord_tuple!(:world_macro_coord, [:x, :y, :z])
      |> validate_coord_range!(@i64_min, @i64_max, :world_macro_coord)

    {cx, mx} = chunk_and_local_macro_axis(x)
    {cy, my} = chunk_and_local_macro_axis(y)
    {cz, mz} = chunk_and_local_macro_axis(z)

    {{cx, cy, cz}, {mx, my, mz}}
  end

  @doc "Returns `{chunk_axis, local_axis}` for one world macro axis."
  @spec chunk_and_local_macro_axis(integer()) :: {integer(), 0..15}
  def chunk_and_local_macro_axis(world_macro_axis) when is_integer(world_macro_axis) do
    {floor_div(world_macro_axis, @chunk_size_in_macro),
     floor_mod(world_macro_axis, @chunk_size_in_macro)}
  end

  @doc "Integer floor division, rounding toward negative infinity."
  @spec floor_div(integer(), pos_integer()) :: integer()
  def floor_div(dividend, divisor)
      when is_integer(dividend) and is_integer(divisor) and divisor > 0 do
    quotient = div(dividend, divisor)
    remainder = rem(dividend, divisor)

    if remainder != 0 and ((remainder < 0 and divisor > 0) or (remainder > 0 and divisor < 0)) do
      quotient - 1
    else
      quotient
    end
  end

  @doc "Euclidean remainder for a positive divisor."
  @spec floor_mod(integer(), pos_integer()) :: non_neg_integer()
  def floor_mod(dividend, divisor)
      when is_integer(dividend) and is_integer(divisor) and divisor > 0 do
    remainder = rem(dividend, divisor)

    if remainder < 0 do
      remainder + divisor
    else
      remainder
    end
  end

  defp coord_tuple!({x, y, z}, label, _map_keys) do
    validate_integer_tuple!({x, y, z}, label)
  end

  defp coord_tuple!([x, y, z], label, _map_keys) do
    validate_integer_tuple!({x, y, z}, label)
  end

  defp coord_tuple!(%{} = attrs, label, map_keys) do
    string_keys = Enum.map(map_keys, &Atom.to_string/1)

    cond do
      all_keys?(attrs, map_keys) ->
        attrs
        |> fetch_tuple!(map_keys)
        |> validate_integer_tuple!(label)

      all_keys?(attrs, string_keys) ->
        attrs
        |> fetch_tuple!(string_keys)
        |> validate_integer_tuple!(label)

      map_keys != [:x, :y, :z] and all_keys?(attrs, [:x, :y, :z]) ->
        attrs
        |> fetch_tuple!([:x, :y, :z])
        |> validate_integer_tuple!(label)

      map_keys != [:x, :y, :z] and all_keys?(attrs, ["x", "y", "z"]) ->
        attrs
        |> fetch_tuple!(["x", "y", "z"])
        |> validate_integer_tuple!(label)

      true ->
        raise ArgumentError, "expected #{label} coordinate keys, got: #{inspect(attrs)}"
    end
  end

  defp coord_tuple!(value, label, _map_keys) do
    raise ArgumentError, "expected #{label} as {x, y, z}, got: #{inspect(value)}"
  end

  defp fetch_tuple!(attrs, [x_key, y_key, z_key]) do
    {Map.fetch!(attrs, x_key), Map.fetch!(attrs, y_key), Map.fetch!(attrs, z_key)}
  end

  defp fetch_any!(attrs, keys, label) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(attrs, key) do
        {:ok, value} -> {:found, value}
        :error -> nil
      end
    end)
    |> case do
      {:found, value} -> value
      nil -> raise ArgumentError, "missing #{label}"
    end
  end

  defp all_keys?(attrs, keys), do: Enum.all?(keys, &Map.has_key?(attrs, &1))

  defp validate_integer_tuple!({x, y, z}, label) do
    unless is_integer(x) and is_integer(y) and is_integer(z) do
      raise ArgumentError, "expected #{label} integer coordinate, got: #{inspect({x, y, z})}"
    end

    {x, y, z}
  end

  defp validate_coord_range!({x, y, z}, min, max, label) do
    {
      validate_integer_range!(x, min, max, label),
      validate_integer_range!(y, min, max, label),
      validate_integer_range!(z, min, max, label)
    }
  end

  defp validate_integer_range!(value, min, max, label) when is_integer(value) do
    if value < min or value > max do
      raise ArgumentError, "#{label} value #{value} outside #{min}..#{max}"
    end

    value
  end

  defp validate_integer_range!(value, _min, _max, label) do
    raise ArgumentError, "expected #{label} integer, got: #{inspect(value)}"
  end

  defp validate_min_lte_max!({min_x, min_y, min_z}, {max_x, max_y, max_z}, label) do
    unless min_x <= max_x and min_y <= max_y and min_z <= max_z do
      raise ArgumentError,
            "expected #{label} half-open bounds with min <= max, got: #{inspect({{min_x, min_y, min_z}, {max_x, max_y, max_z}})}"
    end
  end
end
