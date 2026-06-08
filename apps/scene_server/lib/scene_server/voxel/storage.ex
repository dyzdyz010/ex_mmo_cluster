defmodule SceneServer.Voxel.Storage do
  @moduledoc """
  Scene-side canonical storage struct for one v1 voxel chunk.

  `SceneServer` owns hot execution state for leased chunks. This struct holds
  only chunk truth and local dirty metadata; WorldServer remains responsible for
  global ownership, and DataService only persists snapshots after write-token
  validation.
  """

  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.AttributeEntry
  alias SceneServer.Voxel.AttributeSet
  alias SceneServer.Voxel.ChunkObjectRef
  alias SceneServer.Voxel.DirtyMacroBounds
  alias SceneServer.Voxel.Hash
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.MacroEnvironmentSummary
  alias SceneServer.Voxel.MaterialCatalog
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

  # 阶段2.5（voxel-storage-6）—— 内存表示与线序/hash 序解耦。
  #
  # `macro_headers` / `refined_cells` 这两个 **公共字段始终是 canonical 有序
  # list**（macro_index 升序 / payload_index 升序），它们是 codec wire layout 与
  # `chunk_hash` 字节序的唯一真相投影 —— encode/hash 永远只遍历这两个 list，
  # 因此换底层加速结构对 wire/hash **零字节漂移**（见 §wire_hash_invariance）。
  #
  # `accel` 是一个**私有派生加速索引**（不进 wire、不进 hash、不参与结构相等
  # 语义——见 `Map.delete(:accel)` 的归一化处理）：
  #
  #   * `headers_array` —— Erlang `:array`（定长 4096），把 macro_index 随机读
  #     从 list `Enum.at` 的 O(n) 降到 O(1)；
  #   * `refined_by_payload` —— `map` `payload_index => RefinedCellData`，把
  #     refined cell 随机读从 O(n) 降到 O(1)。
  #
  # accel 在 `normalize!`（边界全量校验）与 `trust_transform!`（内部局部可信
  # 变换）出口构建/刷新；它**永远从 canonical list 派生**，二者天然一致。
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
            dirty_bounds: %DirtyMacroBounds{},
            accel: nil

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
          dirty_bounds: DirtyMacroBounds.t(),
          accel: accel() | nil
        }

  @typedoc """
  私有派生加速索引（不进 wire / 不进 hash / 不参与结构相等语义）。

  `headers_array` 是定长 4096 的 Erlang `:array`，`refined_by_payload` 是
  `payload_index => RefinedCellData` 的 map。二者永远从 canonical list 派生。
  """
  @type accel :: %{
          headers_array: :array.array(),
          refined_by_payload: %{non_neg_integer() => RefinedCellData.t()}
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

  # ----------------------------------------------------------------------------
  # 阶段2.5 — 加速索引（accel）构建与 O(1) 随机访问 accessor
  #
  # accel 是从 canonical list 派生的私有索引，wire/hash **不**消费它。所有热路径
  # 随机读经下面的 accessor 走 `:array` / `map` 的 O(1) 访问；外部仍可继续以 list
  # 读 `storage.macro_headers` / `storage.refined_cells`（兼容既有调用方/测试），
  # 但那是 O(n) 慢路。
  # ----------------------------------------------------------------------------

  @doc """
  确保 `accel` 加速索引已就绪并与 canonical list 一致。

  幂等：已有 accel 时直接返回。供热路径在拿到 storage 后一次性建好索引，后续
  随机读全部 O(1)。`normalize!` / `trust_transform!` 出口已自动调用本函数。
  """
  @spec ensure_accel(t()) :: t()
  def ensure_accel(%__MODULE__{accel: %{}} = storage), do: storage

  def ensure_accel(%__MODULE__{} = storage) do
    %{storage | accel: build_accel(storage.macro_headers, storage.refined_cells)}
  end

  # 从 canonical list 派生 accel。headers list 长度恒为 4096（normalize 保证），
  # refined list 顺序即 payload_index 升序（pool append 语义）。
  defp build_accel(macro_headers, refined_cells) do
    %{
      headers_array: :array.from_list(macro_headers),
      refined_by_payload: refined_by_payload_map(refined_cells)
    }
  end

  defp refined_by_payload_map(refined_cells) do
    refined_cells
    |> Enum.with_index()
    |> Map.new(fn {cell, payload_index} -> {payload_index, cell} end)
  end

  @doc """
  O(1) 读取 macro_index 处的 `MacroCellHeader`（经 accel `:array`）。

  storage 未建 accel 时回退 list `Enum.at`（O(n)）——调用方若在热循环里反复读，
  应先 `ensure_accel/1`。
  """
  @spec fetch_macro_header(t(), 0..4095) :: MacroCellHeader.t()
  def fetch_macro_header(%__MODULE__{accel: %{headers_array: arr}}, macro_index)
      when is_integer(macro_index) do
    :array.get(macro_index, arr)
  end

  def fetch_macro_header(%__MODULE__{macro_headers: headers}, macro_index)
      when is_integer(macro_index) do
    Enum.at(headers, macro_index)
  end

  @doc """
  O(1) 读取 `payload_index` 处的 `RefinedCellData`（经 accel map），无则 `nil`。

  storage 未建 accel 时回退 list `Enum.at`（O(n)）。
  """
  @spec fetch_refined_cell(t(), non_neg_integer()) :: RefinedCellData.t() | nil
  def fetch_refined_cell(%__MODULE__{accel: %{refined_by_payload: by_payload}}, payload_index)
      when is_integer(payload_index) do
    Map.get(by_payload, payload_index)
  end

  def fetch_refined_cell(%__MODULE__{refined_cells: refined_cells}, payload_index)
      when is_integer(payload_index) do
    Enum.at(refined_cells, payload_index)
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

    # 阶段2.5:入口已 normalize!（全量校验 + 建 accel）；本地写只替换一个已
    # normalize 的 header + append 一个已 normalize 的 block(都不触发 pool 重排,
    # macro/payload 顺序不变),用轻量 finalize（mark dirty + 刷 accel）替代出口
    # 全量 normalize! —— 输出逐字段等价,但不再重扫 4096 header。
    %{
      storage
      | macro_headers: List.replace_at(storage.macro_headers, macro_index, header),
        normal_blocks: storage.normal_blocks ++ [block]
    }
    |> finalize_local_write([macro_index], DirtyMacroBounds.reason_attribute_write())
  end

  # 阶段2.5:受信局部写的统一 finalize —— mark dirty(touched macro 集)+ 刷新 accel。
  # 调用前提:① storage 入口已 normalize!(全量校验 + accel 已建一次);② 本次只
  # 局部改写了 touched macro 对应的 header / payload,且改动的子结构已各自 normalize;
  # ③ 未触发 attribute_sets/tag_sets pool 的 canonical 重排(那条路径仍走 normalize!)。
  # 满足上述前提时,本 finalize 与出口 `normalize!()` 的输出逐字段一致,但 O(变更量)。
  defp finalize_local_write(%__MODULE__{} = storage, touched_macros, reason_flag) do
    dirty =
      Enum.reduce(touched_macros, storage.dirty_bounds, fn macro_index, acc ->
        DirtyMacroBounds.add_macro(acc, macro_index, reason_flag)
      end)

    refresh_accel(%{storage | dirty_bounds: dirty})
  end

  @doc "Puts multiple solid normal blocks and normalizes the chunk once."
  @spec put_solid_blocks(t(), [{integer() | term(), NormalBlockData.t() | map(), keyword()}]) ::
          t()
  def put_solid_blocks(%__MODULE__{} = storage, entries) when is_list(entries) do
    storage = normalize!(storage)
    base_payload_index = length(storage.normal_blocks)

    {macro_headers, blocks, dirty_bounds} =
      entries
      |> Enum.with_index()
      |> Enum.reduce(
        {storage.macro_headers, [], storage.dirty_bounds},
        fn {{macro_index_or_coord, block, opts}, offset}, {headers, acc_blocks, dirty} ->
          macro_index = Types.macro_index_or_coord!(macro_index_or_coord)
          block = NormalBlockData.normalize!(block)
          payload_index = base_payload_index + offset

          header =
            MacroCellHeader.solid(payload_index,
              flags: Keyword.get(opts, :flags, 0),
              environment_index:
                Keyword.get(opts, :environment_index, MacroCellHeader.no_index()),
              cell_version: Keyword.get(opts, :cell_version, 0),
              cell_hash: Keyword.get(opts, :cell_hash, 0)
            )

          dirty =
            DirtyMacroBounds.add_macro(
              dirty,
              macro_index,
              DirtyMacroBounds.reason_attribute_write()
            )

          {List.replace_at(headers, macro_index, header), [block | acc_blocks], dirty}
        end
      )

    # 阶段2.5:batch 内已逐格 normalize header/block 并累加 dirty;出口只刷 accel
    # （未碰 attribute/tag pool,顺序不变），替代全量 normalize! 的 4096 趟重扫。
    %{
      storage
      | macro_headers: macro_headers,
        normal_blocks: storage.normal_blocks ++ Enum.reverse(blocks),
        dirty_bounds: dirty_bounds
    }
    |> refresh_accel()
  end

  # ----------------------------------------------------------------------------
  # Phase 5.E — dirty tracking helpers
  # ----------------------------------------------------------------------------

  @doc """
  Public helper to mark a single macro cell dirty with a reason flag.

  Phase 5.E ChunkProcess uses this to fan dirty bits in from non-`Storage`
  paths (e.g. subscriber set changes, cross-chunk boundary fences, catalog
  bumps). Storage mutation paths above already self-mark.
  """
  @spec mark_macro_dirty(t(), integer() | term(), 0..0xFFFF) :: t()
  def mark_macro_dirty(%__MODULE__{} = storage, macro_index_or_coord, reason_flag) do
    %{
      storage
      | dirty_bounds:
          DirtyMacroBounds.add_macro(storage.dirty_bounds, macro_index_or_coord, reason_flag)
    }
  end

  @doc "Clears the per-chunk dirty bounds (Phase 5.E tick consumed them)."
  @spec clear_dirty_bounds(t()) :: t()
  def clear_dirty_bounds(%__MODULE__{} = storage) do
    %{storage | dirty_bounds: DirtyMacroBounds.empty()}
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

    # 阶段2.5:仅替换一个已 normalize 的 empty header(未碰 pool/顺序),轻量 finalize。
    %{storage | macro_headers: List.replace_at(storage.macro_headers, macro_index, header)}
    |> finalize_local_write([macro_index], DirtyMacroBounds.reason_attribute_write())
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
    # 阶段2.5:入口 normalize! 已建 accel,随机读 O(1)。
    header = fetch_macro_header(storage, macro_index)

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
        cell = fetch_refined_cell(storage, header.payload_index)
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
        # 阶段2.5:入口 normalize! 已建 accel,随机读 O(1)。
        header = fetch_macro_header(storage, macro_index)

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
            cell = fetch_refined_cell(storage, header.payload_index)
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
    # 阶段2.5:入口 normalize! 已建 accel,随机读 O(1)。
    header = fetch_macro_header(storage, macro_index)

    cond do
      header.mode == MacroCellHeader.cell_mode_empty() ->
        storage

      header.mode == MacroCellHeader.cell_mode_solid_block() ->
        raise ArgumentError,
          message:
            "cannot_micro_edit_solid_macro: macro #{macro_index} is in :solid mode; " <>
              "Phase 1c v1 only supports empty ↔ refined transitions"

      header.mode == MacroCellHeader.cell_mode_refined() ->
        cell = fetch_refined_cell(storage, header.payload_index)
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
    storage = ensure_accel(storage)
    header = macro_header_at(storage, macro_index_or_coord)

    if header.mode == MacroCellHeader.cell_mode_refined() do
      # 阶段2.5:O(1) 经 accel map,替代 O(n) Enum.at。
      fetch_refined_cell(storage, header.payload_index)
    else
      nil
    end
  end

  @doc "Reads one macro header by local macro coord or macro index."
  @spec macro_header_at(t(), integer() | term()) :: MacroCellHeader.t()
  def macro_header_at(%__MODULE__{} = storage, macro_index_or_coord) do
    storage = ensure_accel(storage)
    macro_index = Types.macro_index_or_coord!(macro_index_or_coord)
    # 阶段2.5:O(1) 经 accel :array,替代 O(n) Enum.at。
    fetch_macro_header(storage, macro_index)
  end

  @doc "Reads the normal-block payload for a solid macro cell, or nil."
  @spec normal_block_at(t(), integer() | term()) :: NormalBlockData.t() | nil
  def normal_block_at(%__MODULE__{} = storage, macro_index_or_coord) do
    storage = ensure_accel(storage)
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
  # Phase 5.C — high-level attribute write API
  # ----------------------------------------------------------------------------

  @doc """
  Phase 5.C 高层 API：按 attribute name 写入 attribute 到 cell 的
  attribute_set。

  路径：
    1. `AttributeCatalog.lookup_by_name(name)` → 拿 id + value_type + min/max
       + merge_rule（缺失 raise `:catalog_miss`）。
    2. 按 value_type 校验 value 在 `[min_value, max_value]`（fixed32 Q16.16
       范围按 raw int32 比较）。
    3. 读取 cell（macro_index_or_coord）的当前 NormalBlockData：
       - cell 必须是 `:solid` mode（Phase 5.C 简化路径，C-7 选项 1：要求
         caller 先 `put_solid_block`）。`:empty` / `:refined` 都 raise
         `:cell_not_solid`。Phase 5.D 接 cell mode 自动转换。
    4. 读 `block.attribute_set_ref`：
       - `0` → 构造单 entry 的新 AttributeSet。
       - 非零 → 取出 pool 中既有 set，**用 key_id 替换** matching entry
         (override 语义)；其余 entry 保留。
    5. `intern_attribute_set/2` 拿新 ref（结构等价复用旧 ref）。
    6. 更新 block.attribute_set_ref → put_solid_block 写回（替换 block，
       cell_version 由 caller 在 opts 中提供，默认保留旧 header 的 cell_version
       / cell_hash 因为这是同一 macro 的更新）。

  返回新 storage struct（已 normalize!）。

  Options:
    * `:cell_version` — replace the macro header cell version after the write.
    * `:cell_hash` — replace the macro header cell hash after the write.
    * `:flags` — replace the macro header flags after the write.

  **注意**：本 API 写入 NormalBlockData.attribute_set_ref。Phase 5.C 不处理
  refined cell 的 attribute_set（每条 MicroLayer 各有 attribute_set_ref），
  那条路径在 Phase 5.D 才会接入。

  `merge_rule` 字段从 catalog 取出但本 commit **不**消费——它在 Phase 5.D 五层
  effective value 解析时才生效。本 API 始终走"在 attribute_set 内 override
  同 key_id 的 entry"语义（覆盖性 put），与 wire-level AttributeSet 唯一 key_id
  约束（每条 set 内 key_id 唯一）保持一致。
  """
  @spec put_attribute_for_cell(t(), integer() | term(), String.t(), integer(), keyword()) :: t()
  def put_attribute_for_cell(
        %__MODULE__{} = storage,
        macro_index_or_coord,
        attr_name,
        value,
        opts \\ []
      )
      when is_binary(attr_name) and is_integer(value) do
    storage = normalize!(storage)
    macro_index = Types.macro_index_or_coord!(macro_index_or_coord)

    defn =
      case AttributeCatalog.lookup_by_name(attr_name) do
        {:ok, _id, defn} ->
          defn

        {:error, :not_found} ->
          raise ArgumentError,
                "put_attribute_for_cell: attribute name #{inspect(attr_name)} not in " <>
                  "catalog (AttributeCatalog.lookup_by_name → :not_found)"
      end

    if value < defn.min_value or value > defn.max_value do
      raise ArgumentError,
            "put_attribute_for_cell: value #{inspect(value)} out of range " <>
              "[#{defn.min_value}, #{defn.max_value}] for attribute " <>
              "#{inspect(attr_name)} (id=#{defn.id})"
    end

    header = Enum.at(storage.macro_headers, macro_index)

    cond do
      header.mode == MacroCellHeader.cell_mode_solid_block() ->
        block = Enum.at(storage.normal_blocks, header.payload_index)
        new_entry = %AttributeEntry{key_id: defn.id, value_type: defn.value_type, value: value}

        merged_set = merge_entry_into_set(storage, block.attribute_set_ref, new_entry)
        {storage, new_ref} = intern_attribute_set(storage, merged_set)

        updated_block = %{block | attribute_set_ref: new_ref}
        updated_header = update_macro_header_metadata(header, opts)

        %{
          storage
          | macro_headers: List.replace_at(storage.macro_headers, macro_index, updated_header),
            normal_blocks:
              List.replace_at(storage.normal_blocks, header.payload_index, updated_block)
        }
        |> mark_macro_dirty(macro_index, DirtyMacroBounds.reason_attribute_write())
        |> normalize!()

      header.mode == MacroCellHeader.cell_mode_empty() ->
        raise ArgumentError,
              "put_attribute_for_cell: macro #{macro_index} is in :empty mode; " <>
                "Phase 5.C requires caller to put_solid_block first (Phase 5.D 接 " <>
                "cell mode 自动转换)"

      header.mode == MacroCellHeader.cell_mode_refined() ->
        raise ArgumentError,
              "put_attribute_for_cell: macro #{macro_index} is in :refined mode; " <>
                "Phase 5.C only supports solid cells (refined per-MicroLayer " <>
                "attribute path 推到 Phase 5.D)"

      true ->
        raise ArgumentError, "unknown macro mode: #{header.mode}"
    end
  end

  defp update_macro_header_metadata(%MacroCellHeader{} = header, opts) do
    %{
      header
      | flags: Keyword.get(opts, :flags, header.flags),
        cell_version: Keyword.get(opts, :cell_version, header.cell_version),
        cell_hash: Keyword.get(opts, :cell_hash, header.cell_hash)
    }
    |> MacroCellHeader.normalize!()
  end

  # Override semantics: 取出 ref 指向的现有 AttributeSet（ref=0 → 空 entries），
  # 用 key_id 替换 matching entry，其余 entry 保留；AttributeSet.normalize! 会
  # 自动 sort + 拒绝重复 key_id。
  defp merge_entry_into_set(_storage, 0, %AttributeEntry{} = new_entry) do
    %AttributeSet{entries: [new_entry]}
  end

  defp merge_entry_into_set(%__MODULE__{} = storage, ref, %AttributeEntry{} = new_entry)
       when is_integer(ref) and ref > 0 do
    existing = Enum.at(storage.attribute_sets, ref - 1)

    if is_nil(existing) do
      raise ArgumentError,
            "put_attribute_for_cell: attribute_set_ref #{ref} points outside pool " <>
              "(pool size #{length(storage.attribute_sets)})"
    end

    other_entries =
      Enum.reject(existing.entries, fn entry -> entry.key_id == new_entry.key_id end)

    AttributeSet.normalize!(%{entries: [new_entry | other_entries]})
  end

  # ----------------------------------------------------------------------------
  # Phase 5.D — effective_attribute_at（5 层 merge_rule 解析，L4 暂不接 → 4 层）
  # ----------------------------------------------------------------------------

  @merge_override 0x01
  @merge_add_delta 0x02
  @merge_max 0x03
  @merge_min 0x04
  @merge_material_default 0x05

  @doc """
  Phase 5.D 高层 API：按 macro cell + attribute 解析 **effective value**，应用
  4 层 merge_rule（L4 object-part attribute 暂不接，推到 Phase 5.D.2）。

  实施草案 `docs/plans/2026-05-13-phase5d-five-tier-merge-rule.md`
  D-1..D-5 全部推荐方案（用户 2026-05-13 approve）：
    * D-1 override 优先级 **L3 > L2 > L1 > L5**（micro > macro override > material default > environment）
    * D-2 add_delta L1 作为 base，L2/L3/L5 是 delta 累加
    * D-3 temperature_delta / moisture_delta 字段 + attribute_set 双路径 sum 累加（向后兼容）
    * D-4 Phase 5.D 暂不接 L4，实际只实施 4 层
    * D-5 API macro 粒度

  四层数据源：
    * L1 material_default = `AttributeDefinition.default_value`
    * L2 normal_block_override:
        - temperature/moisture: `NormalBlockData.temperature_delta / moisture_delta`
          + `NormalBlockData.attribute_set_ref` → AttributeSet 中 entry（**sum**）
        - 其它 attribute: `NormalBlockData.attribute_set_ref` → AttributeSet 中 entry
    * L3 refined_micro_override: refined_cell.layers[*].attribute_set_ref →
        AttributeSet 中 entry。多 layer 处理：
        - `add_delta` / `max` / `min`：聚合所有 layer 的值（sum / max / min）
        - `override`：取 canonical 序的 first layer 中有该 attribute 的 entry
    * L4 object_part_attribute：Phase 5.D 暂不接（推到 5.D.2）
    * L5 environment_summary: `MacroEnvironmentSummary.current_temperature /
       current_moisture`（仅 temperature / moisture 适用）

  merge_rule 合并语义：

      override:         L3 > L2 > L1 > L5（取最高 priority 层有值的，否则次高，最后 default）
      add_delta:        L1 + (L2.delta ?? 0) + (L3.delta_sum ?? 0) + (L5.delta ?? 0)
      max / min:        max/min over available layers (L1, L2, L3, L5)
      material_default: only L1

  边界：
    * effective_value 超出 `[min_value, max_value]` → **clip** 到边界（草案 §7 推荐策略）
    * 未知 attr_name → raise `ArgumentError`
    * 不合法 `macro_index_or_coord` → raise

  Options:
    * `:catalog` — AttributeCatalog server name / pid（默认模块名 singleton），
      用于测试时注入 ad-hoc catalog（含 override / max / min merge_rule 的测试 attribute）。

  Returns：raw int32 value (按 value_type 解释，i16/u16/fixed32/enum8/bitset32 都返回 raw int)。
  """
  @spec effective_attribute_at(
          t(),
          integer() | term(),
          String.t() | non_neg_integer(),
          keyword()
        ) :: integer()
  def effective_attribute_at(
        %__MODULE__{} = storage,
        macro_index_or_coord,
        attr_name_or_id,
        opts \\ []
      ) do
    storage = normalize!(storage)
    effective_attribute_at_normalized(storage, macro_index_or_coord, attr_name_or_id, opts)
  end

  @doc """
  Same as `effective_attribute_at/4`, but assumes `storage` is already
  normalized.

  Field kernels call this inside hot per-cell loops after their tick context has
  normalized the chunk once. Call `effective_attribute_at/4` at API boundaries
  where compatible maps or hand-built structs may still need validation.
  """
  @spec effective_attribute_at_normalized(
          t(),
          integer() | term(),
          String.t() | non_neg_integer(),
          keyword()
        ) :: integer()
  def effective_attribute_at_normalized(
        %__MODULE__{} = storage,
        macro_index_or_coord,
        attr_name_or_id,
        opts \\ []
      ) do
    macro_index = Types.macro_index_or_coord!(macro_index_or_coord)
    catalog = Keyword.get(opts, :catalog, AttributeCatalog)

    defn = catalog_lookup!(catalog, attr_name_or_id)

    # 阶段2.5:field kernel 热循环逐格读 → 经 accel O(1)(storage 已 normalize)。
    header = fetch_macro_header(storage, macro_index)

    # 抽取 4 层各自的值（layer 不提供该 attribute 时返回 :not_found）
    material_default = material_default_value(storage, header, defn)
    l1 = {:found, material_default}
    l2 = extract_l2(storage, header, defn)
    l3 = extract_l3(storage, header, defn)
    l5 = extract_l5(storage, header, defn)

    effective =
      case defn.merge_rule do
        @merge_material_default ->
          # 仅 L1
          material_default

        @merge_override ->
          # L3 > L2 > L1 > L5
          first_value([l3, l2, l1, l5])

        @merge_add_delta ->
          # L1 + (L2.delta ?? 0) + (L3.delta_sum ?? 0) + (L5.delta ?? 0)
          add_delta_layers(l1, l2, l3, l5)

        @merge_max ->
          # max(available layers)
          aggregate_min_max([l1, l2, l3, l5], &max/2)

        @merge_min ->
          # min(available layers)
          aggregate_min_max([l1, l2, l3, l5], &min/2)

        other ->
          raise ArgumentError,
                "effective_attribute_at: unknown merge_rule #{inspect(other)} for attribute " <>
                  "#{inspect(attr_name_or_id)}"
      end

    clip_to_range(effective, defn.min_value, defn.max_value)
  end

  # ---- catalog lookup helpers -------------------------------------------------

  defp material_default_value(%__MODULE__{} = storage, %MacroCellHeader{} = header, defn) do
    material_id = material_id_for_header(storage, header)

    MaterialCatalog.default_attribute_value(material_id, defn.name, defn.default_value)
  end

  defp material_id_for_header(%__MODULE__{} = storage, %MacroCellHeader{} = header) do
    cond do
      header.mode == MacroCellHeader.cell_mode_solid_block() ->
        case Enum.at(storage.normal_blocks, header.payload_index) do
          %NormalBlockData{material_id: material_id} -> material_id
          _other -> nil
        end

      header.mode == MacroCellHeader.cell_mode_refined() ->
        case fetch_refined_cell(storage, header.payload_index) do
          %RefinedCellData{layers: [%MicroLayer{material_id: material_id} | _]} -> material_id
          _other -> nil
        end

      true ->
        nil
    end
  end

  defp catalog_lookup!(catalog, attr_name) when is_binary(attr_name) do
    case AttributeCatalog.lookup_by_name(catalog, attr_name) do
      {:ok, _id, defn} ->
        defn

      {:error, :not_found} ->
        raise ArgumentError,
              "effective_attribute_at: attribute name #{inspect(attr_name)} not in catalog " <>
                "(AttributeCatalog.lookup_by_name → :not_found)"
    end
  end

  defp catalog_lookup!(catalog, attr_id) when is_integer(attr_id) and attr_id >= 0 do
    case AttributeCatalog.lookup_by_id(catalog, attr_id) do
      {:ok, defn} ->
        defn

      {:error, :not_found} ->
        raise ArgumentError,
              "effective_attribute_at: attribute id #{attr_id} not in catalog " <>
                "(AttributeCatalog.lookup_by_id → :not_found)"
    end
  end

  defp catalog_lookup!(_catalog, other) do
    raise ArgumentError,
          "effective_attribute_at: attr_name_or_id must be String or non-negative integer, " <>
            "got: #{inspect(other)}"
  end

  # ---- L2 (normal block override) extraction ---------------------------------

  # L2 仅在 solid mode 下生效（refined / empty cell 无 normal_block 路径）。
  # D-3 (a1): temperature/moisture 的 typed 字段 + attribute_set 中同 attribute
  # 的 entry **两条 sum 累加**（向后兼容）。
  defp extract_l2(%__MODULE__{} = storage, %MacroCellHeader{} = header, defn) do
    cond do
      header.mode == MacroCellHeader.cell_mode_solid_block() ->
        block = Enum.at(storage.normal_blocks, header.payload_index)
        field_val = extract_normal_block_typed_field(block, defn)
        set_val = extract_attribute_from_ref(storage, block.attribute_set_ref, defn)
        combine_l2(field_val, set_val)

      true ->
        :not_found
    end
  end

  # D-3 (a1)：合并 `temperature_delta` / `moisture_delta` 字段值与 attribute_set
  # 中同 attribute 的 entry —— 两者都生效，**sum 累加**。其余 attribute 仅走
  # attribute_set 路径。
  defp combine_l2(:not_found, :not_found), do: :not_found
  defp combine_l2({:found, v}, :not_found), do: {:found, v}
  defp combine_l2(:not_found, {:found, v}), do: {:found, v}
  defp combine_l2({:found, a}, {:found, b}), do: {:found, a + b}

  # 仅 temperature / moisture 有 typed 字段；其他 attribute 返回 :not_found。
  # 字段值是 i16 raw delta（按 D-3 (a1) 等同于 attribute_set 中 fixed32 delta 的同
  # 单位 raw int，sum 累加；caller 责任保证两路径单位一致 —— Phase 5.C catalog
  # temperature/moisture 都是 fixed32 Q16.16，temperature_delta 字段被解释为
  # Q16.16 raw int32 delta（i16 表示范围内）。
  defp extract_normal_block_typed_field(block, defn) do
    case defn.name do
      "temperature" ->
        if block.temperature_delta != 0, do: {:found, block.temperature_delta}, else: :not_found

      "moisture" ->
        if block.moisture_delta != 0, do: {:found, block.moisture_delta}, else: :not_found

      _ ->
        :not_found
    end
  end

  # ---- L3 (refined micro override) extraction --------------------------------

  # 多 layer 处理（草案 §7 风险段）：
  #   * add_delta：sum 所有 layer 中该 attribute 的 delta（symmetric L1+L3 path）
  #   * max / min：取所有 layer 中该 attribute 的极值
  #   * override：取 canonical 序的 first layer with attribute（不累加）
  #   * material_default：忽略 L3
  defp extract_l3(%__MODULE__{} = storage, %MacroCellHeader{} = header, defn) do
    if header.mode == MacroCellHeader.cell_mode_refined() do
      cell = fetch_refined_cell(storage, header.payload_index)

      layer_values =
        cell.layers
        |> Enum.flat_map(fn layer ->
          case extract_attribute_from_ref(storage, layer.attribute_set_ref, defn) do
            {:found, v} -> [v]
            :not_found -> []
          end
        end)

      case layer_values do
        [] ->
          :not_found

        values ->
          case defn.merge_rule do
            @merge_add_delta -> {:found, Enum.sum(values)}
            @merge_max -> {:found, Enum.max(values)}
            @merge_min -> {:found, Enum.min(values)}
            # override / material_default：取 first layer with attribute（canonical 序）
            _ -> {:found, hd(values)}
          end
      end
    else
      :not_found
    end
  end

  # ---- L5 (environment summary) extraction -----------------------------------

  # L5 仅 temperature / moisture 适用（既有 MacroEnvironmentSummary 结构字段：
  # `current_temperature` / `current_moisture` i16 raw delta）。其它 attribute
  # 返回 :not_found。
  defp extract_l5(%__MODULE__{} = storage, %MacroCellHeader{} = header, defn) do
    no_index = MacroCellHeader.no_index()

    if header.environment_index == no_index do
      :not_found
    else
      summary = Enum.at(storage.environment_summaries, header.environment_index)

      cond do
        is_nil(summary) ->
          :not_found

        defn.name == "temperature" ->
          if summary.current_temperature != 0,
            do: {:found, summary.current_temperature},
            else: :not_found

        defn.name == "moisture" ->
          if summary.current_moisture != 0,
            do: {:found, summary.current_moisture},
            else: :not_found

        true ->
          :not_found
      end
    end
  end

  # ---- AttributeSet entry extraction ------------------------------------------

  # 从指定 attribute_set_ref（1-indexed pool 索引，0 = no set）中按 defn.id 抽取
  # 对应 entry 的 value。
  defp extract_attribute_from_ref(_storage, 0, _defn), do: :not_found

  defp extract_attribute_from_ref(%__MODULE__{} = storage, ref, defn)
       when is_integer(ref) and ref > 0 do
    case Enum.at(storage.attribute_sets, ref - 1) do
      nil ->
        :not_found

      %AttributeSet{entries: entries} ->
        case Enum.find(entries, fn entry -> entry.key_id == defn.id end) do
          nil -> :not_found
          entry -> {:found, entry.value}
        end
    end
  end

  # ---- merge helpers ----------------------------------------------------------

  # 返回 layers 列表中第一个 `{:found, value}` 的 value。layers 顺序即 priority 高到低。
  # L1 永远是 `{:found, default_value}`，所以列表中至少有一个 :found，结果不会 nil。
  defp first_value([{:found, v} | _rest]), do: v
  defp first_value([:not_found | rest]), do: first_value(rest)

  # add_delta：L1 base + 所有 delta layer 累加（:not_found 视为 0）。
  defp add_delta_layers({:found, base}, l2, l3, l5) do
    base + delta_or_zero(l2) + delta_or_zero(l3) + delta_or_zero(l5)
  end

  defp delta_or_zero({:found, v}), do: v
  defp delta_or_zero(:not_found), do: 0

  # max / min over available layers (L1 always available)。
  defp aggregate_min_max(layers, reducer) do
    layers
    |> Enum.flat_map(fn
      {:found, v} -> [v]
      :not_found -> []
    end)
    |> Enum.reduce(reducer)
  end

  # clip 到 [min, max]（草案 §7 风险段当前推荐策略）。
  defp clip_to_range(value, min_v, max_v) do
    cond do
      value < min_v -> min_v
      value > max_v -> max_v
      true -> value
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
    header = fetch_macro_header(storage, macro_index)

    if header.mode == MacroCellHeader.cell_mode_refined() do
      cell = fetch_refined_cell(storage, header.payload_index)
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
  Returns true when a local micro slot is occupied by authoritative voxel truth.

  Empty macro cells are unoccupied. Solid macro cells occupy every one of their
  512 micro slots. Refined macro cells read their `RefinedCellData`
  `occupancy_words`.
  """
  @spec micro_slot_occupied?(t(), integer() | term(), 0..511) :: boolean()
  def micro_slot_occupied?(%__MODULE__{} = storage, macro_index_or_coord, micro_slot_index) do
    storage = normalize!(storage)
    macro_index = Types.macro_index_or_coord!(macro_index_or_coord)
    micro_slot_index = micro_slot!(micro_slot_index)
    header = fetch_macro_header(storage, macro_index)

    cond do
      header.mode == MacroCellHeader.cell_mode_empty() ->
        false

      header.mode == MacroCellHeader.cell_mode_solid_block() ->
        true

      header.mode == MacroCellHeader.cell_mode_refined() ->
        storage
        |> fetch_refined_cell(header.payload_index)
        |> slot_currently_occupied?(micro_slot_index)

      true ->
        false
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

    storage = refresh_accel(%{storage | refined_cells: new_refined_cells})

    # Step 2: aggregate chunk-level ChunkObjectRef[] across refined cells.
    new_chunk_refs = derive_chunk_object_refs(storage)

    %{storage | object_refs: new_chunk_refs}
  end

  @doc """
  阶段2.5 增量重算 object_refs —— 只在 `dirty_bounds` 圈定的 dirty macro 集合内
  重建 per-cell `ObjectCoverRef[]`，再整体重聚合 chunk-level `ChunkObjectRef[]`。

  根因修复：原 `refresh_chunk_object_refs/1` 每次提交全量重扫 4096 header（且内层
  `Enum.at(refined_cells, payload_index)` 是 O(n) 线性扫）。本变体把 per-cell 重算
  收敛到 dirty macro（热路径单格改动 = O(1) refined cell 重算），并用 accel map
  做 O(1) payload→cell 查找。

  语义与全量 `refresh_chunk_object_refs/1` 在 dirty 集覆盖所有真实变更时**等价**：
  调用方（`trust_transform!` 路径）保证每次改动都 mark dirty。`dirty_bounds` 为空
  时 per-cell 不动，仅重聚合 chunk-level（廉价，保证与 cell 真相一致）。

  **不**消费 / 清空 `dirty_bounds`（persist / tick 路径另行 clear）。
  """
  @spec refresh_chunk_object_refs_incremental(t()) :: t()
  def refresh_chunk_object_refs_incremental(%__MODULE__{} = storage) do
    storage = ensure_accel(storage)
    dirty = storage.dirty_bounds

    storage =
      if DirtyMacroBounds.empty?(dirty) do
        storage
      else
        recompute_dirty_cell_object_refs(storage, dirty)
      end

    %{storage | object_refs: derive_chunk_object_refs(storage)}
  end

  # 只对 dirty AABB 内、且处于 refined mode 的 macro 重建其 cell.object_refs。
  defp recompute_dirty_cell_object_refs(%__MODULE__{} = storage, %DirtyMacroBounds{} = dirty) do
    refined_mode = MacroCellHeader.cell_mode_refined()
    {min_x, min_y, min_z} = dirty.min_macro
    {max_x, max_y, max_z} = dirty.max_macro

    # 收集 dirty 区间内 refined header 的 payload_index → 新 object_refs。
    updates =
      for z <- min_z..(max_z - 1)//1,
          y <- min_y..(max_y - 1)//1,
          x <- min_x..(max_x - 1)//1,
          macro_index = Types.macro_index!({x, y, z}),
          header = fetch_macro_header(storage, macro_index),
          header.mode == refined_mode,
          into: %{} do
        cell = fetch_refined_cell(storage, header.payload_index)
        {header.payload_index, derive_cell_object_refs(cell.layers)}
      end

    if updates == %{} do
      storage
    else
      new_refined_cells =
        storage.refined_cells
        |> Enum.with_index()
        |> Enum.map(fn {cell, payload_index} ->
          case Map.fetch(updates, payload_index) do
            {:ok, object_refs} -> %{cell | object_refs: object_refs}
            :error -> cell
          end
        end)

      refresh_accel(%{storage | refined_cells: new_refined_cells})
    end
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
    storage = ensure_accel(storage)
    refined_mode = MacroCellHeader.cell_mode_refined()

    # %{object_id => %{macro_index => or'd mask_words across all parts}}
    #
    # 阶段2.5:内层 `Enum.at(refined_cells, payload_index)` O(n) 线性扫已换成
    # accel map 的 O(1) `fetch_refined_cell/2`。外层仍单趟扫 headers（O(4096)
    # 一次,非 ×Enum.at),只对 refined header 取 cell。
    aggregated =
      storage.macro_headers
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {header, macro_index}, acc ->
        if header.mode == refined_mode do
          cell = fetch_refined_cell(storage, header.payload_index)

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

  @doc """
  边界归一化（full validation）—— 对 storage 结构或兼容 map 做**全量**字段校验
  与 canonical 排序，并重建 accel 加速索引。

  阶段2.5 收口纪律：`normalize!`（全量、O(4096 headers + pools)）**只在边界**
  发生一次——`decode` / 外部注入 / `new` / 公共 API 入口。内部局部变更应走
  `trust_transform!/3`（只校验改动的格），不再每改一格全量重扫。

  `accel`（派生加速索引）在出口由 canonical list 重建，因此输入中携带的任何
  `accel` 都被忽略——它永远不是真相源。
  """
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

    refined_cells =
      normalize_list!(
        fetch(attrs, :refined_cells, []),
        &RefinedCellData.normalize!/1,
        :refined_cells
      )

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
      refined_cells: refined_cells,
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
        DirtyMacroBounds.normalize!(fetch(attrs, :dirty_bounds, DirtyMacroBounds.empty())),
      accel: build_accel(macro_headers, refined_cells)
    }
  end

  # ----------------------------------------------------------------------------
  # 阶段2.5 — trusted transform（内部局部可信变换）
  #
  # 区别于 `normalize!` 的全量校验：`trust_transform!` 接收一个 mutator，mutator
  # 已经在受信内部以**已归一化的子结构**（`MacroCellHeader` / `RefinedCellData`
  # 都各自 normalize 过）局部改写 macro_headers / refined_cells / pools，并报告
  # 它**触碰过的 macro_index 集合**。本函数只：
  #
  #   1. 不重扫 4096 header（信任 mutator 维持其余格不变）；
  #   2. 用 canonical list 增量重建 accel（O(变更量)，list→array/map 仍 O(n) 但
  #      只发生一次，不是每改一格一趟）；
  #   3. 把触碰的 macro 并进 dirty_bounds（绑定后续增量 object_refs / persist）。
  #
  # 它**不**改变 macro_headers / refined_cells 的顺序（保持 macro_index / payload
  # 升序），所以 wire/hash 零漂移。
  # ----------------------------------------------------------------------------

  @doc """
  内部可信局部变换。`fun` 接收当前 storage，返回
  `{next_storage, touched_macro_indices, reason_flag}`：

    * `next_storage` —— 已局部改写 canonical list 的 storage（子结构需已
      normalize；本函数不再全量校验）；
    * `touched_macro_indices` —— 本次改动触碰的 macro_index 列表（用于 dirty
      bounds 增量与后续增量 object_refs）；
    * `reason_flag` —— `DirtyMacroBounds` reason bit。

  出口刷新 accel + 合并 dirty bounds。复杂度 O(变更量 + 一次 list→accel 派生)，
  **不是** N×全量 normalize。
  """
  @spec trust_transform!(t(), (t() -> {t(), [non_neg_integer()], 0..0xFFFF})) :: t()
  def trust_transform!(%__MODULE__{} = storage, fun) when is_function(fun, 1) do
    {next, touched, reason_flag} = fun.(storage)

    dirty =
      Enum.reduce(touched, next.dirty_bounds, fn macro_index, acc ->
        DirtyMacroBounds.add_macro(acc, macro_index, reason_flag)
      end)

    %{next | dirty_bounds: dirty}
    |> refresh_accel()
  end

  # 从当前 canonical list 重派生 accel（强制刷新，丢弃旧 accel）。
  defp refresh_accel(%__MODULE__{} = storage) do
    %{storage | accel: build_accel(storage.macro_headers, storage.refined_cells)}
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

    # 阶段2.5:header / cell 都已 normalize,append 不改 pool 顺序,轻量 finalize。
    %{
      storage
      | macro_headers: List.replace_at(storage.macro_headers, macro_index, header),
        refined_cells: storage.refined_cells ++ [cell]
    }
    |> finalize_local_write([macro_index], DirtyMacroBounds.reason_attribute_write())
  end

  defp replace_refined_cell(storage, macro_index, payload_index, cell, opts) do
    header_now = fetch_macro_header(storage, macro_index)

    header =
      MacroCellHeader.refined(payload_index,
        flags: Keyword.get(opts, :flags, header_now.flags),
        environment_index: Keyword.get(opts, :environment_index, header_now.environment_index),
        cell_version: Keyword.get(opts, :cell_version, header_now.cell_version),
        cell_hash: Keyword.get(opts, :cell_hash, header_now.cell_hash)
      )

    # 阶段2.5:header / cell 都已 normalize,replace_at 不改 pool 顺序,轻量 finalize。
    %{
      storage
      | macro_headers: List.replace_at(storage.macro_headers, macro_index, header),
        refined_cells: List.replace_at(storage.refined_cells, payload_index, cell)
    }
    |> finalize_local_write([macro_index], DirtyMacroBounds.reason_attribute_write())
  end

  defp downgrade_refined_to_empty(storage, macro_index, payload_index, opts) do
    # Match `clear_macro_cell/3`'s compaction policy: leave the orphaned
    # RefinedCellData in the pool (an empty-but-valid cell) and just flip
    # the macro header back to empty mode.
    header_now = fetch_macro_header(storage, macro_index)

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

    # 阶段2.5:header 置 empty、cell 置空(都已 normalize),replace_at 不改顺序,
    # 轻量 finalize 替代全量 normalize!。
    %{
      storage
      | macro_headers: List.replace_at(storage.macro_headers, macro_index, header),
        refined_cells: List.replace_at(storage.refined_cells, payload_index, empty_cell)
    }
    |> finalize_local_write([macro_index], DirtyMacroBounds.reason_attribute_write())
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
