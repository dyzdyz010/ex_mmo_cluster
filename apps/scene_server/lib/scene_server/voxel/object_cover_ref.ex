defmodule SceneServer.Voxel.ObjectCoverRef do
  @moduledoc """
  Reverse index from `(owner_object_id, owner_part_id)` to the micro slots a
  prefab/object covers inside a single refined macro cell.

  Mirrors the `ObjectCoverRef` structure in
  `docs/2026-04-29-server-authoritative-voxel-data-protocol-design.md` §5.4.
  Used for fast object/part deletion, explosion provenance, audit and prefab
  rollback queries; never the source of authoritative occupancy itself.
  """

  @mask_word_count 8
  @u63_max 0x7FFF_FFFF_FFFF_FFFF
  @u64_max 0xFFFF_FFFF_FFFF_FFFF

  defstruct owner_object_id: 0,
            owner_part_id: 0,
            mask_words: List.duplicate(0, @mask_word_count)

  @type mask_word :: 0..0xFFFF_FFFF_FFFF_FFFF
  @type t :: %__MODULE__{
          owner_object_id: 1..0x7FFF_FFFF_FFFF_FFFF,
          owner_part_id: 0..0xFFFF_FFFF,
          mask_words: [mask_word()]
        }

  @doc "Returns the fixed mask-word count (8 → 512 bits)."
  @spec mask_word_count() :: pos_integer()
  def mask_word_count, do: @mask_word_count

  @doc "Builds and validates an object cover ref."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    opts
    |> Map.new()
    |> normalize!()
  end

  @doc "Normalizes a struct or compatible map."
  @spec normalize!(t() | map()) :: t()
  def normalize!(%__MODULE__{} = ref) do
    ref
    |> Map.from_struct()
    |> normalize!()
  end

  def normalize!(attrs) when is_map(attrs) do
    %__MODULE__{
      owner_object_id: owner_object_id!(fetch(attrs, :owner_object_id, 0)),
      owner_part_id: uint!(fetch(attrs, :owner_part_id, 0), 32, :owner_part_id),
      mask_words: mask_words!(fetch(attrs, :mask_words, default_mask()))
    }
  end

  defp default_mask, do: List.duplicate(0, @mask_word_count)

  defp owner_object_id!(value) when is_integer(value) and value >= 1 and value <= @u63_max,
    do: value

  defp owner_object_id!(value),
    do:
      raise(ArgumentError,
        message: "owner_object_id must be a positive integer in 1..2^63-1; got #{inspect(value)}"
      )

  defp mask_words!(words) when is_list(words) do
    if length(words) != @mask_word_count do
      raise ArgumentError,
        message: "mask_words must have exactly #{@mask_word_count} entries, got #{length(words)}"
    end

    Enum.map(words, fn
      w when is_integer(w) and w >= 0 and w <= @u64_max -> w
      other -> raise ArgumentError, message: "mask_word out of range: #{inspect(other)}"
    end)
  end

  defp mask_words!(other),
    do: raise(ArgumentError, message: "mask_words must be a list, got #{inspect(other)}")

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

  @doc "Converts back to a plain map (useful for observe / debug)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = ref), do: Map.from_struct(ref)
end
