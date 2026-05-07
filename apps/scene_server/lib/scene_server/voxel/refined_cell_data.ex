defmodule SceneServer.Voxel.RefinedCellData do
  @moduledoc """
  Authoritative refined micro-grid truth for one macro cell.

  Mirrors `RefinedCellData` in
  `docs/2026-04-29-server-authoritative-voxel-data-protocol-design.md` §5.4:

      RefinedCellData {
        occupancy_words   u64[8]              # union of layer masks
        layers            MicroLayer[]
        object_refs       ObjectCoverRef[]
        boundary_cache    u64
      }

  The cell does not carry its own `cell_version` / `cell_hash`; per protocol
  §5.4 those are owned by the surrounding `MacroCellHeader`. Likewise the
  `local_macro` coordinate and `micro_resolution` are owned by the chunk-level
  envelope (`MacroCellHeader.payload_index` and `ChunkStorage.micro_resolution`)
  and are not duplicated here.

  Slot-level provenance is achieved by giving each layer its own
  `(owner_object_id, owner_part_id)` pair; the layer's `mask_words` then carve
  out the slots it owns. There is no separate per-slot owner field.
  """

  alias SceneServer.Voxel.MicroLayer
  alias SceneServer.Voxel.ObjectCoverRef

  @mask_word_count 8
  @u64_max 0xFFFF_FFFF_FFFF_FFFF

  defstruct occupancy_words: List.duplicate(0, @mask_word_count),
            layers: [],
            object_refs: [],
            boundary_cache: 0

  @type mask_word :: 0..0xFFFF_FFFF_FFFF_FFFF
  @type t :: %__MODULE__{
          occupancy_words: [mask_word()],
          layers: [MicroLayer.t()],
          object_refs: [ObjectCoverRef.t()],
          boundary_cache: 0..0xFFFF_FFFF_FFFF_FFFF
        }

  @doc "Returns the fixed mask-word count (8 → 512 bits)."
  @spec mask_word_count() :: pos_integer()
  def mask_word_count, do: @mask_word_count

  @doc """
  Builds and validates a refined cell.

  Enforces the §5.4 invariants and a few stronger conditions needed to keep
  the wire form deterministic (so two semantically equivalent cells always
  hash to the same `chunk_hash`):

    1. `occupancy_words` length is exactly 8 and every word is in u64 range.
    2. `occupancy_words` equals the bitwise OR of every `layers[*].mask_words`.
    3. No micro slot belongs to more than one layer (`layers` mask are pairwise
       disjoint) and no layer's `mask_words` is all-zero (ghost layers are
       rejected to keep the wire byte-stable).
    4. Layers must already be merged: no two layers share the same
       `(material_id, state_flags, health, attribute_set_ref, tag_set_ref,
       owner_object_id, owner_part_id)` tuple.
    5. Every `object_refs[*].mask_words` is a non-empty subset of
       `occupancy_words` and no two object refs share the same
       `(owner_object_id, owner_part_id)` (duplicates would have to be merged
       by OR-ing their masks).

  After validation, layers and object_refs are normalized to a canonical
  order so the encoded bytes (and therefore `chunk_hash`) are independent of
  the caller's input order. Per protocol §12.3 the canonical encoding rule
  applies to all hash inputs.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    opts
    |> Map.new()
    |> normalize!()
  end

  @doc "Normalizes a struct or compatible map."
  @spec normalize!(t() | map()) :: t()
  def normalize!(%__MODULE__{} = cell) do
    cell
    |> Map.from_struct()
    |> normalize!()
  end

  def normalize!(attrs) when is_map(attrs) do
    occupancy_words =
      mask_words!(fetch(attrs, :occupancy_words, default_mask()), :occupancy_words)

    layers = layers!(fetch(attrs, :layers, []))
    object_refs = object_refs!(fetch(attrs, :object_refs, []))
    boundary_cache = u64!(fetch(attrs, :boundary_cache, 0), :boundary_cache)

    validate_layers_non_empty!(layers)
    validate_object_refs_non_empty!(object_refs)

    cell = %__MODULE__{
      occupancy_words: occupancy_words,
      layers: canonical_layer_order(layers),
      object_refs: canonical_object_ref_order(object_refs),
      boundary_cache: boundary_cache
    }

    validate_invariants!(cell)
    cell
  end

  @doc "Converts back to a plain map (useful for observe / debug)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = cell) do
    %{
      occupancy_words: cell.occupancy_words,
      layers: Enum.map(cell.layers, &MicroLayer.to_map/1),
      object_refs: Enum.map(cell.object_refs, &ObjectCoverRef.to_map/1),
      boundary_cache: cell.boundary_cache
    }
  end

  defp default_mask, do: List.duplicate(0, @mask_word_count)

  defp layers!(list) when is_list(list), do: Enum.map(list, &MicroLayer.normalize!/1)

  defp layers!(other),
    do: raise(ArgumentError, message: "layers must be a list, got #{inspect(other)}")

  defp object_refs!(list) when is_list(list), do: Enum.map(list, &ObjectCoverRef.normalize!/1)

  defp object_refs!(other),
    do: raise(ArgumentError, message: "object_refs must be a list, got #{inspect(other)}")

  defp validate_invariants!(%__MODULE__{} = cell) do
    union = layer_mask_union!(cell.layers)

    if union != cell.occupancy_words do
      raise ArgumentError,
        message:
          "occupancy_words must equal bitwise OR of all layer masks; expected #{inspect(union)}, got #{inspect(cell.occupancy_words)}"
    end

    validate_layers_disjoint!(cell.layers)
    validate_layers_unique_signature!(cell.layers)
    validate_object_refs_subset!(cell.object_refs, cell.occupancy_words)
  end

  defp layer_mask_union!(layers) do
    Enum.reduce(layers, default_mask(), fn layer, acc ->
      bitwise_or_words(acc, layer.mask_words)
    end)
  end

  defp validate_layers_disjoint!(layers) do
    Enum.reduce(layers, default_mask(), fn layer, seen ->
      overlap = bitwise_and_words(seen, layer.mask_words)

      if Enum.any?(overlap, &(&1 != 0)) do
        raise ArgumentError,
          message:
            "micro slots belong to more than one layer (overlap detected); §5.4 invariant 2 violated"
      end

      bitwise_or_words(seen, layer.mask_words)
    end)
  end

  defp validate_layers_unique_signature!(layers) do
    sigs = Enum.map(layers, &MicroLayer.attribute_signature/1)

    if length(Enum.uniq(sigs)) != length(sigs) do
      raise ArgumentError,
        message:
          "layers with identical (material/state/health/attr/tag/owner) signatures must be merged; §5.4 invariant 4 violated"
    end
  end

  defp validate_layers_non_empty!(layers) do
    Enum.each(layers, fn layer ->
      if Enum.all?(layer.mask_words, &(&1 == 0)) do
        raise ArgumentError,
          message:
            "ghost layer rejected: a MicroLayer must cover at least one micro slot (its mask_words must not be all-zero)"
      end
    end)
  end

  defp validate_object_refs_non_empty!(object_refs) do
    Enum.each(object_refs, fn ref ->
      if Enum.all?(ref.mask_words, &(&1 == 0)) do
        raise ArgumentError,
          message: "empty ObjectCoverRef rejected: mask_words must not be all-zero"
      end
    end)

    keys = Enum.map(object_refs, &{&1.owner_object_id, &1.owner_part_id})

    if length(Enum.uniq(keys)) != length(keys) do
      raise ArgumentError,
        message:
          "object_refs with identical (owner_object_id, owner_part_id) must be merged into a single entry by OR-ing their masks"
    end
  end

  defp validate_object_refs_subset!(object_refs, occupancy_words) do
    Enum.each(object_refs, fn ref ->
      and_words = bitwise_and_words(ref.mask_words, occupancy_words)

      if and_words != ref.mask_words do
        raise ArgumentError,
          message:
            "object_refs mask must be a subset of occupancy_words; ref claims slots that are unoccupied"
      end
    end)
  end

  defp canonical_layer_order(layers) do
    Enum.sort_by(layers, &MicroLayer.attribute_signature/1)
  end

  defp canonical_object_ref_order(object_refs) do
    Enum.sort_by(object_refs, &{&1.owner_object_id, &1.owner_part_id})
  end

  defp bitwise_or_words(a, b)
       when length(a) == @mask_word_count and length(b) == @mask_word_count do
    Enum.zip_with(a, b, fn x, y -> Bitwise.bor(x, y) end)
  end

  defp bitwise_and_words(a, b)
       when length(a) == @mask_word_count and length(b) == @mask_word_count do
    Enum.zip_with(a, b, fn x, y -> Bitwise.band(x, y) end)
  end

  defp mask_words!(words, label) when is_list(words) do
    if length(words) != @mask_word_count do
      raise ArgumentError,
        message: "#{label} must have exactly #{@mask_word_count} entries, got #{length(words)}"
    end

    Enum.map(words, fn
      w when is_integer(w) and w >= 0 and w <= @u64_max -> w
      other -> raise ArgumentError, message: "#{label} word out of range: #{inspect(other)}"
    end)
  end

  defp mask_words!(other, label),
    do: raise(ArgumentError, message: "#{label} must be a list, got #{inspect(other)}")

  defp fetch(attrs, key, default) do
    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.fetch!(attrs, Atom.to_string(key))
      true -> default
    end
  end

  defp u64!(value, _label) when is_integer(value) and value >= 0 and value <= @u64_max, do: value

  defp u64!(value, label),
    do: raise(ArgumentError, "expected #{label} u64, got: #{inspect(value)}")
end
