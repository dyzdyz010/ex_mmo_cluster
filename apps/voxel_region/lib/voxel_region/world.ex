defmodule VoxelRegion.World do
  @moduledoc """
  Voxim R6 的 region 真值：truth = 烘焙文件（`VoxelRegion.FileStore`）⊕ overlay 日志。

  - **日志**：全局单调 `seq`，每条 `cell` 条目 = canonical 格的新材质 + 服务端算好的各级 reduce 结果（材质 + 表皮，
    从 L1 向上、某级材质与表皮都没变即停）。批次共享一个 seq，父格逐级去重，只规约一次。
    文件 `<root>/<cv>/overlay.log`（`<<len::32, term>>`）记录选出的 region 快照与稀疏值；region 事务后压实完整前缀，启动时重放。
  - **overlay**：`{level, cell} → {material, skins}`，就是日志的压扁；reduce 时 children 先查它，没有再读文件。
  - **载荷**：`serve/1` 对被条目碰过的 region 把文件解码、套上 overlay、按当前 seq 重编码（缓存到下一条碰它的条目为止）；
    没碰过的 region 原样吐文件。记住每个 region 最近一次下发的 seq/hash；旧副本与此完全吻合、后续只有稀疏条目且更省字节才回 entries。
    entries 不写回客户端磁盘，服务端保留这个旧头供重复请求校验；缺失此头、hash 不同、跨过 region 替换时回完整载荷。
  - **订阅**：`subscribe(pid, have_seq, l0_box, coarse_min_level)`：先补 have_seq 之后落在 box（外扩 1 个 region，让 ring 也跟上）
    或 level ≥ coarse_min_level 的条目，之后每条新条目按同一过滤推送 `{:voxel_log_entry_payload, bin}`。连接断了（monitor）就忘。

  S4 换 kernel / 持久化时接口不变。没有 fallback：region 文件缺 → intent 拒绝；
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

  @doc "多格编辑原子提交；每级父格去重后规约。"
  def apply_edits(server \\ @name, edits), do: GenServer.call(server, {:apply_edits, edits}, 300_000)

  @doc "压实完整前缀；任意旧 have_seq 都能从检查点补齐。"
  def compact(server \\ @name), do: GenServer.call(server, :compact, 300_000)

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
          snapshots: MapSet.new(),
          materialized: %{},
          served_headers: %{},
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

  def handle_call({:apply_edit, coord, material}, from, state) do
    case do_apply_edit(state, coord, material) do
      {:ok, :noop, state} ->
        acknowledge_noop(state,from)
        {:reply, {:ok, state.seq}, state}
      {:ok, entry, state} -> {:reply, {:ok, entry.seq}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:subscribe, pid, have_seq, box, min_level}, _from, state) do
    unless Map.has_key?(state.subs, pid), do: Process.monitor(pid)
    filter = {box, min_level}

    state.entries
    |> Enum.filter(fn {seq, _entry} -> seq > have_seq end)
    |> Enum.sort_by(fn {seq, _} -> seq end)
    |> Enum.each(fn {_, entry} -> send_filtered(pid, entry, filter) end)

    {:reply, :ok, %{state | subs: Map.put(state.subs, pid, filter)}}
  end

  def handle_call({:entries_after, seq}, _from, state) do
    {:reply, state.entries |> Enum.filter(fn {s, _} -> s > seq end) |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)), state}
  end

  def handle_call({:apply_edits, edits}, from, state) do
    case apply_batch(state, edits) do
      {:ok, next_state} ->
        if next_state.seq == state.seq, do: acknowledge_noop(next_state,from)
        {:reply, {:ok, next_state.seq}, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:compact, _from, state) do
    {:reply, :ok, compact_log(state)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state), do: {:noreply, %{state | subs: Map.delete(state.subs, pid)}}
  def handle_info(_msg, state), do: {:noreply, state}

  # ---- 应答

  defp serve_item(state, client_version, %{level: level, region: region, have_seq: have_seq, have_hash: have_hash}) do
    case payload_bytes(state, level, region) do
      {:ok, bytes, header, state} ->
        key = {level,region}
        known = Map.get(state.served_headers,key) == {have_seq,have_hash}
        previous = state.entries |> Enum.filter(fn {seq,_} -> seq > have_seq end) |> Enum.sort_by(&elem(&1,0))
        transactions = Enum.map(previous, fn {_,e} -> project_transaction(e,level,region) end)
        has_region = Enum.any?(transactions, &(&1 == :region))
        transactions = Enum.reject(transactions, &(&1 != :region and &1.entries == [] and &1.coarse == []))
        served = %{state | served_headers: Map.put(state.served_headers,key,{header.seq,header.hash})}
        if client_version == state.cv and header.hash == have_hash and header.seq == have_seq do
          {{:unchanged, level, region}, served}
        else
          entry_reply = {:entries,level,region,transactions}
          payload_reply = {:payload,level,region,bytes}
          if client_version == state.cv and have_seq > 0 and known and not has_region and transactions != [] and
               IO.iodata_length(Codec.encode_reply(state.cv,[entry_reply])) < IO.iodata_length(Codec.encode_reply(state.cv,[payload_reply])) do
            {entry_reply,state}
          else
            {payload_reply,served}
          end
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

        if MapSet.size(cells) == 0 and not MapSet.member?(state.snapshots, key) do
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
    old_seq = state.seq
    case apply_batch(state, [{coord, material}], true) do
      {:ok, state} when state.seq == old_seq -> {:ok, :noop, state}
      {:ok, state} -> {:ok, Map.fetch!(state.entries, state.seq), state}
      error -> error
    end
  end

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
    state = replay_entry(state, entry)
    replay_entries(%{state | seq: max(state.seq, entry.seq), entries: Map.put(state.entries, entry.seq, entry)}, rest)
  end

  # ---- 订阅

  defp fanout(state, entry) do
    Enum.each(state.subs, fn {pid, filter} -> send_filtered(pid, entry, filter) end)
  end

  defp send_filtered(pid, %{entries: entries, coarse: coarse} = txn, filter) do
    entries = Enum.filter(entries, &matches?(&1, filter))
    coarse = Enum.filter(coarse, &matches_cell?(&1.level, &1.cell, filter))
    if entries != [] or coarse != [] do
      bin = Codec.encode_transaction(%{txn | entries: entries, coarse: coarse}) |> IO.iodata_to_binary()
      send(pid, {:voxel_log_transaction_payload, bin})
    end
  end

  defp send_filtered(pid, entry, filter) do
    if matches?(entry, filter), do: send(pid, {:voxel_log_entry_payload, IO.iodata_to_binary(Codec.encode_entry(entry))})
  end

  defp matches?(%{payload: bytes}, filter) do
    {:ok, h} = Codec.decode_payload_header(bytes)
    {x, y, z} = h.region
    matches_span?(h.level, {x*64, y*64, z*64}, {x*64+63, y*64+63, z*64+63}, filter)
  end

  defp matches?(entry, {{{x0, y0, z0}, {x1, y1, z1}}, min_level}) do
    {rx, ry, rz} = region_of(entry.coord)

    in_box = rx >= x0 - 1 and rx <= x1 + 1 and ry >= y0 - 1 and ry <= y1 + 1 and rz >= z0 - 1 and rz <= z1 + 1
    in_box or Enum.any?(entry.coarse, &(&1.level >= min_level))
  end

  defp matches_cell?(level, cell, filter), do: matches_span?(level, cell, cell, filter)

  defp matches_span?(level, {ax,ay,az}, {bx,by,bz}, {{{x0,y0,z0},{x1,y1,z1}}, min_level}) do
    step = 1 <<< level
    level >= min_level or
      (floor_div(ax*step,64) <= x1+1 and floor_div((bx+1)*step-1,64) >= x0-1 and
       floor_div(ay*step,64) <= y1+1 and floor_div((by+1)*step-1,64) >= y0-1 and
       floor_div(az*step,64) <= z1+1 and floor_div((bz+1)*step-1,64) >= z0-1)
  end

  defp project_transaction(%{entries: entries,coarse: coarse}=txn,level,region) do
    {ox,oy,oz}=Payload.origin(region)
    replacement = Enum.any?(entries,fn
      %{payload: bytes} ->
        {:ok,h}=Codec.decode_payload_header(bytes)
        {x,y,z}=h.region
        h.level==level and x*64 <= ox+65 and x*64+63 >= ox and y*64 <= oy+65 and y*64+63 >= oy and z*64 <= oz+65 and z*64+63 >= oz
      _ -> false
    end)
    if replacement do
      :region
    else
      cells=Enum.filter(entries,fn e -> level==0 and Map.has_key?(e,:coord) and Payload.in_span?(Payload.local(region,e.coord)) end)
      coarse=Enum.filter(coarse,fn e -> e.level==level and Payload.in_span?(Payload.local(region,e.cell)) end)
      %{txn | entries: cells,coarse: coarse}
    end
  end

  defp project_transaction(entry,level,region) do
    project_transaction(%{seq: entry.seq,entries: [%{entry | coarse: []}],coarse: entry.coarse},level,region)
  end

  defp replay_entry(state, %{entries: entries, coarse: coarse}) do
    state = Enum.reduce(entries, state, &replay_entry(&2, &1))
    Enum.reduce(coarse, state, fn e, s -> put_overlay(s, e.level, e.cell, {e.material, e.skins}) end)
  end

  defp replay_entry(state, %{payload: bytes}) do
    {:ok, p} = Payload.decode(bytes)
    key = {p.level, p.region}
    overlay = Map.reject(state.overlay, fn {{level, cell}, _} -> level == p.level and region_of(cell) == p.region end)
    regions = Map.new(state.overlay_regions, fn {k, cells} -> {k, MapSet.filter(cells, &Map.has_key?(overlay, {elem(k, 0), &1}))} end)
    state = %{state | decoded: Map.put(state.decoded, key, p), snapshots: MapSet.put(state.snapshots, key), overlay: overlay,
                       overlay_regions: regions, materialized: %{}}
    {rx, ry, rz} = p.region
    # 内部格直接从快照读取；边界格同时进入邻居 ring。
    for z <- 0..63, y <- 0..63, x <- 0..63, x in [0, 63] or y in [0, 63] or z in [0, 63], reduce: state do
      s -> put_overlay(s, p.level, {rx*64+x, ry*64+y, rz*64+z}, Payload.value(p, {x+1,y+1,z+1}))
    end
  end

  defp replay_entry(state, entry) do
    state = put_overlay(state, 0, entry.coord, {entry.material, Reducer.uniform(entry.material)})
    Enum.reduce(entry.coarse, state, fn e, s -> put_overlay(s, e.level, e.cell, {e.material, e.skins}) end)
  end

  defp apply_batch(state, edits, legacy \\ false) do
    started = System.monotonic_time(:microsecond)
    result = Enum.reduce_while(Map.new(edits), {[], state}, fn {cell,m}, {changed,s} ->
      case cell_value(s, 0, cell) do
        {:ok, {old,_}, s} when old == m -> {:cont, {changed,s}}
        {:ok, _, s} -> {:cont, {[{0,cell}|changed],put_overlay(s,0,cell,{m,Reducer.uniform(m)})}}
        {:error,:missing,_} -> {:halt, {:error,:missing_region}}
      end
    end)
    case result do
      {:error, reason} -> {:error, reason}
      {[], state} -> {:ok,state}
      {changed,state} ->
        {all,state,visits} = reduce_batch(state,changed,1,changed,0)
        state = %{state | seq: state.seq+1}
        {txn,state} = if legacy do
          [{coord,material}]=edits
          coarse=for {level,cell} <- Enum.sort(all), level > 0 do
            {m,skins}=Map.fetch!(state.overlay,{level,cell})
            %{level: level,cell: cell,material: m,skins: skins}
          end
          {%{seq: state.seq,coord: coord,material: material,coarse: coarse},state}
        else
          select_transaction(state,all)
        end
        append_log(state,txn)
        state = %{state | entries: Map.put(state.entries,state.seq,txn)}
        fanout(state,txn)
        region_count = Enum.count(Map.get(txn,:entries,[]),&Map.has_key?(&1,:payload))
        state = if region_count > 0, do: compact_log(state), else: state
        Logger.info("voxel_region transaction seq=#{state.seq} canonical=#{length(changed)} reduced=#{visits} changed=#{length(all)} regions=#{region_count} bytes=#{IO.iodata_length(if legacy, do: Codec.encode_entry(txn), else: Codec.encode_transaction(txn))} elapsed_us=#{System.monotonic_time(:microsecond)-started}")
        {:ok,state}
    end
  end

  defp reduce_batch(state, [], _level, all, visits), do: {all,state,visits}
  defp reduce_batch(state, _dirty, level, all, visits) when level > @max_level, do: {all,state,visits}
  defp reduce_batch(state, dirty, level, all, visits) do
    parents = dirty |> Enum.map(fn {_,c} -> parent_of(c) end) |> Enum.uniq()
    {changed,state} = Enum.reduce(parents,{[],state},fn parent,{changed,s} ->
      {px,py,pz}=parent
      {children,s}=Enum.map_reduce(0..7,s,fn oct,s ->
        c={px*2+(oct &&& 1),py*2+((oct >>> 1) &&& 1),pz*2+((oct >>> 2) &&& 1)}
        case cell_value(s,level-1,c) do
          {:ok,v,s}->{v,s}
          {:error,:missing,s}->{:missing,s}
        end
      end)
      with false <- :missing in children, {:ok,old,s} <- cell_value(s,level,parent) do
        new=Reducer.reduce_cell(children,level)
        if new==old, do: {changed,s}, else: {[{level,parent}|changed],put_overlay(s,level,parent,new)}
      else
        _ ->
          Logger.warning("voxel_region: L#{level} around #{inspect(parent)} not baked; reduce chain stops here")
          {changed,s}
      end
    end)
    reduce_batch(state,changed,level+1,changed++all,visits+length(parents))
  end

  defp select_transaction(state, changed) do
    groups=Enum.group_by(changed,fn {level,cell}->{level,region_of(cell)} end)
    Enum.reduce(Enum.sort(groups), {%{seq: state.seq,entries: [],coarse: []},state},fn {{level,region},keys},{txn,s}->
      sparse=Enum.map(Enum.sort(keys),fn {level,cell}->
        {m,skins}=Map.fetch!(s.overlay,{level,cell})
        if level==0, do: %{seq: s.seq,coord: cell,material: m,coarse: []}, else: %{level: level,cell: cell,material: m,skins: skins}
      end)
      cell_bytes=Enum.reduce(sparse,0,fn e,n -> n+if(level==0,do: 4+IO.iodata_length(Codec.encode_entry(e)),else: IO.iodata_length(Codec.encode_coarse(e))) end)
      {:ok,bytes,_header,s}=payload_bytes(s,level,region)
      if cell_bytes > 13+byte_size(bytes) do
        {%{txn | entries: txn.entries++[region_entry(s.seq,bytes)]},s}
      else
        if level==0, do: {%{txn | entries: txn.entries++sparse},s}, else: {%{txn | coarse: txn.coarse++sparse},s}
      end
    end)
  end

  defp compact_log(%{seq: 0}=state), do: state
  defp compact_log(state) do
    # 检查点覆盖完整前缀；当前 seq 对任意更旧游标都是完整补丁。
    {txn,state}=select_transaction(state,Map.keys(state.overlay))
    existing=txn.entries |> Enum.filter(&Map.has_key?(&1,:payload)) |> MapSet.new(fn e ->
      {:ok,h}=Codec.decode_payload_header(e.payload)
      {h.level,h.region}
    end)
    {extra,state}=Enum.map_reduce(MapSet.difference(state.snapshots,existing),state,fn {level,region},s ->
      {:ok,bytes,_,s}=payload_bytes(s,level,region)
      {region_entry(s.seq,bytes),s}
    end)
    txn=%{txn | entries: txn.entries++extra}
    term=:erlang.term_to_binary(txn)
    File.write!(state.log_path<>".tmp",<<byte_size(term)::32,term::binary>>)
    File.rename!(state.log_path<>".tmp",state.log_path)
    %{state | entries: %{state.seq=>txn}}
  end

  # no-op 不追加日志；只向发起连接确认当前游标，排在此连接已有的 World 消息之后。
  defp acknowledge_noop(state,{pid,_tag}) do
    if Map.has_key?(state.subs,pid) do
      bytes=Codec.encode_transaction(%{seq: state.seq,entries: [],coarse: []}) |> IO.iodata_to_binary()
      send(pid,{:voxel_log_transaction_payload,bytes})
    end
  end

  defp region_entry(seq,bytes), do: %{seq: seq,payload: Codec.stamp_payload_seq(bytes,seq)}
end
