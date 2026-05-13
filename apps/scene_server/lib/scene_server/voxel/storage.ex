defmodule SceneServer.Voxel.Storage do
  @moduledoc """
  Scene-side canonical storage struct for one v1 voxel chunk.

  `SceneServer` owns hot execution state for leased chunks. This struct holds
  only chunk truth and local dirty metadata; WorldServer remains responsible for
  global ownership, and DataService only persists snapshots after write-token
  validation.
  """

  alias SceneServer.Voxel.AttributeSet
  alias SceneServer.Voxel.ChunkObjectRef
  alias SceneServer.Voxel.DirtyMacroBounds
  alias SceneServer.Voxel.Hash
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.MacroEnvironmentSummary
  alias SceneServer.Voxel.MicroLayer
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.ObjectCoverRef
  alias SceneServer.Voxel.RefinedCellData
  alias SceneServer.Voxel.TagSet
  alias SceneServer.Voxel.Types

  import Bitwise

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
          refined_cells: [RefinedCellData.t()],
          environment_summaries: [MacroEnvironmentSummary.t()],
          object_refs: [ChunkObjectRef.t()],
          attribute_sets: [AttributeSet.t()],
          tag_sets: [TagSet.t()],
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

  @doc """
  Clears a macro cell back to empty mode.

  The header at `macro_index_or_coord` is replaced with an empty header carrying
  the bumped `cell_version` / fresh `cell_hash` from `opts`. Any payload entry
  the cell previously pointed at is left in `normal_blocks` (orphaned) — full
  compaction is intentionally deferred to a future slice; the wire `ChunkDelta`
  with `delta_kind = 0` (CellEmpty) is the source of truth for clients.
  """
  @spec clear_macro_cell(t(), integer() | term(), keyword()) :: t()
  def clear_macro_cell(%__MODULE__{} = storage, macro_index_or_coord, opts \\ []) do
    storage = normalize!(storage)
    macro_index = Types.macro_index_or_coord!(macro_index_or_coord)

    header =
      MacroCellHeader.empty(
        flags: Keyword.get(opts, :flags, 0),
        cell_version: Keyword.get(opts, :cell_version, 0),
        cell_hash: Keyword.get(opts, :cell_hash, 0)
      )

    %{storage | macro_headers: List.replace_at(storage.macro_headers, macro_index, header)}
    |> normalize!()
  end

  @doc """
  Puts (or sets) a single micro slot inside the macro cell at
  `macro_index_or_coord`.

  `micro_slot_index` is in `0..511` (8³ slots per macro at v1
  `micro_resolution = 8`). `layer_attrs` is a map of `MicroLayer` field
  values (material_id / state_flags / health / attribute_set_ref /
  tag_set_ref / owner_object_id / owner_part_id). Slots sharing the same
  attribute signature are merged into one layer per protocol §5.4 invariant 4.

  State transitions (Phase 1c v1):

    * `empty`   → `refined`  (new RefinedCellData appended to pool)
    * `refined` → `refined`  (existing cell mutated in place at its pool index)
    * `solid`   → raises `ArgumentError` `:cannot_micro_edit_solid_macro`

  `opts` accepts `cell_version` / `cell_hash` / `flags` /
  `environment_index` / `boundary_cache` for the resulting macro header
  and refined cell.
  """
  @spec put_micro_block(
          t(),
          integer() | term(),
          0..511,
          map(),
          keyword()
        ) :: t()
  def put_micro_block(
        %__MODULE__{} = storage,
        macro_index_or_coord,
        micro_slot_index,
        layer_attrs,
        opts \\ []
      ) do
    storage = normalize!(storage)
    macro_index = Types.macro_index_or_coord!(macro_index_or_coord)
    micro_slot_index = micro_slot!(micro_slot_index)
    header = Enum.at(storage.macro_headers, macro_index)

    cond do
      header.mode == MacroCellHeader.cell_mode_solid_block() ->
        raise ArgumentError,
          message:
            "cannot_micro_edit_solid_macro: macro #{macro_index} is in :solid mode; " <>
              "Phase 1c v1 only supports empty ↔ refined transitions"

      header.mode == MacroCellHeader.cell_mode_empty() ->
        new_cell = build_initial_refined_cell(micro_slot_index, layer_attrs, opts)
        append_refined_cell(storage, macro_index, new_cell, opts)

      header.mode == MacroCellHeader.cell_mode_refined() ->
        cell = Enum.at(storage.refined_cells, header.payload_index)
        updated_cell = upsert_micro_slot(cell, micro_slot_index, layer_attrs, opts)
        replace_refined_cell(storage, macro_index, header.payload_index, updated_cell, opts)

      true ->
        raise ArgumentError, "unknown macro mode: #{header.mode}"
    end
  end

  @doc """
  Phase A1-1b batch fast-path:在一个 macro 内一次性写多个 micro slots。

  `slot_layer_pairs` 是 `[{slot_index, layer_attrs}, ...]`。所有 slot 必须
  唯一(in-batch 不重复 / 不冲突 — caller 责任)。

  Algorithmic complexity:1 次 `normalize!`(O(macro_count)) + 1 次 macro
  header lookup + 1 次 cell build/upsert(O(slots) layer merge)+ 1 次
  `List.replace_at` headers + 1 次 refined_cells append/replace。**总开销
  O(macro_count + slots)**,而不是 N 次单 slot put 的 O(macro_count × slots)。

  这条路径让 sphere prefab(280 micro slots)的 commit 从 ~1.5s 降到
  ~50-100ms,demo 体感 = 立即响应。

  State transitions 跟 `put_micro_block/5` 一致。
  """
  @spec put_micro_blocks(
          t(),
          integer() | term(),
          [{0..511, map()}],
          keyword()
        ) :: t()
  def put_micro_blocks(
        %__MODULE__{} = storage,
        macro_index_or_coord,
        slot_layer_pairs,
        opts \\ []
      )
      when is_list(slot_layer_pairs) do
    storage = normalize!(storage)
    macro_index = Types.macro_index_or_coord!(macro_index_or_coord)
    pairs = Enum.map(slot_layer_pairs, fn {slot, layer} -> {micro_slot!(slot), layer} end)

    case pairs do
      [] ->
        storage

      _ ->
        header = Enum.at(storage.macro_headers, macro_index)

        cond do
          header.mode == MacroCellHeader.cell_mode_solid_block() ->
            raise ArgumentError,
              message:
                "cannot_micro_edit_solid_macro: macro #{macro_index} is in :solid mode; " <>
                  "Phase 1c v1 only supports empty ↔ refined transitions"

          header.mode == MacroCellHeader.cell_mode_empty() ->
            new_cell = build_initial_refined_cell_batch(pairs, opts)
            append_refined_cell(storage, macro_index, new_cell, opts)

          header.mode == MacroCellHeader.cell_mode_refined() ->
            cell = Enum.at(storage.refined_cells, header.payload_index)
            updated_cell = upsert_micro_slots(cell, pairs, opts)
            replace_refined_cell(storage, macro_index, header.payload_index, updated_cell, opts)

          true ->
            raise ArgumentError, "unknown macro mode: #{header.mode}"
        end
    end
  end

  @doc """
  Clears a single micro slot inside the macro cell at `macro_index_or_coord`.

  If the slot is currently unoccupied, returns the storage unchanged
  (idempotent). If clearing leaves the cell with no layers and no object
  refs, the macro header is downgraded back to `:empty` mode and the pool
  entry is left orphaned (matching `clear_macro_cell/3` compaction policy).

  `solid` macros raise; `empty` macros no-op.
  """
  @spec clear_micro_block(t(), integer() | term(), 0..511, keyword()) :: t()
  def clear_micro_block(
        %__MODULE__{} = storage,
        macro_index_or_coord,
        micro_slot_index,
        opts \\ []
      ) do
    storage = normalize!(storage)
    macro_index = Types.macro_index_or_coord!(macro_index_or_coord)
    micro_slot_index = micro_slot!(micro_slot_index)
    header = Enum.at(storage.macro_headers, macro_index)

    cond do
      header.mode == MacroCellHeader.cell_mode_empty() ->
        storage

      header.mode == MacroCellHeader.cell_mode_solid_block() ->
        raise ArgumentError,
          message:
            "cannot_micro_edit_solid_macro: macro #{macro_index} is in :solid mode; " <>
              "Phase 1c v1 only supports empty ↔ refined transitions"

      header.mode == MacroCellHeader.cell_mode_refined() ->
        cell = Enum.at(storage.refined_cells, header.payload_index)
        updated_cell = remove_micro_slot(cell, micro_slot_index)

        if refined_cell_empty?(updated_cell) do
          downgrade_refined_to_empty(storage, macro_index, header.payload_index, opts)
        else
          replace_refined_cell(storage, macro_index, header.payload_index, updated_cell, opts)
        end

      true ->
        raise ArgumentError, "unknown macro mode: #{header.mode}"
    end
  end

  @doc "Reads the RefinedCellData payload for a refined macro cell, or nil."
  @spec refined_cell_at(t(), integer() | term()) :: RefinedCellData.t() | nil
  def refined_cell_at(%__MODULE__{} = storage, macro_index_or_coord) do
    storage = normalize!(storage)
    header = macro_header_at(storage, macro_index_or_coord)

    if header.mode == MacroCellHeader.cell_mode_refined() do
      Enum.at(storage.refined_cells, header.payload_index)
    else
      nil
    end
  end

  @doc "Reads one macro header by local macro coord or macro index."
  @spec macro_header_at(t(), integer() | term()) :: MacroCellHeader.t()
  def macro_header_at(%__MODULE__{} = storage, macro_index_or_coord) do
    storage = normalize!(storage)
    macro_index = Types.macro_index_or_coord!(macro_index_or_coord)
    Enum.at(storage.macro_headers, macro_index)
  end

  @doc "Reads the normal-block payload for a solid macro cell, or nil."
  @spec normal_block_at(t(), integer() | term()) :: NormalBlockData.t() | nil
  def normal_block_at(%__MODULE__{} = storage, macro_index_or_coord) do
    storage = normalize!(storage)
    header = macro_header_at(storage, macro_index_or_coord)

    if header.mode == MacroCellHeader.cell_mode_solid_block() do
      Enum.at(storage.normal_blocks, header.payload_index)
    else
      nil
    end
  end

  # ----------------------------------------------------------------------------
  # Phase 1.2 — AttributeSet pool intern API
  # ----------------------------------------------------------------------------

  @doc """
  Interns an `AttributeSet` into the chunk-local pool and returns
  `{storage, attribute_set_ref}`.

  `attribute_set_ref` is 1-indexed (0 reserved for "no attribute set",
  matching `NormalBlockData.attribute_set_ref` / `MicroLayer.attribute_set_ref`
  null semantics). The ref returned is **stable across canonical sort** —
  callers should never compute their own ref off `length(storage.attribute_sets)`
  because `Storage.normalize!` reorders the pool by byte-wise canonical key.

  Re-interning a structurally identical set (same entries after normalize,
  in any input order) returns the existing ref and leaves the pool unchanged.

  Accepts either a `%AttributeSet{}` struct or a compatible map with
  `:entries` — the input is normalized internally before lookup.
  """
  @spec intern_attribute_set(t(), AttributeSet.t() | map()) :: {t(), pos_integer()}
  def intern_attribute_set(%__MODULE__{} = storage, %AttributeSet{} = set) do
    do_intern_attribute_set(storage, AttributeSet.normalize!(set))
  end

  def intern_attribute_set(%__MODULE__{} = storage, attrs) when is_map(attrs) do
    do_intern_attribute_set(storage, AttributeSet.normalize!(attrs))
  end

  defp do_intern_attribute_set(storage, %AttributeSet{} = normalized_set) do
    storage = normalize!(storage)
    key = AttributeSet.byte_canonical_key(normalized_set)

    case Enum.find_index(storage.attribute_sets, fn s ->
           AttributeSet.byte_canonical_key(s) == key
         end) do
      nil ->
        new_pool = storage.attribute_sets ++ [normalized_set]
        storage = normalize!(%{storage | attribute_sets: new_pool})

        # `normalize!` resorts the pool by canonical key. Look up the final
        # index post-sort to return the stable ref.
        index =
          Enum.find_index(storage.attribute_sets, fn s ->
            AttributeSet.byte_canonical_key(s) == key
          end)

        {storage, index + 1}

      idx ->
        {storage, idx + 1}
    end
  end

  # ----------------------------------------------------------------------------
  # Phase 1.3 — TagSet pool intern API
  # ----------------------------------------------------------------------------

  @doc """
  Interns a `TagSet` into the chunk-local pool and returns
  `{storage, tag_set_ref}`.

  `tag_set_ref` is 1-indexed (0 reserved for "no tag set", matching
  `NormalBlockData.tag_set_ref` / `MicroLayer.tag_set_ref` null semantics).
  The ref returned is **stable across canonical sort** — callers should never
  compute their own ref off `length(storage.tag_sets)` because
  `Storage.normalize!` reorders the pool by byte-wise canonical key.

  Re-interning a structurally identical set (same `tag_ids` after normalize,
  in any input order) returns the existing ref and leaves the pool unchanged.

  Accepts either a `%TagSet{}` struct or a compatible map with `:tag_ids`
  — the input is normalized internally before lookup.
  """
  @spec intern_tag_set(t(), TagSet.t() | map()) :: {t(), pos_integer()}
  def intern_tag_set(%__MODULE__{} = storage, %TagSet{} = set) do
    do_intern_tag_set(storage, TagSet.normalize!(set))
  end

  def intern_tag_set(%__MODULE__{} = storage, attrs) when is_map(attrs) do
    do_intern_tag_set(storage, TagSet.normalize!(attrs))
  end

  defp do_intern_tag_set(storage, %TagSet{} = normalized_set) do
    storage = normalize!(storage)
    key = TagSet.byte_canonical_key(normalized_set)

    case Enum.find_index(storage.tag_sets, fn s ->
           TagSet.byte_canonical_key(s) == key
         end) do
      nil ->
        new_pool = storage.tag_sets ++ [normalized_set]
        storage = normalize!(%{storage | tag_sets: new_pool})

        # `normalize!` resorts the pool by canonical key. Look up the final
        # index post-sort to return the stable ref.
        index =
          Enum.find_index(storage.tag_sets, fn s ->
            TagSet.byte_canonical_key(s) == key
          end)

        {storage, index + 1}

      idx ->
        {storage, idx + 1}
    end
  end

  # ----------------------------------------------------------------------------
  # Phase 4 — object provenance reverse lookup + chunk-level cover aggregation
  # ----------------------------------------------------------------------------

  @doc """
  Returns `{owner_object_id, owner_part_id}` for the layer that occupies the
  given micro slot inside the macro at `macro_index_or_coord`. Returns `nil`
  when the slot is unoccupied or the macro is not in `:refined` mode.

  Note that a terrain layer (`owner_object_id = 0`) still returns
  `{0, 0}` — callers attributing damage to objects must filter
  non-zero owners themselves.

  Phase 4 (D6 反向查询):used by ChunkProcess damage routing to figure out
  which object/part owns a micro slot before/after a `break_micro_block`
  intent applies.
  """
  @spec lookup_owner_at(t(), integer() | term(), 0..511) ::
          {non_neg_integer(), non_neg_integer()} | nil
  def lookup_owner_at(%__MODULE__{} = storage, macro_index_or_coord, micro_slot_index) do
    storage = normalize!(storage)
    macro_index = Types.macro_index_or_coord!(macro_index_or_coord)
    micro_slot_index = micro_slot!(micro_slot_index)
    header = Enum.at(storage.macro_headers, macro_index)

    if header.mode == MacroCellHeader.cell_mode_refined() do
      cell = Enum.at(storage.refined_cells, header.payload_index)
      bit_mask = single_bit_mask(micro_slot_index)

      Enum.find_value(cell.layers, fn layer ->
        if mask_intersects?(layer.mask_words, bit_mask) do
          {layer.owner_object_id, layer.owner_part_id}
        else
          nil
        end
      end)
    else
      nil
    end
  end

  @doc """
  Recomputes per-cell `ObjectCoverRef[]` and chunk-level `ChunkObjectRef[]`
  from the current `MicroLayer.owner_object_id` / `owner_part_id` truth.

  Both indices are derived data:`MicroLayer` is the source of truth, the
  cover refs are caches that speed up object-scoped queries (cell level)
  and snapshot摘要 (chunk level)。重算策略走"整 chunk 重算"(决策稿 D6)
  —— 4096 macro × few refined cells × few layers,扫成本 < ms。

  Phase 4:called by `ChunkProcess` after every `apply_intent` commit and
  after `destroy_part` / `destroy_object` cleanup paths to keep the indices
  in sync with layer truth. `object_version` 在 storage 层不可知,固定写 0;
  ObjectRegistry 在自己的内存视图里维护实时 version。
  """
  @spec refresh_chunk_object_refs(t()) :: t()
  def refresh_chunk_object_refs(%__MODULE__{} = storage) do
    storage = normalize!(storage)

    # Step 1: rebuild per-cell ObjectCoverRef[] from layer truth.
    new_refined_cells =
      Enum.map(storage.refined_cells, fn %RefinedCellData{} = cell ->
        %{cell | object_refs: derive_cell_object_refs(cell.layers)}
      end)

    storage = %{storage | refined_cells: new_refined_cells}

    # Step 2: aggregate chunk-level ChunkObjectRef[] across refined cells.
    new_chunk_refs = derive_chunk_object_refs(storage)

    %{storage | object_refs: new_chunk_refs}
  end

  defp derive_cell_object_refs(layers) do
    layers
    |> Enum.reject(fn layer -> layer.owner_object_id == 0 end)
    |> Enum.group_by(fn layer -> {layer.owner_object_id, layer.owner_part_id} end)
    |> Enum.map(fn {{oid, pid}, group} ->
      mask =
        Enum.reduce(group, List.duplicate(0, 8), fn layer, acc ->
          bitwise_or_words(acc, layer.mask_words)
        end)

      ObjectCoverRef.new(
        owner_object_id: oid,
        owner_part_id: pid,
        mask_words: mask
      )
    end)
    |> Enum.sort_by(fn ref -> {ref.owner_object_id, ref.owner_part_id} end)
  end

  defp derive_chunk_object_refs(storage) do
    # %{object_id => %{macro_index => or'd mask_words across all parts}}
    aggregated =
      storage.macro_headers
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {header, macro_index}, acc ->
        if header.mode == MacroCellHeader.cell_mode_refined() do
          cell = Enum.at(storage.refined_cells, header.payload_index)

          Enum.reduce(cell.object_refs, acc, fn ref, inner_acc ->
            inner_acc
            |> Map.put_new(ref.owner_object_id, %{})
            |> Map.update!(ref.owner_object_id, fn macros ->
              Map.update(
                macros,
                macro_index,
                ref.mask_words,
                &bitwise_or_words(&1, ref.mask_words)
              )
            end)
          end)
        else
          acc
        end
      end)

    aggregated
    |> Enum.map(fn {object_id, macros} ->
      coords = macros |> Map.keys() |> Enum.map(&Types.macro_coord!/1)
      {min_macro, max_macro} = aabb_half_open(coords)
      cover_hash = compute_cover_hash(object_id, min_macro, max_macro, macros)

      ChunkObjectRef.new(object_id,
        object_version: 0,
        covered_macro_min: min_macro,
        covered_macro_max: max_macro,
        cover_hash: cover_hash
      )
    end)
    |> Enum.sort_by(& &1.object_id)
  end

  defp aabb_half_open(coords) do
    xs = Enum.map(coords, &elem(&1, 0))
    ys = Enum.map(coords, &elem(&1, 1))
    zs = Enum.map(coords, &elem(&1, 2))

    min_macro = {Enum.min(xs), Enum.min(ys), Enum.min(zs)}
    max_macro = {Enum.max(xs) + 1, Enum.max(ys) + 1, Enum.max(zs) + 1}

    {min_macro, max_macro}
  end

  defp compute_cover_hash(object_id, {min_x, min_y, min_z}, {max_x, max_y, max_z}, macros) do
    sorted = Enum.sort_by(macros, fn {idx, _} -> idx end)

    iodata = [
      <<object_id::unsigned-big-integer-size(64)>>,
      <<min_x::unsigned-big-integer-size(8)>>,
      <<min_y::unsigned-big-integer-size(8)>>,
      <<min_z::unsigned-big-integer-size(8)>>,
      <<max_x::unsigned-big-integer-size(8)>>,
      <<max_y::unsigned-big-integer-size(8)>>,
      <<max_z::unsigned-big-integer-size(8)>>,
      <<length(sorted)::unsigned-big-integer-size(32)>>,
      Enum.map(sorted, fn {macro_index, mask_words} ->
        [
          <<macro_index::unsigned-big-integer-size(16)>>,
          Enum.map(mask_words, fn w ->
            <<w::unsigned-big-integer-size(64)>>
          end)
        ]
      end)
    ]

    Hash.digest64(iodata)
  end

  defp mask_intersects?(mask_a, mask_b) do
    mask_a
    |> Enum.zip(mask_b)
    |> Enum.any?(fn {a, b} -> band(a, b) != 0 end)
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
      refined_cells:
        normalize_list!(
          fetch(attrs, :refined_cells, []),
          &RefinedCellData.normalize!/1,
          :refined_cells
        ),
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
      attribute_sets: normalize_attribute_sets!(fetch(attrs, :attribute_sets, [])),
      tag_sets: normalize_tag_sets!(fetch(attrs, :tag_sets, [])),
      dirty_bounds:
        DirtyMacroBounds.normalize!(fetch(attrs, :dirty_bounds, DirtyMacroBounds.empty()))
    }
  end

  # ----------------------------------------------------------------------------
  # Phase 1c — refined micro mutation helpers
  # ----------------------------------------------------------------------------

  defp micro_slot!(index) when is_integer(index) and index >= 0 and index <= 511, do: index

  defp micro_slot!(index) do
    raise ArgumentError, "micro_slot_index must be in 0..511, got: #{inspect(index)}"
  end

  defp build_initial_refined_cell(slot_index, layer_attrs, opts) do
    mask = single_bit_mask(slot_index)
    layer = MicroLayer.normalize!(Map.put(layer_attrs, :mask_words, mask))

    RefinedCellData.new(
      occupancy_words: mask,
      layers: [layer],
      object_refs: [],
      boundary_cache: Keyword.get(opts, :boundary_cache, 0)
    )
  end

  # Phase A1-1b:batch 版本。把所有 (slot, layer_attrs) 按 layer signature
  # 分组合并 → 一次性产生最少数量的 layers + 一个累积 occupancy mask。
  defp build_initial_refined_cell_batch(pairs, opts) do
    {occupancy, layers} = build_layers_from_pairs(pairs)

    RefinedCellData.new(
      occupancy_words: occupancy,
      layers: layers,
      object_refs: [],
      boundary_cache: Keyword.get(opts, :boundary_cache, 0)
    )
  end

  # 按 attribute signature 把 batch 内 slots 折叠成最少 layer 数,
  # 同时累计整 cell 的 occupancy mask。返回 {occupancy_words, layers}。
  defp build_layers_from_pairs(pairs) do
    {layer_groups_reversed, occupancy} =
      Enum.reduce(pairs, {[], List.duplicate(0, 8)}, fn {slot, attrs}, {groups, occ} ->
        slot_mask = single_bit_mask(slot)
        next_occ = bitwise_or_words(occ, slot_mask)
        # build a shape-only normalized layer to extract attribute signature.
        sig_layer = MicroLayer.normalize!(Map.put(attrs, :mask_words, slot_mask))
        sig = MicroLayer.attribute_signature(sig_layer)

        case List.keyfind(groups, sig, 0) do
          {^sig, %MicroLayer{mask_words: existing_mask} = layer} ->
            merged = %{layer | mask_words: bitwise_or_words(existing_mask, slot_mask)}
            {List.keyreplace(groups, sig, 0, {sig, merged}), next_occ}

          nil ->
            {[{sig, sig_layer} | groups], next_occ}
        end
      end)

    layers = layer_groups_reversed |> Enum.reverse() |> Enum.map(fn {_sig, layer} -> layer end)
    {occupancy, layers}
  end

  defp append_refined_cell(storage, macro_index, cell, opts) do
    payload_index = length(storage.refined_cells)

    header =
      MacroCellHeader.refined(payload_index,
        flags: Keyword.get(opts, :flags, 0),
        environment_index: Keyword.get(opts, :environment_index, MacroCellHeader.no_index()),
        cell_version: Keyword.get(opts, :cell_version, 0),
        cell_hash: Keyword.get(opts, :cell_hash, 0)
      )

    %{
      storage
      | macro_headers: List.replace_at(storage.macro_headers, macro_index, header),
        refined_cells: storage.refined_cells ++ [cell]
    }
    |> normalize!()
  end

  defp replace_refined_cell(storage, macro_index, payload_index, cell, opts) do
    header_now = Enum.at(storage.macro_headers, macro_index)

    header =
      MacroCellHeader.refined(payload_index,
        flags: Keyword.get(opts, :flags, header_now.flags),
        environment_index: Keyword.get(opts, :environment_index, header_now.environment_index),
        cell_version: Keyword.get(opts, :cell_version, header_now.cell_version),
        cell_hash: Keyword.get(opts, :cell_hash, header_now.cell_hash)
      )

    %{
      storage
      | macro_headers: List.replace_at(storage.macro_headers, macro_index, header),
        refined_cells: List.replace_at(storage.refined_cells, payload_index, cell)
    }
    |> normalize!()
  end

  defp downgrade_refined_to_empty(storage, macro_index, payload_index, opts) do
    # Match `clear_macro_cell/3`'s compaction policy: leave the orphaned
    # RefinedCellData in the pool (an empty-but-valid cell) and just flip
    # the macro header back to empty mode.
    header_now = Enum.at(storage.macro_headers, macro_index)

    header =
      MacroCellHeader.empty(
        flags: Keyword.get(opts, :flags, header_now.flags),
        cell_version: Keyword.get(opts, :cell_version, header_now.cell_version),
        cell_hash: Keyword.get(opts, :cell_hash, header_now.cell_hash)
      )

    empty_cell =
      RefinedCellData.new(
        occupancy_words: List.duplicate(0, 8),
        layers: [],
        object_refs: [],
        boundary_cache: 0
      )

    %{
      storage
      | macro_headers: List.replace_at(storage.macro_headers, macro_index, header),
        refined_cells: List.replace_at(storage.refined_cells, payload_index, empty_cell)
    }
    |> normalize!()
  end

  # Phase A1-1b:batch 版本。Pre-existing cell + N 个新 (slot, layer_attrs)
  # → 一次性合并到 cell.layers,同时拒绝任何已被 occupied 的 slot。
  defp upsert_micro_slots(cell, pairs, opts) do
    Enum.each(pairs, fn {slot_index, _attrs} ->
      if slot_currently_occupied?(cell, slot_index) do
        raise ArgumentError,
          message:
            "micro_slot_already_occupied: slot #{slot_index} already belongs to a layer; " <>
              "callers must clear it first or use a future replace path"
      end
    end)

    {add_occupancy, batch_layers} = build_layers_from_pairs(pairs)

    new_layers =
      Enum.reduce(batch_layers, cell.layers, fn batch_layer, acc ->
        sig = MicroLayer.attribute_signature(batch_layer)

        case Enum.split_with(acc, fn existing ->
               MicroLayer.attribute_signature(existing) == sig
             end) do
          {[%MicroLayer{mask_words: existing_mask} = existing], rest} ->
            merged = %{
              existing
              | mask_words: bitwise_or_words(existing_mask, batch_layer.mask_words)
            }

            rest ++ [merged]

          {[], rest} ->
            rest ++ [batch_layer]
        end
      end)

    new_occupancy = bitwise_or_words(cell.occupancy_words, add_occupancy)

    RefinedCellData.new(
      occupancy_words: new_occupancy,
      layers: new_layers,
      object_refs: cell.object_refs,
      boundary_cache: Keyword.get(opts, :boundary_cache, cell.boundary_cache)
    )
  end

  defp upsert_micro_slot(cell, slot_index, layer_attrs, opts) do
    bit_mask = single_bit_mask(slot_index)

    if slot_currently_occupied?(cell, slot_index) do
      raise ArgumentError,
        message:
          "micro_slot_already_occupied: slot #{slot_index} already belongs to a layer; " <>
            "callers must clear it first or use a future replace path"
    end

    target_layer = MicroLayer.normalize!(Map.put(layer_attrs, :mask_words, bit_mask))
    target_sig = MicroLayer.attribute_signature(target_layer)

    {merged_layers, found?} =
      Enum.map_reduce(cell.layers, false, fn %MicroLayer{} = layer, found ->
        if MicroLayer.attribute_signature(layer) == target_sig do
          {%{layer | mask_words: bitwise_or_words(layer.mask_words, bit_mask)}, true}
        else
          {layer, found}
        end
      end)

    new_layers = if found?, do: merged_layers, else: cell.layers ++ [target_layer]

    new_occupancy = bitwise_or_words(cell.occupancy_words, bit_mask)

    RefinedCellData.new(
      occupancy_words: new_occupancy,
      layers: new_layers,
      object_refs: cell.object_refs,
      boundary_cache: Keyword.get(opts, :boundary_cache, cell.boundary_cache)
    )
  end

  defp remove_micro_slot(cell, slot_index) do
    bit_mask = single_bit_mask(slot_index)

    {new_layers, _changed?} =
      Enum.map_reduce(cell.layers, false, fn %MicroLayer{} = layer, changed ->
        cleared = bitwise_andnot_words(layer.mask_words, bit_mask)
        {%{layer | mask_words: cleared}, changed or cleared != layer.mask_words}
      end)

    # Drop layers that became all-zero (ghost layers are forbidden by §5.4).
    pruned_layers =
      Enum.reject(new_layers, fn layer ->
        Enum.all?(layer.mask_words, &(&1 == 0))
      end)

    new_occupancy = bitwise_andnot_words(cell.occupancy_words, bit_mask)

    pruned_object_refs =
      cell.object_refs
      |> Enum.map(fn ref ->
        %{ref | mask_words: bitwise_andnot_words(ref.mask_words, bit_mask)}
      end)
      |> Enum.reject(fn ref ->
        Enum.all?(ref.mask_words, &(&1 == 0))
      end)

    RefinedCellData.new(
      occupancy_words: new_occupancy,
      layers: pruned_layers,
      object_refs: pruned_object_refs,
      boundary_cache: cell.boundary_cache
    )
  end

  defp refined_cell_empty?(%RefinedCellData{} = cell) do
    Enum.all?(cell.occupancy_words, &(&1 == 0)) and
      cell.layers == [] and
      cell.object_refs == []
  end

  defp slot_currently_occupied?(%RefinedCellData{} = cell, slot_index) do
    bit_mask = single_bit_mask(slot_index)

    cell.occupancy_words
    |> Enum.zip(bit_mask)
    |> Enum.any?(fn {word, mask_word} -> band(word, mask_word) != 0 end)
  end

  defp single_bit_mask(slot_index) do
    word_index = div(slot_index, 64)
    bit_index = rem(slot_index, 64)
    bit = bsl(1, bit_index)
    List.replace_at(List.duplicate(0, 8), word_index, bit)
  end

  defp bitwise_or_words(a, b), do: Enum.zip_with(a, b, &bor/2)

  # bitwise AND NOT: clears bits in `a` that are set in `b`.
  defp bitwise_andnot_words(a, b),
    do: Enum.zip_with(a, b, fn x, y -> band(x, bnot(y) &&& 0xFFFF_FFFF_FFFF_FFFF) end)

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

  # Phase 1.2: AttributeSet pool normalization — validate each entry, then
  # sort the pool by byte-wise canonical key (decision D-5a). Pool ordering is
  # independent of caller insertion order, so chunk_hash is stable.
  defp normalize_attribute_sets!(values) when is_list(values) do
    values
    |> Enum.map(&AttributeSet.normalize!/1)
    |> Enum.sort_by(&AttributeSet.byte_canonical_key/1)
  rescue
    exception in ArgumentError ->
      raise ArgumentError, "attribute_sets: #{Exception.message(exception)}"
  end

  defp normalize_attribute_sets!(values) do
    raise ArgumentError, "expected attribute_sets list, got: #{inspect(values)}"
  end

  # Phase 1.3: TagSet pool normalization — validate each entry, then sort the
  # pool by byte-wise canonical key (mirrors `normalize_attribute_sets!`). Pool
  # ordering is independent of caller insertion order, so chunk_hash is stable.
  defp normalize_tag_sets!(values) when is_list(values) do
    values
    |> Enum.map(&TagSet.normalize!/1)
    |> Enum.sort_by(&TagSet.byte_canonical_key/1)
  rescue
    exception in ArgumentError ->
      raise ArgumentError, "tag_sets: #{Exception.message(exception)}"
  end

  defp normalize_tag_sets!(values) do
    raise ArgumentError, "expected tag_sets list, got: #{inspect(values)}"
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
