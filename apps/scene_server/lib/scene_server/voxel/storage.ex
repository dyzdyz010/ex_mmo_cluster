defmodule SceneServer.Voxel.Storage do
  @moduledoc """
  Scene-side canonical storage struct for one v1 voxel chunk.

  `SceneServer` owns hot execution state for leased chunks. This struct holds
  only chunk truth and local dirty metadata; WorldServer remains responsible for
  global ownership, and DataService only persists snapshots after write-token
  validation.
  """

  alias SceneServer.Voxel.ChunkObjectRef
  alias SceneServer.Voxel.DirtyMacroBounds
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.MacroEnvironmentSummary
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Types

  @schema_version 1
  @chunk_size_in_macro 16
  @micro_resolution 8
  @macro_header_count 4096
  @max_u32 0xFFFF_FFFF
  @max_u63 9_223_372_036_854_775_807

  defstruct schema_version: @schema_version,
            logical_scene_id: 0,
            chunk_coord: {0, 0, 0},
            chunk_size_in_macro: @chunk_size_in_macro,
            micro_resolution: @micro_resolution,
            chunk_version: 0,
            flags: 0,
            macro_headers: [],
            normal_blocks: [],
            refined_cells: [],
            environment_summaries: [],
            object_refs: [],
            attribute_sets: [],
            tag_sets: [],
            dirty_bounds: %DirtyMacroBounds{}

  @type t :: %__MODULE__{
          schema_version: 1,
          logical_scene_id: 0..9_223_372_036_854_775_807,
          chunk_coord: Types.chunk_coord(),
          chunk_size_in_macro: 16,
          micro_resolution: 8,
          chunk_version: 0..9_223_372_036_854_775_807,
          flags: 0..0xFFFF_FFFF,
          macro_headers: [MacroCellHeader.t()],
          normal_blocks: [NormalBlockData.t()],
          refined_cells: [term()],
          environment_summaries: [MacroEnvironmentSummary.t()],
          object_refs: [ChunkObjectRef.t()],
          attribute_sets: [term()],
          tag_sets: [term()],
          dirty_bounds: DirtyMacroBounds.t()
        }

  @doc "Returns the only schema version supported by this S0 codec."
  @spec schema_version() :: 1
  def schema_version, do: @schema_version

  @doc "Returns the fixed v1 macro edge length per chunk."
  @spec chunk_size_in_macro() :: 16
  def chunk_size_in_macro, do: @chunk_size_in_macro

  @doc "Returns the fixed v1 micro edge length per macro cell."
  @spec micro_resolution() :: 8
  def micro_resolution, do: @micro_resolution

  @doc "Returns the fixed v1 macro-header count."
  @spec macro_header_count() :: 4096
  def macro_header_count, do: @macro_header_count

  @doc "Builds an empty v1 chunk storage struct with 4096 empty macro headers."
  @spec new(non_neg_integer(), term(), keyword()) :: t()
  def new(logical_scene_id, chunk_coord, opts \\ []) do
    attrs =
      opts
      |> Map.new()
      |> Map.put(:logical_scene_id, logical_scene_id)
      |> Map.put(:chunk_coord, chunk_coord)
      |> Map.put_new(:macro_headers, empty_macro_headers())

    normalize!(struct(__MODULE__, attrs))
  end

  @doc "Alias for `new/3` used by tests and fixtures."
  @spec empty(non_neg_integer(), term(), keyword()) :: t()
  def empty(logical_scene_id, chunk_coord, opts \\ []) do
    new(logical_scene_id, chunk_coord, opts)
  end

  @doc "Returns the canonical list of 4096 empty macro headers."
  @spec empty_macro_headers() :: [MacroCellHeader.t()]
  def empty_macro_headers do
    List.duplicate(MacroCellHeader.empty(), @macro_header_count)
  end

  @doc "Puts a solid normal block at a local macro coord or macro index."
  @spec put_solid_block(t(), integer() | term(), NormalBlockData.t() | map(), keyword()) :: t()
  def put_solid_block(%__MODULE__{} = storage, macro_index_or_coord, block, opts \\ []) do
    storage = normalize!(storage)
    macro_index = Types.macro_index_or_coord!(macro_index_or_coord)
    block = NormalBlockData.normalize!(block)
    payload_index = length(storage.normal_blocks)

    header =
      MacroCellHeader.solid(payload_index,
        flags: Keyword.get(opts, :flags, 0),
        environment_index: Keyword.get(opts, :environment_index, MacroCellHeader.no_index()),
        cell_version: Keyword.get(opts, :cell_version, 0),
        cell_hash: Keyword.get(opts, :cell_hash, 0)
      )

    %{
      storage
      | macro_headers: List.replace_at(storage.macro_headers, macro_index, header),
        normal_blocks: storage.normal_blocks ++ [block]
    }
    |> normalize!()
  end

  @doc "Reads one macro header by local macro coord or macro index."
  @spec macro_header_at(t(), integer() | term()) :: MacroCellHeader.t()
  def macro_header_at(%__MODULE__{} = storage, macro_index_or_coord) do
    storage = normalize!(storage)
    macro_index = Types.macro_index_or_coord!(macro_index_or_coord)
    Enum.at(storage.macro_headers, macro_index)
  end

  @doc "Normalizes a chunk storage struct or compatible map."
  @spec normalize!(t() | map()) :: t()
  def normalize!(%__MODULE__{} = storage) do
    storage
    |> Map.from_struct()
    |> normalize!()
  end

  def normalize!(attrs) when is_map(attrs) do
    macro_headers =
      attrs
      |> fetch(:macro_headers, empty_macro_headers())
      |> normalize_macro_headers!()

    %__MODULE__{
      schema_version:
        fixed!(fetch(attrs, :schema_version, @schema_version), @schema_version, :schema_version),
      logical_scene_id: uint!(fetch(attrs, :logical_scene_id, 0), @max_u63, :logical_scene_id),
      chunk_coord: Types.normalize_chunk_coord!(fetch(attrs, :chunk_coord, {0, 0, 0})),
      chunk_size_in_macro:
        fixed!(
          fetch(attrs, :chunk_size_in_macro, @chunk_size_in_macro),
          @chunk_size_in_macro,
          :chunk_size_in_macro
        ),
      micro_resolution:
        fixed!(
          fetch(attrs, :micro_resolution, @micro_resolution),
          @micro_resolution,
          :micro_resolution
        ),
      chunk_version: uint!(fetch(attrs, :chunk_version, 0), @max_u63, :chunk_version),
      flags: uint!(fetch(attrs, :flags, 0), @max_u32, :flags),
      macro_headers: macro_headers,
      normal_blocks:
        normalize_list!(
          fetch(attrs, :normal_blocks, []),
          &NormalBlockData.normalize!/1,
          :normal_blocks
        ),
      refined_cells: fetch(attrs, :refined_cells, []),
      environment_summaries:
        normalize_list!(
          fetch(attrs, :environment_summaries, []),
          &MacroEnvironmentSummary.normalize!/1,
          :environment_summaries
        ),
      object_refs:
        normalize_list!(
          fetch(attrs, :object_refs, []),
          &ChunkObjectRef.normalize!/1,
          :object_refs
        ),
      attribute_sets: fetch(attrs, :attribute_sets, []),
      tag_sets: fetch(attrs, :tag_sets, []),
      dirty_bounds:
        DirtyMacroBounds.normalize!(fetch(attrs, :dirty_bounds, DirtyMacroBounds.empty()))
    }
  end

  defp normalize_macro_headers!([]), do: empty_macro_headers()

  defp normalize_macro_headers!(headers)
       when is_list(headers) and length(headers) == @macro_header_count do
    Enum.map(headers, &MacroCellHeader.normalize!/1)
  end

  defp normalize_macro_headers!(headers) when is_list(headers) do
    raise ArgumentError, "expected #{@macro_header_count} macro headers, got #{length(headers)}"
  end

  defp normalize_macro_headers!(headers) do
    raise ArgumentError, "expected macro_headers list, got: #{inspect(headers)}"
  end

  defp normalize_list!(values, normalizer, label) when is_list(values) do
    Enum.map(values, normalizer)
  rescue
    exception in ArgumentError ->
      raise ArgumentError, "#{label}: #{Exception.message(exception)}"
  end

  defp normalize_list!(values, _normalizer, label) do
    raise ArgumentError, "expected #{label} list, got: #{inspect(values)}"
  end

  defp fetch(attrs, key, default) do
    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, Atom.to_string(key)) -> Map.fetch!(attrs, Atom.to_string(key))
      true -> default
    end
  end

  defp fixed!(value, expected, label) do
    if value != expected do
      raise ArgumentError, "#{label} must be #{expected}, got: #{inspect(value)}"
    end

    value
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
