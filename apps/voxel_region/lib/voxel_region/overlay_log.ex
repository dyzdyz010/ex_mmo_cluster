defmodule VoxelRegion.OverlayLog do
  @moduledoc """
  `VoxelRegion.World` 的 overlay 日志后端：一笔事务 `%{seq, entries, coarse}` 追加、启动重放、压实检查点。

  正式后端 `VoxelRegion.OverlayLog.Db`（DataService `voxel_overlay_log` 表，决策稿 §9 第 1 项）；
  `VoxelRegion.OverlayLog.File`（`<world_dir>/overlay.log` ETF 帧）只给不起数据库的测试用。

  表里一行 = 一个条目：kind 0 `cell`（0x77 kind0 线格式）、1 `region`（完整 VXR4）、2 `coarse`（粗格线格式），
  kind 3 为属性/余额元数据，kind 4 为结构格 afterimage（0x77 kind2）。
  `ordinal` 保持事务内顺序；旧的单格入口 `apply_edit` 产出的裸条目 `%{seq, coord, material, coarse}` 入表时归一成事务。
  """

  alias MmoContracts.Voxel.Codec

  @callback open(world_dir :: String.t(), content_version :: non_neg_integer()) :: term()
  @callback append(handle :: term(), transaction :: map()) :: :ok
  @callback replay(handle :: term()) :: [map()]
  @callback checkpoint(handle :: term(), transaction :: map()) :: :ok

  @doc """
  已部署日志里的设备记录键与撤下的账目（R8-04 增量 2／3）。回放用 `binary_to_term(_, [:safe])`，原子须已存在；现行代码里
  只有惰性加载的迁移模块还提到其中一些（`:circuit`），回放可能早于它加载。本模块在解码前已加载，这些字面量随之进入原子表。
  """
  def historical_atoms,
    do: [:circuit, :tool_id, :kind, :size, :anchor, :closed, :fault, :remaining_j, :voltage_v, :current_a, :power_w,
         :circuit_fed_j, :circuit_rejected_j, :circuit_cooling_j]

  @doc """
  日志元数据解码（两个后端共用）：调用本模块即保证上面的历史原子已在原子表里。拟态记录（`thermal.semblances`）的键
  （`mass_kg`、`age_s`、`kinetic_j` 等）只出现在惰性加载的 `VoxelRegion.Magic.Semblance` 里，冷重启的新 VM 回放时它可能还没加载，
  所以解码前先加载它（magic-inc2 首次双端实跑的冷重启即因此失败）。
  """
  def term(bytes) do
    {:module, _} = Code.ensure_loaded(VoxelRegion.Magic.Semblance)
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

    metadata = Map.take(txn,[:property_states,:epochs,:material_balances,:caster_energy,:material_supplies,:craft_ledger,:placed_by,:macro_owners,:protection,:prefab_instances,:phase_inventory,:thermal,:attachment_serial,:attachment_owners,:material_units_per_micro,:liquid_active])
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

  defp region_of({x, y, z}), do: {Integer.floor_div(x, 64), Integer.floor_div(y, 64), Integer.floor_div(z, 64)}

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
    def checkpoint(cv, txn), do: OverlayLogStore.replace(cv, OverlayLog.rows(txn))
  end

  defmodule File do
    @moduledoc "`<world_dir>/overlay.log`：`<<len::32, term_to_binary(txn)>>` 帧；只供不起数据库的测试。"
    @behaviour VoxelRegion.OverlayLog

    @impl true
    def open(world_dir, _cv), do: Path.join(world_dir, "overlay.log")

    @impl true
    def append(path, txn) do
      Elixir.File.mkdir_p!(Path.dirname(path))
      Elixir.File.write!(path, frame(txn), [:append])
    end

    @impl true
    def replay(path) do
      case Elixir.File.read(path) do
        {:ok, bytes} -> frames(bytes, [])
        {:error, :enoent} -> []
      end
    end

    @impl true
    def checkpoint(path, txn) do
      Elixir.File.write!(path <> ".tmp", frame(txn))
      Elixir.File.rename!(path <> ".tmp", path)
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
