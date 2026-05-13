defmodule SceneServer.Voxel.DirtyMacroBounds do
  @moduledoc """
  Half-open local macro bounds for dirty chunk work.

  The bounds identify the smallest local macro range that needs follow-up work
  such as persistence, mesh rebuild, or rule simulation. This metadata is not
  part of the canonical chunk content hash.
  """

  alias SceneServer.Voxel.Types

  import Bitwise

  # Phase 5.E reason_flags bitmap（详见
  # `docs/plans/2026-05-13-phase5e-simulation-tick-infrastructure.md` E-3）。
  @reason_attribute_write 0x01
  @reason_chunk_sub_change 0x02
  @reason_cross_chunk_boundary 0x04
  @reason_catalog_changed 0x08

  defstruct min_macro: {0, 0, 0},
            max_macro: {0, 0, 0},
            reason_flags: 0

  @type bound_coord :: {0..16, 0..16, 0..16}

  @type t :: %__MODULE__{
          min_macro: bound_coord(),
          max_macro: bound_coord(),
          reason_flags: 0..0xFFFF
        }

  @doc "reason_flag: macro 内 attribute / cell payload 写入。"
  @spec reason_attribute_write() :: 0x01
  def reason_attribute_write, do: @reason_attribute_write

  @doc "reason_flag: 订阅集合变化（首次订阅不打标，仅订阅状态变更才打）。"
  @spec reason_chunk_sub_change() :: 0x02
  def reason_chunk_sub_change, do: @reason_chunk_sub_change

  @doc "reason_flag: 邻 chunk 边界事件渗透。"
  @spec reason_cross_chunk_boundary() :: 0x04
  def reason_cross_chunk_boundary, do: @reason_cross_chunk_boundary

  @doc "reason_flag: AttributeCatalog / TagCatalog runtime 版本变化。"
  @spec reason_catalog_changed() :: 0x08
  def reason_catalog_changed, do: @reason_catalog_changed

  @doc "Builds empty dirty bounds."
  @spec empty() :: t()
  def empty, do: %__MODULE__{}

  @doc "Whether dirty bounds carry no macro cells (half-open `min == max` 任一轴)."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{min_macro: {ax, ay, az}, max_macro: {bx, by, bz}}) do
    ax >= bx or ay >= by or az >= bz
  end

  @doc "Resets dirty bounds back to empty (e.g. after a simulation tick consumed them)."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = _bounds), do: empty()

  @doc """
  Marks one macro index (or coord) as dirty and OR-merges the reason flag.

  本函数把 `min_macro` 向下扩、把 `max_macro` 向上扩到刚好包住目标 macro
  cell（half-open `[min, max)`，所以包含 macro `(x, y, z)` 的最小 bounds 是
  `min = (x, y, z)`、`max = (x+1, y+1, z+1)`）。空 bounds 第一次 `add_macro/3`
  会得到刚好覆盖一个 cell 的合法 bounds。
  """
  @spec add_macro(t(), integer() | term(), 0..0xFFFF) :: t()
  def add_macro(%__MODULE__{} = bounds, macro_index_or_coord, reason_flag)
      when is_integer(reason_flag) and reason_flag >= 0 and reason_flag <= 0xFFFF do
    index = Types.macro_index_or_coord!(macro_index_or_coord)
    {mx, my, mz} = Types.macro_coord!(index)
    do_add_macro(bounds, mx, my, mz, reason_flag)
  end

  @doc "Tests whether the given reason_flag bit is currently set."
  @spec reason_set?(t(), 0..0xFFFF) :: boolean()
  def reason_set?(%__MODULE__{reason_flags: flags}, reason_flag)
      when is_integer(reason_flag) and reason_flag >= 0 do
    (flags &&& reason_flag) == reason_flag and reason_flag > 0
  end

  defp do_add_macro(%__MODULE__{} = bounds, mx, my, mz, reason_flag) do
    cond do
      empty?(bounds) ->
        %__MODULE__{
          min_macro: {mx, my, mz},
          max_macro: {mx + 1, my + 1, mz + 1},
          reason_flags: bounds.reason_flags ||| reason_flag
        }

      true ->
        {ax, ay, az} = bounds.min_macro
        {bx, by, bz} = bounds.max_macro

        %__MODULE__{
          min_macro: {min(ax, mx), min(ay, my), min(az, mz)},
          max_macro: {max(bx, mx + 1), max(by, my + 1), max(bz, mz + 1)},
          reason_flags: bounds.reason_flags ||| reason_flag
        }
    end
  end

  @doc "Builds and validates half-open local macro dirty bounds."
  @spec new(term(), term(), keyword()) :: t()
  def new(min_macro, max_macro, opts \\ []) do
    opts
    |> Map.new()
    |> Map.put(:min_macro, min_macro)
    |> Map.put(:max_macro, max_macro)
    |> normalize!()
  end

  @doc "Normalizes dirty bounds from a struct or compatible map."
  @spec normalize!(t() | map()) :: t()
  def normalize!(%__MODULE__{} = bounds) do
    bounds
    |> Map.from_struct()
    |> normalize!()
  end

  def normalize!(attrs) when is_map(attrs) do
    {min_macro, max_macro} =
      Types.normalize_local_macro_aabb!(
        fetch(attrs, :min_macro, {0, 0, 0}),
        fetch(attrs, :max_macro, {0, 0, 0})
      )

    %__MODULE__{
      min_macro: min_macro,
      max_macro: max_macro,
      reason_flags: uint16!(fetch(attrs, :reason_flags, 0))
    }
  end

  defp fetch(attrs, key, default) do
    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.fetch!(attrs, Atom.to_string(key))
      true -> default
    end
  end

  defp uint16!(value) when is_integer(value) and value >= 0 and value <= 0xFFFF, do: value

  defp uint16!(value) do
    raise ArgumentError, "expected reason_flags u16, got: #{inspect(value)}"
  end
end
