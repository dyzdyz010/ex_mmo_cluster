defmodule SceneServer.Voxel.ChunkObjectRef do
  @moduledoc """
  Chunk-local object coverage summary.

  Scene objects own long-lived object state elsewhere; this record only keeps the
  chunk-level coverage bounds and cover hash needed by snapshots and audits.
  """

  alias SceneServer.Voxel.Types

  @max_u63 9_223_372_036_854_775_807
  @max_u64 0xFFFF_FFFF_FFFF_FFFF

  defstruct object_id: 0,
            object_version: 0,
            covered_macro_min: {0, 0, 0},
            covered_macro_max: {0, 0, 0},
            cover_hash: 0

  @type t :: %__MODULE__{
          object_id: 0..9_223_372_036_854_775_807,
          object_version: 0..9_223_372_036_854_775_807,
          covered_macro_min: {0..16, 0..16, 0..16},
          covered_macro_max: {0..16, 0..16, 0..16},
          cover_hash: 0..0xFFFF_FFFF_FFFF_FFFF
        }

  @doc "Builds and validates a chunk object reference."
  @spec new(non_neg_integer(), keyword()) :: t()
  def new(object_id, opts \\ []) do
    opts
    |> Map.new()
    |> Map.put(:object_id, object_id)
    |> normalize!()
  end

  @doc "Normalizes a chunk object reference struct or compatible map."
  @spec normalize!(t() | map()) :: t()
  def normalize!(%__MODULE__{} = ref) do
    ref
    |> Map.from_struct()
    |> normalize!()
  end

  def normalize!(attrs) when is_map(attrs) do
    {covered_macro_min, covered_macro_max} =
      Types.normalize_local_macro_aabb!(
        fetch(attrs, :covered_macro_min, {0, 0, 0}),
        fetch(attrs, :covered_macro_max, {0, 0, 0})
      )

    %__MODULE__{
      object_id: uint!(fetch(attrs, :object_id, 0), @max_u63, :object_id),
      object_version: uint!(fetch(attrs, :object_version, 0), @max_u63, :object_version),
      covered_macro_min: covered_macro_min,
      covered_macro_max: covered_macro_max,
      cover_hash: uint!(fetch(attrs, :cover_hash, 0), @max_u64, :cover_hash)
    }
  end

  defp fetch(attrs, key, default) do
    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.fetch!(attrs, Atom.to_string(key))
      true -> default
    end
  end

  defp uint!(value, max, label) when is_integer(value) do
    if value < 0 or value > max do
      raise ArgumentError, "#{label} value #{value} outside 0..#{max}"
    end

    value
  end

  defp uint!(value, _max, label) do
    raise ArgumentError, "expected #{label} unsigned integer, got: #{inspect(value)}"
  end
end
