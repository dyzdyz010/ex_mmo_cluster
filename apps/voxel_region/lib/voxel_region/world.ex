defmodule VoxelRegion.World do
  @moduledoc """
  Voxim R6 的 region 真值（S2）：truth = 烘焙文件（`VoxelRegion.FileStore`）⊕ overlay 日志。

  - **日志**：全局单调 `seq`，每条 `cell` 条目 = canonical 格的新材质 + 服务端算好的各级 reduce 结果（材质 + 表皮，
    从 L1 向上、某级材质与表皮都没变即停）。append-only 文件 `<root>/<cv>/overlay.log`（`<<len::32, term>>`），启动时重放。
  - **overlay**：`{level, cell} → {material, skins}`，就是日志的压扁；reduce 时 children 先查它，没有再读文件。
  - **载荷**：`serve/1` 对被条目碰过的 region 把文件解码、套上 overlay、按当前 seq 重编码（缓存到下一条碰它的条目为止）；
    没碰过的 region 原样吐文件。应答只有 unchanged / payload / missing（`entries` 应答留给以后：hash 只能核对当前载荷）。
  - **订阅**：`subscribe(pid, have_seq, l0_box, coarse_min_level)`：先补 have_seq 之后落在 box（外扩 1 个 region，让 ring 也跟上）
    或 level ≥ coarse_min_level 的条目，之后每条新条目按同一过滤推送 `{:voxel_log_entry_payload, bin}`。连接断了（monitor）就忘。

  这是 S2 的形状；S4 换 kernel / 持久化时接口不变。没有 fallback：region 文件缺 → intent 拒绝；
  粗层文件缺（没烘到）→ 链在那一级停下并记 warning。
  """

  use GenServer
  require Logger
  import Bitwise
  alias VoxelRegion.{Codec, FileStore, Payload, Reducer}

  @max_level 5
  @name __MODULE__

  # ---- API

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))

  def content_version(server \\ @name), do: GenServer.call(server, :content_version)
  def seq(server \\ @name), do: GenServer.call(server, :seq)

  @doc "`POST /voxel/regions` 的整个请求 → 应答 iodata。"
  def serve(server \\ @name, request) when is_binary(request) do
    case Codec.decode_request(request) do
      {:ok, client_version, items} -> {:ok, GenServer.call(server, {:serve, client_version, items}, 60_000)}
      error -> error
    end
  end

  @doc "一次 canonical 编辑：`{:ok, seq}`（seq = 提交的日志序号；no-op 时是当前 seq）/ `{:error, reason}`。"
  def apply_edit(server \\ @name, {_, _, _} = coord, material) when is_integer(material) and material >= 0 and material <= 255 do
    GenServer.call(server, {:apply_edit, coord, material}, 60_000)
  end

  def subscribe(server \\ @name, pid, have_seq, {{_, _, _}, {_, _, _}} = box, coarse_min_level) do
    GenServer.call(server, {:subscribe, pid, have_seq, box, coarse_min_level})
  end

  def entries_after(server \\ @name, seq), do: GenServer.call(server, {:entries_after, seq})

  # ---- GenServer

  @impl true
  def init(opts) do
    root = Keyword.fetch!(opts, :root)

    case FileStore.content_version(root) do
      {:ok, cv} ->
        state = %{
          root: root,
          cv: cv,
          decoded: %{},
          materialized: %{},
          overlay: %{},
          overlay_regions: %{},
          seq: 0,
          entries: %{},
          subs: %{},
          log_path: Path.join([root, FileStore.hex(cv), "overlay.log"])
        }

        state = replay_log(state)
        Logger.info("voxel_region world #{FileStore.hex(cv)} ready, seq=#{state.seq}, root=#{root}")
        {:ok, state}

      {:error, :no_world} ->
        {:stop, {:no_world, root}}
    end
  end

  @impl true
  def handle_call(:content_version, _from, state), do: {:reply, state.cv, state}
  def handle_call(:seq, _from, state), do: {:reply, state.seq, state}

  def handle_call({:serve, client_version, items}, _from, state) do
    {replies, state} =
      Enum.map_reduce(items, state, fn item, state ->
        {reply, state} = serve_item(state, client_version, item)
        {reply, state}
      end)

    {:reply, Codec.encode_reply(state.cv, replies), state}
  end

  def handle_call({:apply_edit, coord, material}, _from, state) do
    case do_apply_edit(state, coord, material) do
      {:ok, :noop, state} -> {:reply, {:ok, state.seq}, state}
      {:ok, entry, state} -> {:reply, {:ok, entry.seq}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:subscribe, pid, have_seq, box, min_level}, _from, state) do
    unless Map.has_key?(state.subs, pid), do: Process.monitor(pid)
    filter = {box, min_level}

    state.entries
    |> Enum.filter(fn {seq, entry} -> seq > have_seq and matches?(entry, filter) end)
    |> Enum.sort_by(fn {seq, _} -> seq end)
    |> Enum.each(fn {_, entry} -> send(pid, {:voxel_log_entry_payload, IO.iodata_to_binary(Codec.encode_entry(entry))}) end)

    {:reply, :ok, %{state | subs: Map.put(state.subs, pid, filter)}}
  end

  def handle_call({:entries_after, seq}, _from, state) do
    {:reply, state.entries |> Enum.filter(fn {s, _} -> s > seq end) |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)), state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state), do: {:noreply, %{state | subs: Map.delete(state.subs, pid)}}
  def handle_info(_msg, state), do: {:noreply, state}

  # ---- 应答

  defp serve_item(state, client_version, %{level: level, region: region, have_seq: have_seq, have_hash: have_hash}) do
    case payload_bytes(state, level, region) do
      {:ok, bytes, header, state} ->
        if client_version == state.cv and header.hash == have_hash and header.seq == have_seq do
          {{:unchanged, level, region}, state}
        else
          {{:payload, level, region, bytes}, state}
        end

      {:error, :missing, state} ->
        {{:missing, level, region}, state}
    end
  end

  # 被 overlay 碰过的 region 用物化载荷（缓存），否则原样是文件。
  defp payload_bytes(state, level, region) do
    key = {level, region}

    case Map.fetch(state.materialized, key) do
      {:ok, {bytes, header}} ->
        {:ok, bytes, header, state}

      :error ->
        cells = Map.get(state.overlay_regions, key, MapSet.new())

        if MapSet.size(cells) == 0 do
          case FileStore.read(state.root, state.cv, level, region) do
            {:ok, bytes, header} -> {:ok, bytes, header, state}
            {:error, :missing} -> {:error, :missing, state}
          end
        else
          case decoded(state, level, region) do
            {:ok, payload, state} ->
              overrides = Map.new(cells, fn cell -> {Payload.local(region, cell), Map.fetch!(state.overlay, {level, cell})} end)
              bytes = Payload.encode(payload, overrides, state.seq, state.cv)
              {:ok, header} = Codec.decode_payload_header(bytes)
              {:ok, bytes, header, %{state | materialized: Map.put(state.materialized, key, {bytes, header})}}

            {:error, :missing, state} ->
              {:error, :missing, state}
          end
        end
    end
  end

  defp decoded(state, level, region) do
    key = {level, region}

    case Map.fetch(state.decoded, key) do
      {:ok, payload} ->
        {:ok, payload, state}

      :error ->
        with {:ok, bytes, _header} <- FileStore.read(state.root, state.cv, level, region),
             {:ok, payload} <- Payload.decode(bytes) do
          {:ok, payload, %{state | decoded: Map.put(state.decoded, key, payload)}}
        else
          _ -> {:error, :missing, state}
        end
    end
  end

  # ---- 真值

  defp cell_value(state, level, cell) do
    case Map.fetch(state.overlay, {level, cell}) do
      {:ok, value} ->
        {:ok, value, state}

      :error ->
        region = region_of(cell)

        case decoded(state, level, region) do
          {:ok, payload, state} -> {:ok, Payload.value(payload, Payload.local(region, cell)), state}
          {:error, :missing, state} -> {:error, :missing, state}
        end
    end
  end

  defp region_of({x, y, z}), do: {floor_div(x, 64), floor_div(y, 64), floor_div(z, 64)}
  defp floor_div(a, b), do: div(a - rem(rem(a, b) + b, b), b)
  defp parent_of({x, y, z}), do: {floor_div(x, 2), floor_div(y, 2), floor_div(z, 2)}

  defp do_apply_edit(state, coord, material) do
    with {:ok, {old, _}, state} <- cell_value(state, 0, coord) do
      if old == material do
        {:ok, :noop, state}
      else
        value = {material, Reducer.uniform(material)}
        state = put_overlay(state, 0, coord, value)
        {coarse, state} = reduce_chain(state, coord, 1, [])
        seq = state.seq + 1
        entry = %{seq: seq, coord: coord, material: material, coarse: coarse}
        state = %{state | seq: seq, entries: Map.put(state.entries, seq, entry)}
        append_log(state, entry)
        fanout(state, entry)
        {:ok, entry, state}
      end
    else
      {:error, :missing, _state} -> {:error, :missing_region}
    end
  end

  defp reduce_chain(state, _cell, level, acc) when level > @max_level, do: {Enum.reverse(acc), state}

  defp reduce_chain(state, cell, level, acc) do
    parent = parent_of(cell)
    {px, py, pz} = parent

    {children, state} =
      Enum.map_reduce(0..7, state, fn oct, state ->
        child = {px * 2 + (oct &&& 1), py * 2 + ((oct >>> 1) &&& 1), pz * 2 + ((oct >>> 2) &&& 1)}

        case cell_value(state, level - 1, child) do
          {:ok, value, state} -> {value, state}
          {:error, :missing, state} -> {:missing, state}
        end
      end)

    with false <- Enum.any?(children, &(&1 == :missing)),
         {:ok, old, state} <- cell_value(state, level, parent) do
      new = Reducer.reduce_cell(children, level)

      if new == old do
        {Enum.reverse(acc), state}
      else
        state = put_overlay(state, level, parent, new)
        {m, s} = new
        reduce_chain(state, parent, level + 1, [%{level: level, cell: parent, material: m, skins: s} | acc])
      end
    else
      _ ->
        Logger.warning("voxel_region: L#{level} around #{inspect(parent)} not baked; reduce chain stops here")
        {Enum.reverse(acc), state}
    end
  end

  # overlay 一格：所有 66³ 跨度含它的 region（自己 + 邻居的 ring）都记上，它们的物化载荷作废。
  defp put_overlay(state, level, {x, y, z} = cell, value) do
    regions =
      for rx <- floor_div(x - 1, 64)..floor_div(x + 1, 64), ry <- floor_div(y - 1, 64)..floor_div(y + 1, 64), rz <- floor_div(z - 1, 64)..floor_div(z + 1, 64), do: {rx, ry, rz}

    Enum.reduce(regions, %{state | overlay: Map.put(state.overlay, {level, cell}, value)}, fn region, state ->
      key = {level, region}

      %{
        state
        | overlay_regions: Map.update(state.overlay_regions, key, MapSet.new([cell]), &MapSet.put(&1, cell)),
          materialized: Map.delete(state.materialized, key)
      }
    end)
  end

  # ---- 日志

  defp append_log(state, entry) do
    File.mkdir_p!(Path.dirname(state.log_path))
    term = :erlang.term_to_binary(entry)
    File.write!(state.log_path, <<byte_size(term)::32, term::binary>>, [:append])
  end

  defp replay_log(state) do
    case File.read(state.log_path) do
      {:ok, bytes} -> replay_entries(state, bytes)
      {:error, :enoent} -> state
    end
  end

  defp replay_entries(state, <<>>), do: state

  defp replay_entries(state, <<len::32, term::binary-size(len), rest::binary>>) do
    entry = :erlang.binary_to_term(term, [:safe])
    state = put_overlay(state, 0, entry.coord, {entry.material, Reducer.uniform(entry.material)})
    state = Enum.reduce(entry.coarse, state, fn %{level: level, cell: cell, material: m, skins: s}, state -> put_overlay(state, level, cell, {m, s}) end)
    replay_entries(%{state | seq: max(state.seq, entry.seq), entries: Map.put(state.entries, entry.seq, entry)}, rest)
  end

  # ---- 订阅

  defp fanout(state, entry) do
    bin = IO.iodata_to_binary(Codec.encode_entry(entry))

    Enum.each(state.subs, fn {pid, filter} ->
      if matches?(entry, filter), do: send(pid, {:voxel_log_entry_payload, bin})
    end)
  end

  defp matches?(entry, {{{x0, y0, z0}, {x1, y1, z1}}, min_level}) do
    {rx, ry, rz} = region_of(entry.coord)

    in_box = rx >= x0 - 1 and rx <= x1 + 1 and ry >= y0 - 1 and ry <= y1 + 1 and rz >= z0 - 1 and rz <= z1 + 1
    in_box or Enum.any?(entry.coarse, &(&1.level >= min_level))
  end
end
