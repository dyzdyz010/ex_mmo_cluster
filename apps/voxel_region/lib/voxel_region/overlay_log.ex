defmodule VoxelRegion.OverlayLog do
  @moduledoc """
  `VoxelRegion.World` 的 overlay 日志后端：一笔事务 `%{seq, entries, coarse}` 追加、启动重放、压实检查点。

  正式后端 `VoxelRegion.OverlayLog.Db`（DataService `voxel_overlay_log` 表，决策稿 §9 第 1 项）；
  `VoxelRegion.OverlayLog.File`（`<world_dir>/overlay.log` ETF 帧）只给不起数据库的测试用。

  表里一行 = 一个条目：kind 0 `cell`（0x77 kind0 线格式）、1 `region`（完整 VXR4）、2 `coarse`（粗格线格式），
  `ordinal` 保持事务内顺序；旧的单格入口 `apply_edit` 产出的裸条目 `%{seq, coord, material, coarse}` 入表时归一成事务。
  """

  alias MmoContracts.Voxel.Codec

  @callback open(world_dir :: String.t(), content_version :: non_neg_integer()) :: term()
  @callback append(handle :: term(), transaction :: map()) :: :ok
  @callback replay(handle :: term()) :: [map()]
  @callback checkpoint(handle :: term(), transaction :: map()) :: :ok

  @doc "事务 → 行（legacy 裸条目先归一成事务）。"
  def rows(%{seq: seq, coord: _} = legacy), do: rows(%{seq: seq, entries: [%{legacy | coarse: []}], coarse: legacy.coarse})

  def rows(%{seq: seq, entries: entries, coarse: coarse}) do
    entry_rows =
      Enum.map(entries, fn
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

    (entry_rows ++ coarse_rows) |> Enum.with_index() |> Enum.map(fn {row, ordinal} -> Map.put(row, :ordinal, ordinal) end)
  end

  @doc "按 (seq, ordinal) 升序的行 → 事务列表（seq 升序）。"
  def transactions(rows) do
    rows
    |> Enum.chunk_by(& &1.seq)
    |> Enum.map(fn [%{seq: seq} | _] = chunk ->
      Enum.reduce(chunk, %{seq: seq, entries: [], coarse: []}, fn
        %{kind: 1, payload: bytes}, txn -> %{txn | entries: txn.entries ++ [%{seq: seq, payload: bytes}]}
        %{kind: 0, payload: bytes}, txn -> {:ok, cell} = Codec.decode_entry(bytes); %{txn | entries: txn.entries ++ [cell]}
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
      do: frames(rest, [:erlang.binary_to_term(term, [:safe]) | acc])
  end

end
