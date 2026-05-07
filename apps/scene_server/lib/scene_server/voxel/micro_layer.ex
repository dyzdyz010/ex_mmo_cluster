defmodule SceneServer.Voxel.MicroLayer do
  @moduledoc """
  One layer inside a refined macro cell: a sparse group of micro slots that
  share the same `(material_id, state_flags, health, attribute_set_ref,
  tag_set_ref, owner_object_id, owner_part_id)` and is identified by its own
  `mask_words` (8 × u64 = 512 bits, one bit per micro slot).

  Mirrors the `MicroLayer` structure in
  `docs/2026-04-29-server-authoritative-voxel-data-protocol-design.md` §5.4.
  Slot-level provenance is achieved by giving the layer its own owner pair;
  there is no separate per-slot owner field.
  """

  @mask_word_count 8
  @u63_max 0x7FFF_FFFF_FFFF_FFFF
  @u64_max 0xFFFF_FFFF_FFFF_FFFF

  defstruct mask_words: List.duplicate(0, @mask_word_count),
            material_id: 0,
            state_flags: 0,
            health: 0,
            attribute_set_ref: 0,
            tag_set_ref: 0,
            owner_object_id: 0,
            owner_part_id: 0

  @type mask_word :: 0..0xFFFF_FFFF_FFFF_FFFF
  @type t :: %__MODULE__{
          mask_words: [mask_word()],
          material_id: 0..0xFFFF,
          state_flags: 0..0xFFFF_FFFF,
          health: 0..0xFFFF,
          attribute_set_ref: 0..0xFFFF_FFFF,
          tag_set_ref: 0..0xFFFF_FFFF,
          owner_object_id: 0..0x7FFF_FFFF_FFFF_FFFF,
          owner_part_id: 0..0xFFFF_FFFF
        }

  @doc "Returns the fixed mask-word count (8 → 512 bits)."
  @spec mask_word_count() :: pos_integer()
  def mask_word_count, do: @mask_word_count

  @doc "Builds and validates a micro-layer."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    opts
    |> Map.new()
    |> normalize!()
  end

  @doc "Normalizes a struct or compatible map."
  @spec normalize!(t() | map()) :: t()
  def normalize!(%__MODULE__{} = layer) do
    layer
    |> Map.from_struct()
    |> normalize!()
  end

  def normalize!(attrs) when is_map(attrs) do
    %__MODULE__{
      mask_words: mask_words!(fetch(attrs, :mask_words, default_mask())),
      material_id: uint!(fetch(attrs, :material_id, 0), 16, :material_id),
      state_flags: uint!(fetch(attrs, :state_flags, 0), 32, :state_flags),
      health: uint!(fetch(attrs, :health, 0), 16, :health),
      attribute_set_ref: uint!(fetch(attrs, :attribute_set_ref, 0), 32, :attribute_set_ref),
      tag_set_ref: uint!(fetch(attrs, :tag_set_ref, 0), 32, :tag_set_ref),
      owner_object_id: owner_object_id!(fetch(attrs, :owner_object_id, 0)),
      owner_part_id: uint!(fetch(attrs, :owner_part_id, 0), 32, :owner_part_id)
    }
  end

  @doc """
  A grouping fingerprint: the tuple that determines whether two layers must be
  merged per protocol rule §5.4.4 (\"multiple slots sharing material, state,
  attribute, tag and owner must be merged into one layer\").
  """
  @spec attribute_signature(t()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
           non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def attribute_signature(%__MODULE__{} = layer) do
    {layer.material_id, layer.state_flags, layer.health, layer.attribute_set_ref,
     layer.tag_set_ref, layer.owner_object_id, layer.owner_part_id}
  end

  @doc "Converts back to a plain map (useful for observe / debug)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = layer), do: Map.from_struct(layer)

  defp default_mask, do: List.duplicate(0, @mask_word_count)

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

  defp owner_object_id!(value) when is_integer(value) and value >= 0 and value <= @u63_max,
    do: value

  defp owner_object_id!(value),
    do:
      raise(ArgumentError,
        message:
          "owner_object_id must be a non-negative integer in 0..2^63-1; got #{inspect(value)}"
      )

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
