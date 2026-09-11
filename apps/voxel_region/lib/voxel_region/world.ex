defmodule VoxelRegion.World do
  @moduledoc """
  Voxim R6 的 region 真值：truth = 显式 baseline source ⊕ overlay 日志。

  - **日志**：全局单调 `seq`，每条 `cell` 条目 = canonical 格的新材质 + 服务端算好的各级 reduce 结果（材质 + 表皮，
    从 L1 向上、某级材质与表皮都没变即停）。批次共享一个 seq，父格逐级去重，只规约一次。
    文件 `<root>/<cv>/overlay.log`（`<<len::32, term>>`）记录选出的 region 快照与稀疏值；region 事务后压实完整前缀，启动时重放。
  - **overlay**：`{level, cell} → {material, skins}`，就是日志的压扁；reduce 时 children 先查它，没有再读 baseline source。
  - **载荷**：`serve/1` 对被条目碰过的 region 把 baseline 解码、套上 overlay、按当前 seq 重编码；
    没碰过的 region 原样吐 source 载荷。两者都进同一个内存载荷缓存 `(level, region) → {bytes, header}`：
    L0–L3 按最近使用淘汰（字节上限 `:payload_cache_bytes`），L4+ 常驻；条目碰到的 region 立即失效。
    冷 miss 的 baseline 生成在调用方进程里并发预备（`prepare/2`），GenServer 只做缓存查找与编码，不被生成阻塞。
    记住每个 region 最近一次下发的 seq/hash；旧副本与此完全吻合、后续只有稀疏条目且更省字节才回 entries。
    entries 不写回客户端磁盘，服务端保留这个旧头供重复请求校验；缺失此头、hash 不同、跨过 region 替换时回完整载荷。
  - **订阅**：`subscribe(pid, have_seq, l0_box, coarse_min_level)`：先补 have_seq 之后落在 box（外扩 1 个 region，让 ring 也跟上）
    或 level ≥ coarse_min_level 的条目，之后每条新条目按同一过滤推送 `{:voxel_log_entry_payload, bin}`。连接断了（monitor）就忘。

  正式运行由 `VoxelRegion.GeneratedStore` 在线生成；`VoxelRegion.FileStore` 只供既有 fixture 测试显式使用。
  source 失败不 fallback。
  """

  use GenServer
  require Logger
  import Bitwise
  alias VoxelRegion.OverlayLog
  alias VoxelRegion.{CollisionSource, FileStore, Prefab, Reducer}
  alias MmoContracts.Voxel.{CanonicalDelta, CanonicalSnapshot, Codec, Payload}

  @max_level 5
  @resident_level 4
  @default_cache_bytes 512 * 1024 * 1024
  @name __MODULE__

  # ---- API

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))

  def content_version(server \\ @name), do: GenServer.call(server, :content_version)
  def seq(server \\ @name), do: GenServer.call(server, :seq)

  @doc "唯一 canonical authority 的 PID，供区域视图共享世界身份。"
  def authority_ref(server \\ @name), do: GenServer.call(server, :authority_ref)

  @doc "区域物化服务启动入口：在本节点预备源，再原子返回快照并订阅完整区域更新。"
  def replica_snapshot_and_subscribe(server, box, pid) do
    prepare(server, Enum.map(CollisionSource.regions(box), &{0, &1}))
    GenServer.call(server, {:replica_snapshot, box, pid}, 300_000)
  end

  @doc "载荷缓存与生成统计：entries / lru_bytes / resident_bytes / hits / misses / evictions / generated。"
  def stats(server \\ @name), do: GenServer.call(server, :stats)

  @doc "`POST /voxel/regions` 的整个请求 → 应答 iodata。"
  def serve(server \\ @name, request) when is_binary(request) do
    case Codec.decode_request(request) do
      {:ok, client_version, items} ->
        if Enum.all?(items, &valid_request_item?/1) do
          prepare(server, Enum.map(items, &{&1.level, &1.region}))

          case GenServer.call(server, {:serve, client_version, items}, 60_000) do
            {:error, _reason} = error -> error
            reply -> {:ok, reply}
          end
        else
          {:error, :invalid_request}
        end

      error -> error
    end
  end

  defp valid_request_item?(%{level: level, region: region}) when level in 0..@max_level do
    step = 1 <<< level

    valid_region?(region, step)
  end

  defp valid_request_item?(_), do: false

  defp valid_region?({x, y, z}, step) when is_integer(x) and is_integer(y) and is_integer(z) do
    Enum.all?([x, y, z], fn value ->
      min = (value * 64 - 1) * step - 4
      max = (value * 64 + 65) * step - 1 + 4
      min >= -2_147_483_648 and max <= 2_147_483_647
    end)
  end

  defp valid_region?(_, _), do: false

  defp valid_edit_coord?({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z) do
    Enum.all?(0..@max_level, fn level ->
      step = 1 <<< level
      cell = {floor_div(x, step), floor_div(y, step), floor_div(z, step)}
      valid_region?(region_of(cell), step)
    end)
  end

  defp valid_edit_coord?(_), do: false

  # 冷 miss 的 baseline 在调用方进程并发物化到磁盘缓存；结果不看——World 读时缺失就是 missing、损坏就是错误，语义不变。
  defp prepare(server, keys) do
    # 多人加入的快照共用此 mailbox；前置查询沿用后续快照的等待时限，
    # 避免 20 人实验中正常排队被默认 5 秒超时截断。
    {source, source_state} = GenServer.call(server, :source, 300_000)

    keys
    |> Enum.uniq()
    |> Task.async_stream(fn {level, region} -> source.ensure(source_state, level, region) end,
      max_concurrency: Application.get_env(:voxel_region, :generation_concurrency, 8),
      ordered: false,
      timeout: :infinity
    )
    |> Stream.run()
  end

  defp edit_keys(coords) do
    for {x, y, z} <- coords, level <- 0..@max_level do
      step = 1 <<< level
      {level, region_of({floor_div(x, step), floor_div(y, step), floor_div(z, step)})}
    end
  end

  @doc "一次 canonical 编辑：`{:ok, seq}`（seq = 提交的日志序号；no-op 时是当前 seq）/ `{:error, reason}`。"
  def apply_edit(server \\ @name, {_, _, _} = coord, material) when is_integer(material) and material >= 0 and material <= 255 do
    if valid_edit_coord?(coord) do
      prepare(server, edit_keys([coord]))
      GenServer.call(server, {:apply_edit, coord, material}, 60_000)
    else
      {:error, :invalid_coordinate}
    end
  end

  def place_prefab(server \\ @name, definition_id, anchor, orientation) do
    with {:ok, cells} <- prefab_cells(server,definition_id,anchor,orientation) do
      prepare(server, prefab_keys(cells))
      GenServer.call(server,{:place_prefab,definition_id,anchor,orientation,cells},300_000)
    end
  end
  def remove_prefab(server \\ @name, instance_id), do: GenServer.call(server,{:remove_prefab,instance_id},300_000)
  def publish_prefabs(server \\ @name,path) do
    catalog = Prefab.load(path)
    GenServer.call(server,{:publish_prefabs,catalog},300_000)
  end
  def replace_prefab(server \\ @name,instance_id,definition_id) do
    with {:ok,cells} <- replacement_cells(server,instance_id,definition_id) do
      prepare(server,region_keys(Enum.map(cells,&{0,&1})))
      GenServer.call(server,{:replace_prefab,instance_id,definition_id},300_000)
    end
  end
  def replacement_cells(server,instance_id,definition_id), do: GenServer.call(server,{:replacement_cells,instance_id,definition_id},300_000)
  def prefab_cells(server,id,anchor,orientation), do: GenServer.call(server,{:prefab_cells,id,anchor,orientation})
  def instance_cells(server,id), do: GenServer.call(server,{:instance_cells,id})

  defp prefab_keys(cells) do
    cells |> Enum.flat_map(fn {micro,_} ->
      {{x,y,z},_} = Prefab.macro_slot(micro)
      for rx <- floor_div(x-1,64)..floor_div(x+1,64), ry <- floor_div(y-1,64)..floor_div(y+1,64),
          rz <- floor_div(z-1,64)..floor_div(z+1,64), do: {0,{rx,ry,rz}}
    end) |> Enum.uniq()
  end

  def subscribe(server \\ @name, pid, have_seq, {{_, _, _}, {_, _, _}} = box, coarse_min_level) do
    GenServer.call(server, {:subscribe, pid, have_seq, box, coarse_min_level})
  end

  def entries_after(server \\ @name, seq), do: GenServer.call(server, {:entries_after, seq})

  @doc "Prepare canonical L0 source, then atomically send its snapshot marker and subscribe to all subsequent transactions."
  def canonical_snapshot_and_subscribe(world_ref, l0_box, subscriber_pid, request_ref, include_chunks \\ true) do
    prepare(world_ref, Enum.map(CollisionSource.regions(l0_box), &{0, &1}))
    GenServer.call(world_ref, {:canonical_snapshot, l0_box, subscriber_pid, request_ref, include_chunks}, 300_000)
  end

  @doc "多格编辑原子提交；每级父格去重后规约。"
  def apply_edits(server \\ @name, edits) do
    if Enum.all?(edits, fn
         {{_, _, _} = coord, _material} -> valid_edit_coord?(coord)
         _ -> false
       end) do
      prepare(server, edit_keys(Enum.map(edits, &elem(&1, 0))))
      GenServer.call(server, {:apply_edits, edits}, 300_000)
    else
      {:error, :invalid_coordinate}
    end
  end

  @doc "压实完整前缀；任意旧 have_seq 都能从检查点补齐。"
  def compact(server \\ @name), do: GenServer.call(server, :compact, 300_000)

  # ---- GenServer

  @impl true
  def init(opts) do
    source = Keyword.get(opts, :source, FileStore)

    case source.open(opts) do
      {:ok, source_state} ->
        cv = source.content_version(source_state)
        world_dir = source.world_dir(source_state)
        # 正式启动用 DataService 表（application.ex）；不起数据库的测试默认文件后端。
        log = Keyword.get(opts, :log, OverlayLog.File)
        state = %{
          source: source,
          source_state: source_state,
          cv: cv,
          decoded: %{},
          snapshots: MapSet.new(),
          payloads: %{},
          lru: :gb_trees.empty(),
          lru_ticks: %{},
          tick: 0,
          lru_bytes: 0,
          resident_bytes: 0,
          cache_limit: Keyword.get(opts, :payload_cache_bytes, Application.get_env(:voxel_region, :payload_cache_bytes, @default_cache_bytes)),
          cache_stats: %{hits: 0, misses: 0, evictions: 0},
          served_headers: %{},
          overlay: %{},
          refined: %{},
          structure: %{},
          instances: %{},
          prefabs: Prefab.load(Keyword.get(opts, :prefab_catalog_path, Application.get_env(:voxel_region, :prefab_catalog_path))),
          overlay_regions: %{},
          seq: 0,
          entries: %{},
          subs: %{},
          canonical_subs: %{},
          replica_subs: %{},
          log: {log, log.open(world_dir, cv)}
        }

        state = replay_log(state)
        {state, _} = refresh_structure(state, Map.keys(state.refined))
        state = if map_size(state.structure) > 0, do: compact_log(state), else: state
        Logger.info("voxel_region world #{FileStore.hex(cv)} ready, seq=#{state.seq}, root=#{world_dir}")
        {:ok, state}

      {:error, :no_world} ->
        {:stop, {:no_world, Keyword.fetch!(opts, :root)}}
    end
  end

  @impl true
  def handle_call(:content_version, _from, state), do: {:reply, state.cv, state}
  def handle_call(:seq, _from, state), do: {:reply, state.seq, state}
  def handle_call(:authority_ref, _from, state), do: {:reply, self(), state}
  def handle_call(:source, _from, state), do: {:reply, {state.source, state.source_state}, state}

  def handle_call({:publish_prefabs,catalog},_from,state) do
    {:reply,:ok,%{state | prefabs: Map.merge(state.prefabs,catalog)}}
  end

  def handle_call({:prefab_cells,id,anchor,orientation}, _from,state) do
    result = definition_cells(state,id,anchor,orientation)
    {:reply,result,state}
  end

  def handle_call({:instance_cells,id},_from,state) do
    cells = owner_cells(state,id)
    {:reply,if(cells == [],do: {:error,:instance_not_found},else: {:ok,cells}),state}
  end

  def handle_call({:replacement_cells,target,id},_from,state) do
    result = with {:ok,instance} <- fetch_instance(state,target),
      {:ok,cells} <- definition_cells(state,id,instance.anchor,instance.orientation) do
      {:ok,Enum.uniq(owner_cells(state,target) ++ Enum.map(cells,fn {micro,_} -> elem(Prefab.macro_slot(micro),0) end))}
    end
    {:reply,result,state}
  end

  def handle_call({:place_prefab,id,anchor,orientation,_cells},_from,state) do
    place_tree(state,state,id,anchor,orientation,{0,0},0,[])
  end

  def handle_call({:remove_prefab,id},_from,state) do
    case owner_cells(state,id) do
      [] -> {:reply,{:error,:instance_not_found},state}
      cells -> prefab_reply(state,clear_subtree(state,id,cells),cells)
    end
  end

  def handle_call({:replace_prefab,target,id},_from,state) do
    with {:ok,instance} <- fetch_instance(state,target),
         {:ok,_} <- definition_cells(state,id,instance.anchor,instance.orientation) do
      cells = owner_cells(state,target)
      next = clear_subtree(state,target,cells)
      place_tree(state,next,id,instance.anchor,instance.orientation,Map.get(instance,:parent_id,{0,0}),Map.get(instance,:component_slot,0),cells)
    else
      {:error,reason} -> {:reply,{:error,reason},state}
    end
  end

  def handle_call(:stats, _from, state) do
    stats =
      Map.merge(state.cache_stats, %{
        entries: map_size(state.payloads),
        lru_bytes: state.lru_bytes,
        resident_bytes: state.resident_bytes,
        cache_limit: state.cache_limit,
        generated: state.source.generated(state.source_state)
      })

    {:reply, stats, state}
  end

  def handle_call({:serve, client_version, items}, _from, state) do
    case Enum.reduce_while(items, {[], state}, fn item, {replies, state} ->
           case serve_item(state, client_version, item) do
             {reply, state} -> {:cont, {[reply | replies], state}}
             {:error, reason, _state} -> {:halt, {:error, reason}}
           end
         end) do
      {:error, reason} -> {:reply, {:error, reason}, state}
      {replies, state} -> {:reply, Codec.encode_reply(state.cv, Enum.reverse(replies)), state}
    end
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

  def handle_call({:canonical_snapshot, box, pid, request, include_chunks}, _from, state) do
    case capture_canonical_snapshot(state, box, include_chunks) do
      {:ok, snapshot, state} ->
        unless Map.has_key?(state.canonical_subs, pid), do: Process.monitor(pid)
        send(pid, {:canonical_snapshot, request, snapshot})
        {:reply, :ok, %{state | canonical_subs: Map.put_new(state.canonical_subs, pid, box)}}
      {:error, :canonical_incomplete} ->
        {:reply, {:error, :canonical_incomplete}, state}
    end
  end

  def handle_call({:replica_snapshot, box, pid}, _from, state) do
    case capture_canonical_snapshot(state, box, true) do
      {:ok, snapshot, state} ->
        unless Map.has_key?(state.replica_subs, pid), do: Process.monitor(pid)
        {:reply, {:ok, snapshot}, %{state | replica_subs: Map.put(state.replica_subs, pid, box)}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
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
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state), do: {:noreply, %{state | subs: Map.delete(state.subs, pid), canonical_subs: Map.delete(state.canonical_subs, pid), replica_subs: Map.delete(state.replica_subs, pid)}}
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

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  # 缓存命中直接返回；miss 时被 overlay 碰过的 region 物化、否则原样读 source 载荷，两者都进缓存。
  defp payload_bytes(state, level, region) do
    key = {level, region}

    case cache_fetch(state, key) do
      {:ok, bytes, header, state} ->
        {:ok, bytes, header, state}

      {:miss, state} ->
        cells = Map.get(state.overlay_regions, key, MapSet.new())

        if MapSet.size(cells) == 0 and not MapSet.member?(state.snapshots, key) do
          case state.source.read(state.source_state, level, region) do
            {:ok, bytes, header} -> {:ok, bytes, header, cache_put(state, key, bytes, header)}
            {:error, :missing} -> {:error, :missing, state}
            {:error, reason} -> {:error, reason, state}
          end
        else
          case decoded(state, level, region) do
            {:ok, payload, state} ->
              overrides = Map.new(cells, fn cell -> {Payload.local(region, cell), Map.fetch!(state.overlay, {level, cell})} end)
              payload = with_refined(state, payload)
              bytes = Payload.encode(payload, overrides, state.seq, state.cv)
              {:ok, header} = Codec.decode_payload_header(bytes)
              {:ok, bytes, header, cache_put(state, key, bytes, header)}

            {:error, :missing, state} ->
              {:error, :missing, state}

            {:error, reason, state} ->
              {:error, reason, state}
          end
        end
    end
  end

  # ---- 载荷缓存：L0–L3 在 gb_tree {tick, key} 上按最近使用淘汰，L4+ 常驻不进树。

  defp with_refined(state,%Payload{level: 0,region: region}=payload) do
    refined = for {cell,slots} <- state.refined, local = Payload.local(region,cell), Payload.in_span?(local),
      into: %{}, do: {Payload.cell_index(local),slots}
    ids = live_instance_ids(refined,state.instances)
    %{payload | refined: refined,instances: Map.take(state.instances,ids),
      format_version: if(map_size(refined)>0 or payload.format_version == 5,do: 5,else: 4)}
  end
  defp with_refined(state,%Payload{level: level,region: region}=payload) do
    structure = for {{^level,cell},grid} <- state.structure, local = Payload.local(region,cell), Payload.in_span?(local),
      into: %{}, do: {Payload.cell_index(local),grid}
    %{payload | structure: structure}
  end

  defp definition_cells(state,id,anchor,orientation) do
    with {:ok,definition} <- Map.fetch(state.prefabs,id), true <- orientation in 0..23 do
      cells = Prefab.footprint(definition,anchor,orientation)
      if Enum.all?(cells,fn {micro,_} -> valid_edit_coord?(elem(Prefab.macro_slot(micro),0)) end),
        do: {:ok,cells}, else: {:error,:invalid_coordinate}
    else
      :error -> {:error,:definition_not_found}
      false -> {:error,:invalid_orientation}
    end
  end

  defp fetch_instance(state,id) do
    case Map.fetch(state.instances,id) do
      {:ok,instance} -> {:ok,instance}
      :error -> {:error,:instance_not_found}
    end
  end

  defp subtree_ids(state,id) do
    children = Enum.group_by(state.instances,fn {_,i} -> Map.get(i,:parent_id,{0,0}) end, &elem(&1,0))
    descendants(children,[id],MapSet.new())
  end
  defp descendants(_,[],ids), do: ids
  defp descendants(children,[id|rest],ids), do: descendants(children,Map.get(children,id,[]) ++ rest,MapSet.put(ids,id))

  defp owner_cells(state,id) do
    ids = subtree_ids(state,id)
    for {cell,slots} <- state.refined, Enum.any?(slots,fn {_,{_,owner}} -> MapSet.member?(ids,owner) end), do: cell
  end

  defp clear_subtree(state,id,cells) do
    ids = subtree_ids(state,id)
    next = Enum.reduce(cells,state,fn cell,s ->
      slots = Map.fetch!(s.refined,cell) |> Map.reject(fn {_,{_,owner}} -> MapSet.member?(ids,owner) end)
      refined = if map_size(slots) == 0,do: Map.delete(s.refined,cell),else: Map.put(s.refined,cell,slots)
      put_overlay(%{s | refined: refined},0,cell,{0,MmoContracts.Voxel.Skins.uniform(0)})
    end)
    %{next | instances: Map.drop(next.instances,MapSet.to_list(ids))}
  end

  defp place_tree(before,state,id,anchor,orientation,parent,slot,changed) do
    nodes = Prefab.occurrences(Map.fetch!(state.prefabs,id),anchor,orientation,before.seq+1,parent,slot)
    result = Enum.reduce_while(nodes,{:ok,state,changed},fn {owner,instance,cells},{:ok,s,changed} ->
      result = Enum.reduce_while(cells,{:ok,s,changed},fn {micro,material},{:ok,s,changed} ->
        {cell,slot} = Prefab.macro_slot(micro)
        slots = Map.get(s.refined,cell,%{})
        case cell_value(s,0,cell) do
          {:ok,{0,_},s} ->
            if Map.has_key?(slots,slot) do
              {:halt,{:error,:occupied}}
            else
              s = %{s | refined: Map.put(s.refined,cell,Map.put(slots,slot,{material,owner}))}
              {:cont,{:ok,put_overlay(s,0,cell,{0,MmoContracts.Voxel.Skins.uniform(0)}),[cell|changed]}}
            end
          {:ok,_,_} -> {:halt,{:error,:occupied}}
          {:error,reason,_} -> {:halt,{:error,reason}}
        end
      end)
      case result do
        {:ok,s,changed} -> {:cont,{:ok,%{s | instances: Map.put(s.instances,owner,instance)},changed}}
        error -> {:halt,error}
      end
    end)
    case result do
      {:ok,next,changed} -> prefab_reply(before,next,Enum.uniq(changed))
      {:error,reason} -> {:reply,{:error,reason},before}
    end
  end

  defp live_instance_ids(refined,instances) do
    owners = refined |> Enum.flat_map(fn {_,slots} -> Enum.map(slots,fn {_,{_,id}} -> id end) end) |> Enum.uniq()
    MmoContracts.Voxel.Refined.ancestors(instances,owners)
  end

  defp prefab_reply(before,state,cells) do
    state = %{state | seq: before.seq+1,instances: Map.take(state.instances,live_instance_ids(state.refined,state.instances))}
    {state, structure_keys} = refresh_structure(state,cells)
    keys = region_keys(Enum.map(cells,&{0,&1})) ++ structure_keys
    {entries,state} = region_afterimages(state,keys)
    txn = %{seq: state.seq,entries: entries,coarse: []}
    with {:ok,chunks} <- canonical_changes(before,state,Enum.map(cells,&{0,&1})),
         :ok <- append_log(state,txn) do
      state = %{state | entries: Map.put(state.entries,state.seq,txn)}
      fanout(state,txn)
      fanout_canonical(state,txn,chunks)
      {:reply,{:ok,state.seq},state}
    else
      {:error,reason} -> {:reply,{:error,reason},before}
    end
  end

  defp region_keys(cells) do
    for {level,{x,y,z}} <- cells,
      rx <- floor_div(x-1,64)..floor_div(x+1,64), ry <- floor_div(y-1,64)..floor_div(y+1,64),
      rz <- floor_div(z-1,64)..floor_div(z+1,64), do: {level,{rx,ry,rz}}
  end

  defp region_afterimages(state,keys) do
    Enum.map_reduce(Enum.sort(Enum.uniq(keys)),state,fn {level,region}=key,s ->
      :ok = s.source.ensure(s.source_state,level,region)
      s = %{cache_delete(s,key) | snapshots: MapSet.put(s.snapshots,key)}
      {:ok,bytes,_,s} = payload_bytes(s,level,region)
      {region_entry(s.seq,bytes),s}
    end)
  end

  # 结构与地形分别派生；地形 early-stop 不得截断仍会变化的局部细化。
  defp refresh_structure(state,cells) do
    {state,_,changed} = Enum.reduce(1..@max_level,{state,cells,[]},fn level,{s,dirty,changed} ->
      parents = dirty |> Enum.map(&parent_of/1) |> Enum.uniq()
      {s,changed} = Enum.reduce(parents,{s,changed},fn {px,py,pz}=parent,{s,changed} ->
        children = for oct <- 0..7, do: {px*2+(oct &&& 1),py*2+((oct >>> 1) &&& 1),pz*2+((oct >>> 2) &&& 1)}
        has_structure = Enum.any?(children,fn cell ->
          if level == 1, do: Map.has_key?(s.refined,cell), else: Map.has_key?(s.structure,{level-1,cell})
        end)
        {grid,s} = if has_structure do
          {values,s} = Enum.map_reduce(children,s,fn cell,s ->
            case if(level == 1,do: Map.fetch(s.refined,cell),else: Map.fetch(s.structure,{level-1,cell})) do
              {:ok,value} -> {value,s}
              :error ->
                :ok = s.source.ensure(s.source_state,level-1,region_of(cell))
                {:ok,{m,_},s} = cell_value(s,level-1,cell)
                {m,s}
            end
          end)
          {if(level == 1,do: VoxelRegion.Structure.from_canonical(values),else: VoxelRegion.Structure.reduce(values)),s}
        else
          {nil,s}
        end
        key = {level,parent}
        if grid == Map.get(s.structure,key) do
          {s,changed}
        else
          structure = if grid == nil,do: Map.delete(s.structure,key),else: Map.put(s.structure,key,grid)
          keys = region_keys([key])
          s = Enum.reduce(keys,%{s | structure: structure},fn k,s ->
            %{cache_delete(s,k) | snapshots: MapSet.put(s.snapshots,k)}
          end)
          {s,[key|changed]}
        end
      end)
      {s,parents,changed}
    end)
    {state,region_keys(changed)}
  end

  defp cache_fetch(state, key) do
    case Map.fetch(state.payloads, key) do
      {:ok, {bytes, header}} -> {:ok, bytes, header, count(cache_touch(state, key), :hits)}
      :error -> {:miss, count(state, :misses)}
    end
  end

  defp cache_touch(state, {level, _} = key) when level < @resident_level do
    tick = state.tick + 1
    old = Map.fetch!(state.lru_ticks, key)
    lru = :gb_trees.insert({tick, key}, true, :gb_trees.delete({old, key}, state.lru))
    %{state | lru: lru, lru_ticks: Map.put(state.lru_ticks, key, tick), tick: tick}
  end

  defp cache_touch(state, _key), do: state

  defp cache_put(state, {level, _} = key, bytes, header) do
    state = cache_delete(state, key)
    state = %{state | payloads: Map.put(state.payloads, key, {bytes, header})}

    if level < @resident_level do
      tick = state.tick + 1

      %{state | lru: :gb_trees.insert({tick, key}, true, state.lru), lru_ticks: Map.put(state.lru_ticks, key, tick), tick: tick,
                lru_bytes: state.lru_bytes + byte_size(bytes)}
      |> cache_evict()
    else
      %{state | resident_bytes: state.resident_bytes + byte_size(bytes)}
    end
  end

  defp cache_delete(state, {level, _} = key) do
    case Map.pop(state.payloads, key) do
      {nil, _} ->
        state

      {{bytes, _header}, payloads} ->
        if level < @resident_level do
          {tick, ticks} = Map.pop(state.lru_ticks, key)
          %{state | payloads: payloads, lru: :gb_trees.delete({tick, key}, state.lru), lru_ticks: ticks, lru_bytes: state.lru_bytes - byte_size(bytes)}
        else
          %{state | payloads: payloads, resident_bytes: state.resident_bytes - byte_size(bytes)}
        end
    end
  end

  defp cache_evict(state) do
    if state.lru_bytes > state.cache_limit and :gb_trees.size(state.lru) > 0 do
      {{_tick, key}, _value, _lru} = :gb_trees.take_smallest(state.lru)
      cache_evict(count(cache_delete(state, key), :evictions))
    else
      state
    end
  end

  defp cache_clear(state), do: %{state | payloads: %{}, lru: :gb_trees.empty(), lru_ticks: %{}, lru_bytes: 0, resident_bytes: 0}

  defp count(state, field), do: %{state | cache_stats: Map.update!(state.cache_stats, field, &(&1 + 1))}

  defp decoded(state, level, region) do
    key = {level, region}

    case Map.fetch(state.decoded, key) do
      {:ok, payload} ->
        {:ok, payload, state}

      :error ->
        with {:ok, bytes, _header} <- state.source.read(state.source_state, level, region),
             {:ok, payload} <- Payload.decode(bytes) do
          {:ok, payload, %{state | decoded: Map.put(state.decoded, key, payload)}}
        else
          {:error, reason} -> {:error, reason, state}
          other -> {:error, {:invalid_payload, other}, state}
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
          {:error, reason, state} -> {:error, reason, state}
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

      %{cache_delete(state, key) | overlay_regions: Map.update(state.overlay_regions, key, MapSet.new([cell]), &MapSet.put(&1, cell))}
    end)
  end

  # ---- 日志

  defp append_log(%{log: {backend, handle}}, txn), do: backend.append(handle, txn)

  defp replay_log(%{log: {backend, handle}} = state) do
    Enum.reduce(backend.replay(handle), state, fn txn, s ->
      s = replay_entry(s, txn)
      %{s | seq: max(s.seq, txn.seq), entries: Map.put(s.entries, txn.seq, txn)}
    end)
  end

  # ---- 订阅

  defp fanout(state, entry) do
    Enum.each(state.subs, fn {pid, filter} -> send_filtered(pid, entry, filter) end)
  end

  # Same materialized bytes as serve; only the snapshot header is stamped to the barrier N.
  defp canonical_regions(state, coords) do
    Enum.reduce_while(coords, {:ok, [], [], state}, fn coord, {:ok, regions, payloads, state} ->
      with {:ok, bytes, _, state} <- payload_bytes(state, 0, coord),
           bytes = Codec.stamp_payload_seq(bytes, state.seq),
           {:ok, payload} <- Payload.decode(bytes) do
        {:cont, {:ok, regions ++ [{coord, bytes}], payloads ++ [{coord, payload}], state}}
      else
        _ -> {:halt, {:error, :canonical_incomplete}}
      end
    end)
  end

  defp canonical_chunks(state, coords) do
    groups = Enum.group_by(coords, &CollisionSource.region_coord/1)
    with {:ok, _, payloads, _} <- canonical_regions(state, groups |> Map.keys() |> Enum.sort()) do
      chunks = Enum.flat_map(payloads, fn {region, payload} ->
        Enum.map(Map.fetch!(groups, region), &CollisionSource.capture(payload, &1))
      end)
      {:ok, Enum.sort_by(chunks, & &1.coord)}
    end
  end

  defp capture_canonical_snapshot(state, {l0_min, l0_max} = box, include_chunks) do
    started = System.monotonic_time(:microsecond)
    with {:ok, regions, payloads, state} <- canonical_regions(state, CollisionSource.regions(box)) do
      chunks = if include_chunks, do: (payloads |> Enum.flat_map(fn {coord, payload} ->
        Enum.map(CollisionSource.chunk_coords(coord), &CollisionSource.capture(payload, &1))
      end) |> Enum.sort_by(& &1.coord)), else: []
      snapshot = %CanonicalSnapshot{content_version: state.cv, transaction_seq: state.seq,
        l0_min: l0_min, l0_max_exclusive: l0_max, regions: regions, chunks: chunks}
      Logger.info("voxel_region canonical_snapshot seq=#{state.seq} regions=#{length(regions)} chunks=#{length(chunks)} occupancy_bytes=#{Enum.sum(Enum.map(chunks, &byte_size(&1.cells)))} payload_bytes=#{Enum.sum(Enum.map(regions, &byte_size(elem(&1, 1))))} elapsed_us=#{System.monotonic_time(:microsecond)-started}")
      {:ok, snapshot, state}
    end
  end

  # Capture both versions while the pre-commit state still exists. Never sample after fanout.
  defp canonical_changes(%{canonical_subs: subs, replica_subs: replicas}, _after, _changed) when map_size(subs) == 0 and map_size(replicas) == 0, do: {:ok, []}
  defp canonical_changes(before, after_state, changed) do
    started = System.monotonic_time(:microsecond)
    boxes = (Map.values(before.canonical_subs) ++ Map.values(before.replica_subs)) |> Enum.uniq()
    coords = changed |> Enum.map(fn {0, cell} -> CollisionSource.chunk_coord(cell) end)
      |> Enum.uniq() |> Enum.filter(fn coord -> Enum.any?(boxes, &CollisionSource.in_box?(coord, &1)) end)
      |> Enum.sort()
    with {:ok, old} <- canonical_chunks(before, coords),
         {:ok, new} <- canonical_chunks(after_state, coords) do
      chunks = Enum.zip(old, new) |> Enum.flat_map(fn {a, b} -> if a.cells == b.cells, do: [], else: [b] end)
      Logger.info("voxel_region canonical_delta seq=#{after_state.seq} chunks=#{length(chunks)} occupancy_bytes=#{Enum.sum(Enum.map(chunks, &byte_size(&1.cells)))} capture_us=#{System.monotonic_time(:microsecond)-started}")
      {:ok, chunks}
    end
  end

  defp fanout_canonical(state, %{coord: _} = entry, chunks) do
    fanout_canonical(state, %{seq: entry.seq, entries: [%{entry | coarse: []}], coarse: entry.coarse}, chunks)
  end

  defp fanout_canonical(state, transaction, chunks) do
    Enum.each(state.canonical_subs, fn {pid, box} ->
      delta = %CanonicalDelta{transaction_seq: state.seq, transaction: transaction,
        chunks: Enum.filter(chunks, &CollisionSource.in_box?(&1.coord, box))}
      send(pid, {:canonical_delta, delta})
    end)

    # 同一事务受影响的区域只物化一次，再按各 Replica 的驻留范围分发。
    coords = state.replica_subs |> Map.values() |> Enum.flat_map(&CollisionSource.regions/1) |> Enum.uniq()
      |> Enum.filter(fn region ->
        case project_transaction(transaction, 0, region) do
          %{entries: [], coarse: []} -> false
          _ -> true
        end
      end) |> Enum.sort()
    {:ok, regions, _, _} = canonical_regions(state, coords)
    Enum.each(state.replica_subs, fn {pid, box} ->
      wanted = MapSet.new(CollisionSource.regions(box))
      delta = %CanonicalDelta{transaction_seq: state.seq, transaction: transaction,
        chunks: Enum.filter(chunks, &CollisionSource.in_box?(&1.coord, box))}
      send(pid, {:canonical_replica_delta, delta, Enum.filter(regions, &MapSet.member?(wanted, elem(&1, 0)))})
    end)
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
    state = if p.level == 0 do
      {ox,oy,oz} = Payload.origin(p.region)
      core = for {index,slots} <- p.refined,
        x = rem(index,66), y = rem(div(index,66),66), z = div(index,66*66),
        x in 1..64 and y in 1..64 and z in 1..64, into: %{}, do: {{ox+x,oy+y,oz+z},slots}
      refined = state.refined |> Map.reject(fn {cell,_} -> region_of(cell)==p.region end) |> Map.merge(core)
      instances = Map.merge(state.instances,p.instances)
      ids = live_instance_ids(refined,instances)
      %{state | refined: refined,instances: Map.take(instances,ids)}
    else
      state
    end
    # The region index includes its core and the one-cell ring. Replacing this
    # core can only invalidate overlay entries in this region and its neighbors;
    # scanning every accumulated region for each checkpoint was quadratic.
    core_cells = state.overlay_regions |> Map.get(key, MapSet.new()) |> Enum.filter(&(region_of(&1) == p.region))
    overlay = Map.drop(state.overlay, Enum.map(core_cells, &{p.level, &1}))
    {rx, ry, rz} = p.region
    neighbors = for x <- (rx-1)..(rx+1), y <- (ry-1)..(ry+1), z <- (rz-1)..(rz+1), do: {p.level, {x,y,z}}
    regions = Enum.reduce(Map.take(state.overlay_regions, neighbors), state.overlay_regions, fn {k,cells}, index ->
      Map.put(index, k, MapSet.filter(cells, &(region_of(&1) != p.region)))
    end)
    state = %{cache_clear(state) | decoded: Map.put(state.decoded, key, p), snapshots: MapSet.put(state.snapshots, key), overlay: overlay,
                       overlay_regions: regions}
    # 内部格直接从快照读取；边界格同时进入邻居 ring。
    for z <- 0..63, y <- 0..63, x <- 0..63, x in [0, 63] or y in [0, 63] or z in [0, 63], reduce: state do
      s -> put_overlay(s, p.level, {rx*64+x, ry*64+y, rz*64+z}, Payload.value(p, {x+1,y+1,z+1}))
    end
  end

  defp replay_entry(state, entry) do
    state = put_overlay(state, 0, entry.coord, {entry.material, MmoContracts.Voxel.Skins.uniform(entry.material)})
    Enum.reduce(entry.coarse, state, fn e, s -> put_overlay(s, e.level, e.cell, {e.material, e.skins}) end)
  end

  defp apply_batch(state, edits, legacy \\ false) do
    before = state
    started = System.monotonic_time(:microsecond)
    result = Enum.reduce_while(Map.new(edits), {[], state}, fn {cell,m}, {changed,s} ->
      case if(Map.has_key?(s.refined,cell),do: {:error,:refined_cell,s},else: cell_value(s, 0, cell)) do
        {:ok, {old,_}, s} when old == m -> {:cont, {changed,s}}
        {:ok, _, s} -> {:cont, {[{0,cell}|changed],put_overlay(s,0,cell,{m,MmoContracts.Voxel.Skins.uniform(m)})}}
        {:error,:missing,_} -> {:halt, {:error,:missing_region}}
        {:error,reason,_} -> {:halt, {:error,reason}}
      end
    end)
    case result do
      {:error, reason} -> {:error, reason}
      {[], state} -> {:ok,state}
      {changed,state} ->
        case reduce_batch(state,changed,1,changed,0) do
          {:error, reason} ->
            {:error, reason}

          {:ok,all,state,visits} ->
            state = %{state | seq: state.seq+1}
            {state,structure_keys} = refresh_structure(state,Enum.map(changed,&elem(&1,1)))
            legacy = legacy and structure_keys == []
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
            {txn,state} = if structure_keys == [] do
              {txn,state}
            else
              {afterimages,state} = region_afterimages(state,structure_keys)
              keys = MapSet.new(structure_keys)
              entries = Enum.reject(txn.entries,fn
                %{payload: bytes} -> {:ok,h}=Codec.decode_payload_header(bytes); MapSet.member?(keys,{h.level,h.region})
                _ -> false
              end)
              {%{txn | entries: entries++afterimages},state}
            end
            with {:ok, collision_chunks} <- canonical_changes(before, state, changed) do
            append_log(state,txn)
            state = %{state | entries: Map.put(state.entries,state.seq,txn)}
            fanout(state,txn)
            fanout_canonical(state,txn,collision_chunks)
            region_count = Enum.count(Map.get(txn,:entries,[]),&Map.has_key?(&1,:payload))
            state = if region_count > 0, do: compact_log(state), else: state
            Logger.info("voxel_region transaction seq=#{state.seq} canonical=#{length(changed)} reduced=#{visits} changed=#{length(all)} regions=#{region_count} bytes=#{IO.iodata_length(if legacy, do: Codec.encode_entry(txn), else: Codec.encode_transaction(txn))} elapsed_us=#{System.monotonic_time(:microsecond)-started}")
            {:ok,state}
            end
        end
    end
  end

  defp reduce_batch(state, [], _level, all, visits), do: {:ok,all,state,visits}
  defp reduce_batch(state, _dirty, level, all, visits) when level > @max_level, do: {:ok,all,state,visits}
  defp reduce_batch(state, dirty, level, all, visits) do
    parents = dirty |> Enum.map(fn {_,c} -> parent_of(c) end) |> Enum.uniq()
    result = Enum.reduce_while(parents,{[],state},fn parent,{changed,s} ->
      case child_values(s,level,parent) do
        {:ok,children,s} ->
          case cell_value(s,level,parent) do
            {:ok,old,s} ->
              new=Reducer.reduce_cell(children,level)
              next=if new==old, do: {changed,s}, else: {[{level,parent}|changed],put_overlay(s,level,parent,new)}
              {:cont,next}

            {:error,:missing,s} ->
              Logger.warning("voxel_region: L#{level} around #{inspect(parent)} not baked; reduce chain stops here")
              {:cont,{changed,s}}

            {:error,reason,_s} ->
              {:halt,{:error,reason}}
          end

        {:error,:missing,s} ->
          Logger.warning("voxel_region: L#{level} around #{inspect(parent)} not baked; reduce chain stops here")
          {:cont,{changed,s}}

        {:error,reason,_s} ->
          {:halt,{:error,reason}}
      end
    end)

    case result do
      {:error,reason} -> {:error,reason}
      {changed,state} -> reduce_batch(state,changed,level+1,changed++all,visits+length(parents))
    end
  end

  defp child_values(state,level,{px,py,pz}) do
    result = Enum.reduce_while(0..7,{[],state},fn oct,{children,s} ->
      cell={px*2+(oct &&& 1),py*2+((oct >>> 1) &&& 1),pz*2+((oct >>> 2) &&& 1)}
      case cell_value(s,level-1,cell) do
        {:ok,value,s} -> {:cont,{[value|children],s}}
        {:error,reason,s} -> {:halt,{:error,reason,s}}
      end
    end)

    case result do
      {:error,reason,state} -> {:error,reason,state}
      {children,state} -> {:ok,Enum.reverse(children),state}
    end
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
    {backend,handle}=state.log
    backend.checkpoint(handle,txn)
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
