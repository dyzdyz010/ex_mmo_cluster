defmodule SceneServer.Voxel.MacroCellHeader do
  @moduledoc """
  Fixed per-macro-cell header for chunk storage.

  There are exactly 4096 headers per v1 chunk. The header owns mode, pool
  indexes, local version, and the macro-level content hash field; heavy payloads
  live in sparse pools.
  """

  import Bitwise, only: [band: 2, bnot: 1]

  @cell_mode_empty 0
  @cell_mode_solid_block 1
  @cell_mode_refined 2
  @no_index 0xFFFF_FFFF

  @dirty_storage 0x0001
  @dirty_mesh 0x0002
  @dirty_rules 0x0004
  @transient_flag_mask @dirty_storage + @dirty_mesh + @dirty_rules

  defstruct mode: @cell_mode_empty,
            flags: 0,
            payload_index: @no_index,
            environment_index: @no_index,
            cell_version: 0,
            cell_hash: 0

  @type mode :: 0 | 1 | 2

  @type t :: %__MODULE__{
          mode: mode(),
          flags: 0..0xFFFF,
          payload_index: 0..0xFFFF_FFFF,
          environment_index: 0..0xFFFF_FFFF,
          cell_version: 0..0xFFFF_FFFF,
          cell_hash: 0..0xFFFF_FFFF
        }

  @doc "Returns the v1 empty cell mode value."
  @spec cell_mode_empty() :: 0
  def cell_mode_empty, do: @cell_mode_empty

  @doc "Returns the v1 solid-block cell mode value."
  @spec cell_mode_solid_block() :: 1
  def cell_mode_solid_block, do: @cell_mode_solid_block

  @doc "Returns the v1 refined cell mode value."
  @spec cell_mode_refined() :: 2
  def cell_mode_refined, do: @cell_mode_refined

  @doc "Returns the sentinel used when a header has no pool reference."
  @spec no_index() :: 0xFFFF_FFFF
  def no_index, do: @no_index

  @doc "Builds an empty macro-cell header."
  @spec empty(keyword()) :: t()
  def empty(opts \\ []) do
    opts
    |> Map.new()
    |> Map.put_new(:mode, @cell_mode_empty)
    |> Map.put_new(:payload_index, @no_index)
    |> Map.put_new(:environment_index, @no_index)
    |> normalize!()
  end

  @doc "Builds a solid-block macro-cell header pointing at a normal-block pool index."
  @spec solid(non_neg_integer(), keyword()) :: t()
  def solid(payload_index, opts \\ []) do
    opts
    |> Map.new()
    |> Map.put(:mode, @cell_mode_solid_block)
    |> Map.put(:payload_index, payload_index)
    |> Map.put_new(:environment_index, @no_index)
    |> normalize!()
  end

  @doc "Builds a refined macro-cell header pointing at a refined-cell pool index."
  @spec refined(non_neg_integer(), keyword()) :: t()
  def refined(payload_index, opts \\ []) do
    opts
    |> Map.new()
    |> Map.put(:mode, @cell_mode_refined)
    |> Map.put(:payload_index, payload_index)
    |> Map.put_new(:environment_index, @no_index)
    |> normalize!()
  end

  @doc "Normalizes a header struct or compatible map."
  @spec normalize!(t() | map()) :: t()
  def normalize!(%__MODULE__{} = header) do
    header
    |> Map.from_struct()
    |> normalize!()
  end

  def normalize!(attrs) when is_map(attrs) do
    %__MODULE__{
      mode: normalize_mode!(fetch(attrs, :mode, @cell_mode_empty)),
      flags: uint!(fetch(attrs, :flags, 0), 16, :flags),
      payload_index: uint!(fetch(attrs, :payload_index, @no_index), 32, :payload_index),
      environment_index:
        uint!(fetch(attrs, :environment_index, @no_index), 32, :environment_index),
      cell_version: uint!(fetch(attrs, :cell_version, 0), 32, :cell_version),
      cell_hash: uint!(fetch(attrs, :cell_hash, 0), 32, :cell_hash)
    }
  end

  @doc "Masks out transient dirty flags for canonical content hashing."
  @spec canonical_flags(t() | non_neg_integer()) :: non_neg_integer()
  def canonical_flags(%__MODULE__{} = header), do: canonical_flags(header.flags)

  def canonical_flags(flags) when is_integer(flags) do
    flags
    |> uint!(16, :flags)
    |> band(bnot(@transient_flag_mask))
    |> band(0xFFFF)
  end

  defp normalize_mode!(:empty), do: @cell_mode_empty
  defp normalize_mode!(:solid_block), do: @cell_mode_solid_block
  defp normalize_mode!(:solid), do: @cell_mode_solid_block
  defp normalize_mode!(:refined), do: @cell_mode_refined

  defp normalize_mode!(mode)
       when mode in [@cell_mode_empty, @cell_mode_solid_block, @cell_mode_refined], do: mode

  defp normalize_mode!(mode) do
    raise ArgumentError, "invalid macro cell mode: #{inspect(mode)}"
  end

  defp fetch(attrs, key, default) do
    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.fetch!(attrs, Atom.to_string(key))
      true -> default
    end
  end

  defp uint!(value, bits, label) when is_integer(value) do
    max = trunc(:math.pow(2, bits)) - 1

    if value < 0 or value > max do
      raise ArgumentError, "#{label} value #{value} outside u#{bits}"
    end

    value
  end

  defp uint!(value, bits, label) do
    raise ArgumentError, "expected #{label} u#{bits}, got: #{inspect(value)}"
  end
end
