defmodule VoxelRegion.OverlayLog do
  @moduledoc """
  `VoxelRegion.World` 的 overlay 日志后端：一笔事务 `%{seq, entries, coarse}` 追加、启动重放、压实检查点。

  正式后端 `VoxelRegion.OverlayLog.Db`（DataService `voxel_overlay_log` 表，决策稿 §9 第 1 项）；
  `VoxelRegion.OverlayLog.File`（`<world_dir>/overlay.log` ETF 帧）只给不起数据库的测试用。

  表里一行 = 一个条目：kind 0 `cell`（0x77 kind0 线格式）、1 `region`（完整 VXR4）、2 `coarse`（粗格线格式），
  kind 3 为属性/余额元数据，kind 4 为结构格 afterimage（0x77 kind2）。纯液体数量提交不写区域行，
  改记 kind 0 变化格与元数据里的 `liquid_units` 增量（`World.Edits` 日志表示，`World.Log.replay_liquid/2` 回放）。
  `ordinal` 保持事务内顺序；旧的单格入口 `apply_edit` 产出的裸条目 `%{seq, coord, material, coarse}` 入表时归一成事务。
  `checkpoint(handle, txn)` 原子替换截至 `txn.seq` 的前缀，保留更晚事务。append 由 World 串行调用；checkpoint 在 World 的
  检查点任务里执行，可与 append 并发（两个后端都只替换 ≤ seq 的前缀、保留并发追加的更晚事务）。
  """

  alias MmoContracts.Voxel.Codec

  @callback open(world_dir :: String.t(), content_version :: non_neg_integer()) :: term()
  @callback append(handle :: term(), transaction :: map()) :: :ok
  @callback replay(handle :: term()) :: [map()]
  @callback checkpoint(handle :: term(), transaction :: map()) :: :ok

  # M2a 页表（`m2a-page-store.md` §6）：段行与全局行由 `World.Pages` 编码；后端只存取。
  @doc "已发布的安全前缀（nil = 未初始化 / 未迁移）。"
  @callback prefix(handle :: term()) :: non_neg_integer() | nil
  @doc "删除高于前缀（nil = 全部）的段与全局行。"
  @callback clear_unpublished(handle :: term(), prefix :: non_neg_integer() | nil) :: :ok
  @doc "新增切点的一批段（发布前不可见）。"
  @callback write_pages(handle :: term(), cut_seq :: non_neg_integer(), rows :: [map()]) :: :ok
  @doc "同一原子单位里写最后一批段、全局行并推进前缀；前缀已不低于切点时 `{:error, {:prefix, p}}`。"
  @callback publish(handle :: term(), cut_seq :: non_neg_integer(), rows :: [map()], globals :: binary()) :: :ok | {:error, term()}
  @doc "恢复读取：`%{prefix: nil}` 或 `%{prefix, segments, globals, txns}`（txns = 前缀之后的日志事务）。"
  @callback load(handle :: term()) :: map()
  @doc "按前缀渐进删除一批，返回删掉的行数（0 = 已清完）。"
  @callback collect(handle :: term(), prefix :: non_neg_integer(), limit :: pos_integer()) :: non_neg_integer()

  # M2b 按需装页（`m2b-on-demand-pages.md`）：启动只读头部，页由装页任务按键读。
  @doc "启动读取：`%{prefix: nil}` 或 `%{prefix, globals, txns, activity: [%{region, payload}]}`（活动索引段的可见版本）。"
  @callback load_head(handle :: term(), activity_segment :: integer()) :: map()
  @doc "当前前缀下这些页（`{level, region}`）的可见段行与粗层片段行：`%{prefix, rows}`。"
  @callback read_pages(handle :: term(), keys :: [{integer(), tuple()}], fragment_segments :: [integer()]) :: map()
  @doc "身份定位：`[{kind, a, b}]` → `%{{kind, a, b} => %{root, home}}`。"
  @callback locate(handle :: term(), ids :: [tuple()]) :: map()
  @doc "当前前缀下有可见段的全部 `{level, region, segment}`。"
  @callback page_keys(handle :: term()) :: [tuple()]

  @doc """
  已部署日志里的设备记录键与撤下的账目（R8-04 增量 2／3）。回放用 `binary_to_term(_, [:safe])`，原子须已存在；现行代码里
  只有惰性加载的迁移模块还提到其中一些（`:circuit`），回放可能早于它加载。本模块在解码前已加载，这些字面量随之进入原子表。
  """
  def historical_atoms,
    do: [:circuit, :tool_id, :kind, :size, :anchor, :closed, :fault, :remaining_j, :voltage_v, :current_a, :power_w,
         :circuit_fed_j, :circuit_rejected_j, :circuit_cooling_j]

  # 元数据的写入方：World 与它的状态模块（`world/*.ex`，按文件名得模块名）、拟态记录。
  @metadata_modules [VoxelRegion.World, VoxelRegion.Magic.Semblance |
    for(file <- Path.wildcard(Path.join(__DIR__, "world/*.ex")),
      do: Module.concat(VoxelRegion.World, Macro.camelize(Path.basename(file, ".ex"))))]

  @doc """
  日志元数据解码（两个后端共用）：调用本模块即保证上面的历史原子已在原子表里。元数据的键是写入方模块里的字面量原子
  （拟态记录的 `mass_kg`、`age_s`，施法账的 `semblance_created_j` 等），冷重启的新 VM 回放时这些模块可能还没加载，
  所以解码前先加载全部写入方（magic-inc2 首次双端实跑的冷重启即因此失败；World 拆出状态模块后同理）。
  """
  def term(bytes) do
    Enum.each(@metadata_modules, &({:module, _} = Code.ensure_loaded(&1)))
    :erlang.binary_to_term(bytes, [:safe])
  end

  @doc "事务 → 行（legacy 裸条目先归一成事务）。"
  def rows(%{seq: seq, coord: _} = legacy), do: rows(Map.merge(%{seq: seq, entries: [%{legacy | coarse: []}], coarse: legacy.coarse}, Map.drop(legacy,[:seq,:coord,:material,:coarse])))

  def rows(%{seq: seq, entries: entries, coarse: coarse}=txn) do
    entry_rows =
      Enum.map(entries, fn
        %{structure: _,level: level,cell: cell}=entry ->
          %{seq: seq,kind: 4,level: level,region: region_of(cell),payload: IO.iodata_to_binary(Codec.encode_entry(entry))}
        %{payload: bytes} ->
          {:ok, h} = Codec.decode_payload_header(bytes)
          %{seq: seq, kind: 1, level: h.level, region: h.region, payload: bytes}

        cell ->
          %{seq: seq, kind: 0, level: 0, region: region_of(cell.coord), payload: IO.iodata_to_binary(Codec.encode_entry(cell))}
      end)

    coarse_rows =
      Enum.map(coarse, fn c ->
        %{seq: seq, kind: 2, level: c.level, region: region_of(c.cell), payload: IO.iodata_to_binary(Codec.encode_coarse(c))}
      end)

    metadata = Map.take(txn,[:property_states,:epochs,:material_balances,:caster_energy,:material_supplies,:craft_ledger,:food_ledger,:food_receipts,:placed_by,:macro_owners,:protection,:beacons,:beacon_attunements,:prefab_instances,:instances_delta,:phase_inventory,:thermal,:attachment_serial,:attachment_owners,:attachment_owners_delta,:material_units_per_micro,:liquid_active,:liquid_units,:interaction,:interaction_history,:interaction_floor])
    state_rows = if map_size(metadata)>0, do: [%{seq: seq,kind: 3,level: 0,region: {0,0,0},
      # ETF 自带压缩标记，旧 binary_to_term 读方直接恢复同一元数据。
      payload: :erlang.term_to_binary(metadata,[{:compressed,1}])}],else: []
    (entry_rows ++ coarse_rows ++ state_rows) |> Enum.with_index() |> Enum.map(fn {row, ordinal} -> Map.put(row, :ordinal, ordinal) end)
  end

  @doc "按 (seq, ordinal) 升序的行 → 事务列表（seq 升序）。"
  def transactions(rows) do
    rows
    |> Enum.chunk_by(& &1.seq)
    |> Enum.map(fn [%{seq: seq} | _] = chunk ->
      Enum.reduce(chunk, %{seq: seq, entries: [], coarse: []}, fn
        %{kind: 1, payload: bytes}, txn -> %{txn | entries: txn.entries ++ [%{seq: seq, payload: bytes}]}
        %{kind: kind, payload: bytes}, txn when kind in [0,4] -> {:ok, cell} = Codec.decode_entry(bytes); %{txn | entries: txn.entries ++ [cell]}
        %{kind: 3, payload: bytes}, txn -> Map.merge(txn,term(bytes))
        %{kind: 2, payload: bytes}, txn -> {:ok, c} = Codec.decode_coarse(bytes); %{txn | coarse: txn.coarse ++ [c]}
      end)
    end)
  end

  defp region_of(cell), do: VoxelRegion.Spatial.region_of(cell)

  defmodule Db do
    @moduledoc "DataService `voxel_overlay_log` 表后端（正式）。"
    @behaviour VoxelRegion.OverlayLog
    alias DataService.Voxel.OverlayLogStore
    alias VoxelRegion.OverlayLog

    @impl true
    def open(_world_dir, cv), do: cv

    @impl true
    def append(cv, txn), do: OverlayLogStore.append(cv, OverlayLog.rows(txn))

    @impl true
    def replay(cv), do: cv |> OverlayLogStore.read_all() |> OverlayLog.transactions()

    @impl true
    def checkpoint(cv, txn),
      do: OverlayLogStore.replace(cv, OverlayLog.rows(txn), through_seq: txn.seq)

    alias DataService.Voxel.PageStore

    @impl true
    def prefix(cv), do: PageStore.prefix(cv)

    @impl true
    def clear_unpublished(cv, prefix), do: PageStore.clear_unpublished(cv, prefix)

    @impl true
    def write_pages(cv, cut_seq, rows), do: PageStore.write(cv, cut_seq, rows)

    @impl true
    def publish(cv, cut_seq, rows, globals), do: PageStore.publish(cv, cut_seq, rows, globals)

    @impl true
    def load(cv) do
      case PageStore.load(cv) do
        %{prefix: nil} = none -> none
        loaded -> loaded |> Map.put(:txns, OverlayLog.transactions(loaded.log)) |> Map.delete(:log)
      end
    end

    @impl true
    def collect(cv, prefix, limit), do: PageStore.collect(cv, prefix, limit)

    @impl true
    def load_head(cv, activity_segment) do
      case PageStore.load_head(cv, activity_segment) do
        %{prefix: nil} = none -> none
        loaded -> loaded |> Map.put(:txns, OverlayLog.transactions(loaded.log)) |> Map.delete(:log)
      end
    end

    @impl true
    def read_pages(cv, keys, fragment_segments), do: PageStore.read_pages(cv, keys, fragment_segments)

    @impl true
    def locate(cv, ids), do: PageStore.locate(cv, ids)

    @impl true
    def page_keys(cv), do: PageStore.page_keys(cv)
  end

  defmodule File do
    @moduledoc """
    `<world_dir>/overlay.log`：`<<len::32, term_to_binary(txn)>>` 帧；只供不起数据库的测试。

    检查点写到旁边的 `overlay.log.checkpoint`（临时文件写完再改名，原子替换），回放 = 检查点 + 日志里 seq 更晚的帧。
    追加与检查点各写各的文件，检查点可在后台任务里执行而不丢 World 同时追加的帧（与 Db 后端“保留 seq > P 行”同一契约）。
    """
    @behaviour VoxelRegion.OverlayLog
    import Bitwise

    @impl true
    def open(world_dir, _cv), do: Path.join(world_dir, "overlay.log")

    @impl true
    def append(path, txn) do
      Elixir.File.mkdir_p!(Path.dirname(path))
      Elixir.File.write!(path, frame(txn), [:append])
    end

    @impl true
    def replay(path) do
      case read_frames(path <> ".checkpoint") do
        [checkpoint] -> [checkpoint | for(next <- read_frames(path), next.seq > checkpoint.seq, do: next)]
        [] -> read_frames(path)
      end
    end

    @impl true
    def checkpoint(path, txn) do
      Elixir.File.mkdir_p!(Path.dirname(path))
      Elixir.File.write!(path <> ".tmp", frame(txn))
      Elixir.File.rename!(path <> ".tmp", path <> ".checkpoint")
    end

    # 页表：`<world_dir>/pages.etf` = `%{prefix, segments: %{行键 => %{cut => payload}}, globals: %{cut => payload}}`，
    # 只由写回进程读写，整文件写临时文件再改名。日志帧不在这里删（World 并发追加），恢复只读前缀之后的帧。
    @impl true
    def prefix(path), do: read_pages(path).prefix

    @impl true
    def clear_unpublished(path, prefix) do
      floor = prefix || -1
      pages = read_pages(path)

      if pages.segments == %{} and pages.globals == %{},
        do: :ok,
        else: write_pages_file(path, %{pages | segments: Map.new(pages.segments, fn {k, v} -> {k, Map.filter(v, fn {c, _} -> c <= floor end)} end),
          globals: Map.filter(pages.globals, fn {c, _} -> c <= floor end)})
    end

    @impl true
    def write_pages(path, cut_seq, rows) do
      pages = read_pages(path)
      write_pages_file(path, put_rows(pages, cut_seq, rows))
    end

    @impl true
    def publish(path, cut_seq, rows, globals) do
      pages = read_pages(path)

      if pages.prefix != nil and pages.prefix >= cut_seq do
        {:error, {:prefix, pages.prefix}}
      else
        pages = put_rows(pages, cut_seq, rows)
        write_pages_file(path, %{pages | prefix: cut_seq, globals: Map.put(pages.globals, cut_seq, globals)})
      end
    end

    @impl true
    def load(path) do
      case read_pages(path) do
        %{prefix: nil} -> %{prefix: nil}

        %{prefix: p} = pages ->
          visible =
            for {key, versions} <- pages.segments, {cut, payload} = versions |> Enum.filter(&(elem(&1, 0) <= p)) |> Enum.max_by(&elem(&1, 0), fn -> {nil, nil} end),
                cut != nil, do: Map.put(key, :payload, payload)

          %{prefix: p, segments: visible, globals: Map.fetch!(pages.globals, p),
            txns: for(txn <- read_frames(path), txn.seq > p, do: txn)}
      end
    end

    @impl true
    def collect(path, prefix, _limit) do
      pages = read_pages(path)

      segments =
        Map.new(pages.segments, fn {key, versions} ->
          keep = versions |> Map.keys() |> Enum.filter(&(&1 <= prefix)) |> Enum.max(fn -> nil end)
          {key, Map.filter(versions, fn {c, _} -> c == keep or c > prefix end)}
        end)

      next = %{pages | segments: segments, globals: Map.filter(pages.globals, fn {c, _} -> c >= prefix end)}
      removed = count(pages) - count(next)
      if removed > 0, do: write_pages_file(path, next)
      removed
    end

    @impl true
    def load_head(path, activity_segment) do
      case read_pages(path) do
        %{prefix: nil} ->
          %{prefix: nil}

        %{prefix: p} = pages ->
          activity =
            for {%{level: 0, segment: ^activity_segment} = key, versions} <- pages.segments,
                {cut, payload} = visible(versions, p), cut != nil, do: %{region: key.region, payload: payload}

          %{prefix: p, globals: Map.fetch!(pages.globals, p), activity: activity,
            txns: for(txn <- read_frames(path), txn.seq > p, do: txn)}
      end
    end

    @impl true
    def read_pages(path, keys, fragment_segments) do
      pages = read_pages(path)
      p = pages.prefix
      wanted = MapSet.new(keys)

      rows =
        if p == nil do
          []
        else
          for {key, versions} <- pages.segments, page_row?(key, wanted, fragment_segments),
              {cut, payload} = visible(versions, p), cut != nil, do: Map.put(key, :payload, payload)
        end

      %{prefix: p, rows: rows}
    end

    @impl true
    def locate(path, ids) do
      locators = Map.get(read_pages(path), :locators, %{})
      for id <- ids, {:ok, value} <- [Map.fetch(locators, id)], into: %{}, do: {id, value}
    end

    @impl true
    def page_keys(path) do
      case read_pages(path) do
        %{prefix: nil} -> []
        %{prefix: p} = pages ->
          for {key, versions} <- pages.segments, {cut, _} = visible(versions, p), cut != nil,
              uniq: true, do: {key.level, key.region, key.segment}
      end
    end

    # 与 `DataService.Voxel.PageStore.read_pages/4` 同一选行规则。
    defp page_row?(%{level: level, region: {x, y, z} = region, segment: segment}, wanted, fragments) do
      fragment? = segment in fragments

      (level == 0 and MapSet.member?(wanted, {0, region})) or
        (fragment? and MapSet.member?(wanted, {0, region})) or
        (not fragment? and level > 0 and MapSet.member?(wanted, {level, region})) or
        (fragment? and MapSet.member?(wanted, {level, {Integer.floor_div(x, 1 <<< level), Integer.floor_div(y, 1 <<< level),
          Integer.floor_div(z, 1 <<< level)}}))
    end

    defp visible(versions, p), do: versions |> Enum.filter(&(elem(&1, 0) <= p)) |> Enum.max_by(&elem(&1, 0), fn -> {nil, nil} end)

    defp count(pages), do: Enum.sum(Enum.map(pages.segments, fn {_, v} -> map_size(v) end)) + map_size(pages.globals)

    defp put_rows(pages, cut_seq, rows) do
      {locators, rows} = Enum.split_with(rows, &Map.has_key?(&1, :locator))

      segments =
        Enum.reduce(rows, pages.segments, fn row, acc ->
          Map.update(acc, Map.delete(row, :payload), %{cut_seq => row.payload}, &Map.put(&1, cut_seq, row.payload))
        end)

      # 定位行只插入（与 PG 的 ON CONFLICT DO NOTHING 同义）。
      found = Map.get(pages, :locators, %{})
      located = Enum.reduce(locators, found, fn row, acc -> Map.put_new(acc, row.locator, Map.take(row, [:root, :home])) end)
      %{pages | segments: segments} |> Map.put(:locators, located)
    end

    defp read_pages(path) do
      case Elixir.File.read(pages_path(path)) do
        {:ok, bytes} -> :erlang.binary_to_term(bytes)
        {:error, :enoent} -> %{prefix: nil, segments: %{}, globals: %{}}
      end
    end

    defp write_pages_file(path, pages) do
      Elixir.File.mkdir_p!(Path.dirname(path))
      Elixir.File.write!(pages_path(path) <> ".tmp", :erlang.term_to_binary(pages))
      Elixir.File.rename!(pages_path(path) <> ".tmp", pages_path(path))
    end

    defp pages_path(path), do: Path.join(Path.dirname(path), "pages.etf")

    defp read_frames(path) do
      case Elixir.File.read(path) do
        {:ok, bytes} -> frames(bytes, [])
        {:error, :enoent} -> []
      end
    end

    defp frame(txn) do
      term = :erlang.term_to_binary(txn)
      <<byte_size(term)::32, term::binary>>
    end

    defp frames(<<>>, acc), do: Enum.reverse(acc)

    defp frames(<<len::32, term::binary-size(len), rest::binary>>, acc),
      do: frames(rest, [VoxelRegion.OverlayLog.term(term) | acc])
  end

end
