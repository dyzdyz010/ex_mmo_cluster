defmodule VoxelRegion.World do
  @moduledoc """
  Voxim R6 的 region 真值：truth = 显式 baseline source ⊕ overlay 日志。

  - **日志**：全局单调 `seq`，每条 `cell` 条目 = canonical 格的新材质 + 服务端算好的各级 reduce 结果（材质 + 表皮，
    从 L1 向上、某级材质与表皮都没变即停）。批次共享一个 seq，父格逐级去重，只规约一次。
    文件 `<root>/<cv>/overlay.log`（`<<len::32, term>>`）记录选出的 region 快照与稀疏值；事务同步追加，启动或显式 compact 时压实完整前缀。
  - **真值物化**：`region_bases` 保留已提交完整区域的地形；当前 refined、instances、structure 由世界各自唯一持有。
    `overlay` 的 `{level, cell} → {material, skins}` 只保留后续逐格编辑。
    core 依次读取 overlay、区域基底、baseline；ring 从相邻 core 投影，不展开为常驻逐格增量。
  - **载荷**：`serve/1` 从当前基底和 overlay 物化区域，按当前 seq 编码；未受编辑或相邻基底影响的区域原样读 source。
    两者都进同一个可丢弃载荷缓存 `(level, region) → {bytes, header}`：
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
  alias VoxelRegion.{OverlayLog, Damage}
  alias VoxelRegion.{CollisionSource, FileStore, Prefab, Reducer}
  alias MmoContracts.Voxel.{CanonicalDelta, CanonicalSnapshot, Codec, Payload}

  @micro VoxelRegion.Spatial.micro_resolution()
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

  @doc "载荷缓存与生成统计，以及区域基底、稀疏增量、refined 宏格和 instance 数量；entries 指缓存条目数。"
  def stats(server \\ @name), do: GenServer.call(server, :stats)

  @doc "`POST /voxel/regions` 的整个请求 → 应答 iodata。"
  def serve(server \\ @name, request) when is_binary(request) do
    case Codec.decode_request(request) do
      {:ok, client_version, items} ->
        if Enum.all?(items, &valid_request_item?/1) do
          prepare(server, Enum.map(items, &{&1.level, &1.region}))

          # 一个 region（含 ring）在 owner 内原子物化；批次之间不独占 owner，交互可在区域之间提交。
          # cv 在 World 生命周期内不变，每个 payload 自带其物化时的 seq/hash。
          cv = GenServer.call(server, :content_version, 60_000)
          case Enum.reduce_while(items, {:ok, []}, fn item, {:ok, replies} ->
                 case GenServer.call(server, {:serve_item, client_version, item}, 60_000) do
                   {:ok, reply} -> {:cont, {:ok, [reply | replies]}}
                   {:error, _} = error -> {:halt, error}
                 end
               end) do
            {:ok, replies} -> {:ok, Codec.encode_reply(cv, Enum.reverse(replies))}
            error -> error
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
    {source, source_state, missing} = GenServer.call(server, {:prepare, Enum.uniq(keys)}, 300_000)

    missing
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

  def publish_properties(server,path), do: GenServer.call(server,{:publish_properties,Damage.load(path)})

  @doc "只测试作者入口：从资产导出的实验参数启动有限供能热源；不开放给 Gate 玩家意图。"
  def thermal_experiment(server,path), do: GenServer.call(server,{:thermal_experiment,Jason.decode!(File.read!(path))},300_000)

  @doc "角色确认余额；单位为一个 canonical 微格体积。"
  def material_balances(server,cid), do: GenServer.call(server,{:material_balances,cid},300_000)

  @doc "普通角色查询或付费建造，复用世界事务。"
  def production_intent(server,actor,request) do
    if valid_edit_coord?(request.coord) do
      if request.action == 1, do: prepare(server,edit_keys([request.coord]))
      GenServer.call(server,{:production_intent,actor,request},300_000)
    else
      {:error,:invalid_coordinate}
    end
  end

  def tool_intent(server, actor, request) do
    started = System.monotonic_time(:microsecond)
    # Cold generation remains outside the World mailbox; the authoritative ray is
    # evaluated again inside the atomic owner after preparation.
    range = GenServer.call(server,{:tool_range,request.tool_id},300_000)
    case range do
      {:error,_}=error -> error
      range ->
        if not valid_edit_coord?(Damage.macro(request)) do
          {:error,:invalid_coordinate}
        else
        {x,y,z}=actor.eye
        regions = for rx <- floor((x-range)/64)..floor((x+range)/64),
          ry <- floor((y-range)/64)..floor((y+range)/64),
          rz <- floor((z-range)/64)..floor((z+range)/64),do: {0,{rx,ry,rz}}
        prepare(server,regions)
        if request.action == 1, do: prepare(server,edit_keys([Damage.macro(request)]))
        prepared = System.monotonic_time(:microsecond)
        result = GenServer.call(server,{:tool_intent,actor,request},300_000)
        Logger.info("voxel_tool_call request_id=#{request.request_id} node=#{node()} prepare_us=#{prepared-started} owner_call_us=#{System.monotonic_time(:microsecond)-prepared}")
        result
        end
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
    started = System.monotonic_time(:microsecond)
    with {:ok,cells} <- replacement_cells(server,instance_id,definition_id) do
      range_done = System.monotonic_time(:microsecond)
      prepare(server,region_keys(Enum.map(cells,&{0,&1})))
      prepare_done = System.monotonic_time(:microsecond)
      result = GenServer.call(server,{:replace_prefab,instance_id,definition_id},300_000)
      Logger.info("voxel_prefab_replace range_us=#{range_done-started} prepare_us=#{prepare_done-range_done} " <>
        "commit_us=#{System.monotonic_time(:microsecond)-prepare_done}")
      result
    end
  end
  def replacement_cells(server,instance_id,definition_id), do: GenServer.call(server,{:replacement_cells,instance_id,definition_id},300_000)
  def prefab_cells(server,id,anchor,orientation), do: GenServer.call(server,{:prefab_cells,id,anchor,orientation})
  def instance_cells(server,id), do: GenServer.call(server,{:instance_cells,id})

  defp prefab_keys(cells) do
    cells |> footprint_macros() |> Enum.map(&{0,&1}) |> region_keys() |> Enum.uniq()
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
        cache_limit = Keyword.get(opts, :payload_cache_bytes, Application.get_env(:voxel_region, :payload_cache_bytes, @default_cache_bytes))
        # 允许常驻载荷达到既有缓存预算，避免过小的二进制阈值反复触发全堆 GC；不预分配内存。
        {:min_bin_vheap_size,min_bin_words} = Process.info(self(),:min_bin_vheap_size)
        Process.flag(:min_bin_vheap_size,max(min_bin_words,div(cache_limit,:erlang.system_info(:wordsize))))
        state = %{
          source: source,
          source_state: source_state,
          cv: cv,
          decoded: %{},
          region_bases: %{},
          snapshots: MapSet.new(),
          payloads: %{},
          lru: :gb_trees.empty(),
          lru_ticks: %{},
          tick: 0,
          lru_bytes: 0,
          resident_bytes: 0,
          cache_limit: cache_limit,
          cache_stats: %{hits: 0, misses: 0, evictions: 0},
          served_headers: %{},
          overlay: %{},
          refined: %{},
          damage: %{}, epochs: %{}, tool_sessions: %{},
          thermal: nil,
          thermal_work: empty_thermal_work(),
          material_balances: %{}, build_sessions: %{},
          production_materials: Keyword.get(opts,:production_materials,Application.get_env(:voxel_region,:production_materials,[])),
          properties: load_properties(opts),
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
        validate_damage_catalog(state)
        state = migrate_component_damage(state)
        {state, _, _} = refresh_structure(state, Map.keys(state.refined))
        state = if map_size(state.structure) > 0, do: compact_log(state), else: state
        state = rebuild_thermal_work(state)
        Logger.info("voxel_region world #{FileStore.hex(cv)} ready, seq=#{state.seq}, root=#{world_dir}")
        if state.thermal,do: Process.send_after(self(),:thermal_commit,500)
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

  def handle_call({:prepare, keys}, _from, state) do
    # decoded() can already read these regions without consulting the source.
    missing = Enum.filter(keys, &needs_source?(state,&1))
    {:reply, {state.source,state.source_state,missing}, state}
  end

  def handle_call({:publish_properties,catalog},_,state) do
    if Enum.all?(state.damage,fn {_,t}->t.digest == catalog.digest end) do
      {:reply,:ok,rebuild_thermal_work(%{state | properties: catalog})}
    else
      {:reply,{:error,:property_version_in_use},state}
    end
  end
  def handle_call({:thermal_experiment,config},_,state) do
    true = config["classification"]=="Test-only"
    true = config["ambient_kelvin"]>0 and config["environment_w_per_m2_k"]>0 and config["tolerance_kelvin"]>0
    true = config["power_w"]>0 and config["energy_j"]>0
    # 首片显式 Euler 的稳定步长条件；错误作者配置在开始实验前拒绝。
    true = Enum.all?(state.properties.materials,fn {_,m}->
      not Map.has_key?(m,"heat_capacity_per_macro") or
        0.05*6*(2*m["thermal_conductivity"]+config["environment_w_per_m2_k"])<=m["heat_capacity_per_macro"]
    end)
    micro=config["source_macro"] |> Enum.map(&(&1*@micro)) |> List.to_tuple()
    {%{granularity: 0}=target,state}=target_at(micro,state)
    true = Map.fetch!(state.properties.materials,target.material)["heat_capacity_per_macro"]>0
    source=%{target: target,power_w: config["power_w"],remaining_j: config["energy_j"]}
    thermal=%{config: config,sources: %{Damage.macro(target)=>source},elapsed_s: 0.0,supplied_j: 0.0,environment_j: 0.0,active: true}
    if state.thermal==nil,do: Process.send_after(self(),:thermal_commit,500)
    state=thermal_commit(rebuild_thermal_work(%{state | thermal: thermal}),[])
    {:reply,:ok,state}
  end
  def handle_call({:tool_range,id},_,state) do
    result = with %{tools: tools} <- state.properties, {:ok,tool} <- Map.fetch(tools,id),
      do: tool["range_macro"]
    {:reply,if(is_number(result),do: result,else: {:error,:invalid_tool}),state}
  end
  def handle_call({:material_balances,cid},_,state), do: {:reply,Enum.map(state.production_materials,&balance_state(state,cid,&1)),state}
  def handle_call({:production_intent,actor,request},_,state) do
    with {:ok,actor} <- current_actor(actor), true <- state.production_materials != [] do
      build_target(state,actor,request)
    else
      false -> {:reply,{:error,:production_unavailable},state}
      {:error,reason} -> {:reply,{:error,reason},state}
    end
  end
  def handle_call({:tool_intent,actor,request},_,state) do
    started = System.monotonic_time(:microsecond)
    before = state
    tool = Map.fetch!(state.properties.tools,request.tool_id)
    result = case current_actor(actor) do
      {:error,reason} -> {:reply,{:error,reason},before}
      {:ok,actor} ->
      refreshed = System.monotonic_time(:microsecond)
      Logger.info("voxel_tool_owner request_id=#{request.request_id} node=#{node()} started_us=#{started} refresh_us=#{refreshed-started}")
      case Damage.raycast(actor.eye,request.direction,tool["range_macro"],state,&target_at/2) do
      {:error,reason,_} -> {:reply,{:error,reason},before}
      {:ok,target,state} ->
        target = property_state(state,target)
        cond do
          request.action == 0 -> {:reply,{:ok,%{target | request_id: request.request_id}},state}
          not same_target?(target,request) -> {:reply,{:error,:stale_target},state}
          true -> attack_target(before,state,actor,request,target,tool)
        end
    end
    end
    Logger.info("voxel_tool_owner_done request_id=#{request.request_id} node=#{node()} elapsed_us=#{System.monotonic_time(:microsecond)-started}")
    result
  end

  def handle_call({:publish_prefabs,catalog},_from,state) do
    {:reply,:ok,%{state | prefabs: Map.merge(state.prefabs,catalog)}}
  end

  def handle_call({:prefab_cells,id,anchor,orientation}, _from,state) do
    result = with {:ok,cells,_macros} <- definition_cells(state,id,anchor,orientation),do: {:ok,cells}
    {:reply,result,state}
  end

  def handle_call({:instance_cells,id},_from,state) do
    cells = owner_cells(state,id)
    {:reply,if(cells == [],do: {:error,:instance_not_found},else: {:ok,cells}),state}
  end

  def handle_call({:replacement_cells,target,id},_from,state) do
    result = with {:ok,instance} <- fetch_instance(state,target),
      {:ok,_cells,macros} <- definition_cells(state,id,instance.anchor,instance.orientation) do
      {:ok,Enum.uniq(owner_cells(state,target) ++ macros)}
    end
    {:reply,result,state}
  end

  def handle_call({:place_prefab,id,anchor,orientation,_cells},_from,state) do
    place_tree(state,state,Map.fetch!(state.prefabs,id),anchor,orientation,{0,0},0,[])
  end

  def handle_call({:remove_prefab,id},_from,state) do
    ids = subtree_ids(state,id)
    case subtree_cells(state,ids) do
      [] -> {:reply,{:error,:instance_not_found},state}
      cells -> prefab_reply(state,clear_subtree(state,ids,cells),cells)
    end
  end

  def handle_call({:replace_prefab,target,id},_from,state) do
    with {:ok,instance} <- fetch_instance(state,target),
         {:ok,definition} <- Map.fetch(state.prefabs,id) do
      ids = subtree_ids(state,target)
      cells = subtree_cells(state,ids)
      next = clear_subtree(state,ids,cells)
      place_tree(state,next,definition,instance.anchor,instance.orientation,Map.get(instance,:parent_id,{0,0}),Map.get(instance,:component_slot,0),cells)
    else
      :error -> {:reply,{:error,:definition_not_found},state}
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
        overlay_cells: map_size(state.overlay),
        overlay_regions: map_size(state.overlay_regions),
        snapshot_regions: MapSet.size(state.snapshots),
        decoded_regions: map_size(state.decoded),
        region_bases: map_size(state.region_bases),
        refined_macros: map_size(state.refined),
        instances: map_size(state.instances),
        damaged_targets: map_size(state.damage),damage_state_bytes: :erlang.external_size(state.damage),
        property_digest: if(state.properties,do: Base.encode16(state.properties.digest,case: :lower)),
        generated: state.source.generated(state.source_state)
      })

    {:reply, stats, state}
  end

  def handle_call({:serve_item, client_version, item}, _from, state) do
    case serve_item(state, client_version, item) do
      {:error, reason, _state} -> {:reply, {:error, reason}, state}
      # 浏览请求只保留最终载荷缓存，期间解码的源数据随本区域释放。
      {reply, served} -> {:reply, {:ok, reply}, %{served | decoded: state.decoded}}
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
        {:reply, :ok, %{state | canonical_subs: Map.put(state.canonical_subs, pid, box)}}
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
  def handle_info(:thermal_commit,state) do
    started=System.monotonic_time(:microsecond)
    state=if state.thermal.active,do: advance_thermal(state),else: state
    Process.send_after(self(),:thermal_commit,500)
    if state.thermal.active,do: Logger.info("voxel_thermal_callback elapsed_us=#{System.monotonic_time(:microsecond)-started}")
    {:noreply,state}
  end
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state), do: {:noreply, %{state | subs: Map.delete(state.subs, pid), canonical_subs: Map.delete(state.canonical_subs, pid), replica_subs: Map.delete(state.replica_subs, pid), tool_sessions: Map.delete(state.tool_sessions,pid), build_sessions: Map.delete(state.build_sessions,pid)}}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def code_change(:region_bases, state, _extra), do: {:ok,Map.put_new(state,:region_bases,%{})}

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
        bases = neighboring_bases(state,level,region)

        if MapSet.size(cells) == 0 and not MapSet.member?(state.snapshots, key) and bases == [] do
          case state.source.read(state.source_state, level, region) do
            {:ok, bytes, header} -> {:ok, bytes, header, cache_put(state, key, bytes, header)}
            {:error, :missing} -> {:error, :missing, state}
            {:error, reason} -> {:error, reason, state}
          end
        else
          case decoded(state, level, region) do
            {:ok, payload, state} ->
              overrides = Map.new(cells, fn cell -> {Payload.local(region, cell), Map.fetch!(state.overlay, {level, cell})} end)
              overrides = Map.merge(ring_overrides(bases,region),overrides)
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

  # 已提交完整区域拥有自己的 core；ring 是相邻 core 的投影，不展开成常驻逐格增量。
  defp neighboring_bases(state,level,{rx,ry,rz}) do
    for dx <- -1..1,dy <- -1..1,dz <- -1..1,{dx,dy,dz} != {0,0,0},
      {:ok,p} <- [Map.fetch(state.region_bases,{level,{rx+dx,ry+dy,rz+dz}})],do: {p,{dx,dy,dz}}
  end

  defp ring_overrides(bases,region) do
    {ox,oy,oz} = Payload.origin(region)
    for {p,{dx,dy,dz}} <- bases,x <- ring_axis(dx),y <- ring_axis(dy),z <- ring_axis(dz),into: %{},
      do: {{x,y,z},Payload.value(p,Payload.local(p.region,{ox+x,oy+y,oz+z}))}
  end
  defp ring_axis(-1), do: 0..0
  defp ring_axis(0), do: 1..(Payload.extent()-2)
  defp ring_axis(1), do: (Payload.extent()-1)..(Payload.extent()-1)

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
      macros = footprint_macros(cells)
      if Enum.all?(macros,&valid_edit_coord?/1),
        do: {:ok,cells,macros}, else: {:error,:invalid_coordinate}
    else
      :error -> {:error,:definition_not_found}
      false -> {:error,:invalid_orientation}
    end
  end

  defp footprint_macros(cells) do
    cells |> Enum.map(fn {micro,_} -> elem(Prefab.macro_slot(micro),0) end) |> Enum.uniq()
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
    subtree_cells(state,subtree_ids(state,id))
  end

  defp subtree_cells(state,ids) do
    for {cell,slots} <- state.refined, Enum.any?(slots,fn {_,{_,owner}} -> MapSet.member?(ids,owner) end), do: cell
  end

  defp clear_subtree(state,ids,cells) do
    next = Enum.reduce(cells,state,fn cell,s ->
      slots = Map.fetch!(s.refined,cell) |> Map.reject(fn {_,{_,owner}} -> MapSet.member?(ids,owner) end)
      refined = if map_size(slots) == 0,do: Map.delete(s.refined,cell),else: Map.put(s.refined,cell,slots)
      put_overlay(%{s | refined: refined},0,cell,{0,MmoContracts.Voxel.Skins.uniform(0)})
    end)
    %{next | instances: Map.drop(next.instances,MapSet.to_list(ids))}
  end

  defp place_tree(before,state,definition,anchor,orientation,parent,slot,changed) do
    nodes = Prefab.occurrences(definition,anchor,orientation,before.seq+1,parent,slot)
    # 已发布定义保证 slot 不重叠；按 canonical macro 汇集后，每格只更新一次世界索引和缓存。
    additions = for {owner,_,cells} <- nodes, {micro,material} <- cells, reduce: %{} do
      acc ->
        {cell,micro_slot} = Prefab.macro_slot(micro)
        Map.update(acc,cell,%{micro_slot=>{material,owner}},&Map.put(&1,micro_slot,{material,owner}))
    end
    # 在当前权威提交中检查这次实际构造的占用，不另展开一份模板作预检。
    result = if Enum.all?(Map.keys(additions),&valid_edit_coord?/1) do
      Enum.reduce_while(additions,{:ok,state},fn {cell,added},{:ok,s} ->
        slots = Map.get(s.refined,cell,%{})
        case cell_value(s,0,cell) do
          {:ok,{0,_},s} ->
            if Enum.any?(added,fn {slot,_}->Map.has_key?(slots,slot) end) do
              {:halt,{:error,:occupied}}
            else
              s = %{s | refined: Map.put(s.refined,cell,Map.merge(slots,added))}
              {:cont,{:ok,put_overlay(s,0,cell,{0,MmoContracts.Voxel.Skins.uniform(0)})}}
            end
          {:ok,_,_} -> {:halt,{:error,:occupied}}
          {:error,reason,_} -> {:halt,{:error,reason}}
        end
      end)
    else
      {:error,:invalid_coordinate}
    end
    case result do
      {:ok,next} ->
        instances = Enum.reduce(nodes,next.instances,fn {owner,instance,_},acc->Map.put(acc,owner,instance) end)
        prefab_reply(before,%{next | instances: instances},Enum.uniq(Map.keys(additions)++changed))
      {:error,reason} -> {:reply,{:error,reason},before}
    end
  end

  defp live_instance_ids(refined,instances) do
    owners = Enum.reduce(refined,%{},fn {_,slots},acc ->
      local = Enum.reduce(slots,%{},fn {_,{_,id}},owners -> Map.put(owners,id,true) end)
      Map.merge(acc,local)
    end)
    MmoContracts.Voxel.Refined.ancestors(instances,Map.keys(owners))
  end

  defp prefab_reply(before,state,cells,settlement \\ %{}) do
    started = System.monotonic_time(:microsecond)
    state = %{state | seq: before.seq+1,instances: Map.take(state.instances,live_instance_ids(state.refined,state.instances))}
    # owner 更换仍发布完整 L0；只有实际 slot/材质变化才重建结构和碰撞。
    material_changes = Enum.filter(cells,fn cell ->
      old = Map.get(before.refined,cell,%{})
      new = Map.get(state.refined,cell,%{})
      map_size(old) != map_size(new) or Enum.any?(old,fn {slot,{material,_}} ->
        case Map.get(new,slot) do
          {^material,_} -> false
          _ -> true
        end
      end)
    end)
    terrain_payloads = state.payloads
    {state, structure_keys, structure_cells} = refresh_structure(state,material_changes)
    structure_done = System.monotonic_time(:microsecond)
    l0_keys = region_keys(Enum.map(cells,&{0,&1}))
    keys = l0_keys ++ structure_keys
    {entries,state} = region_afterimages(state,l0_keys,terrain_payloads)
    region_count = length(entries)
    entries = entries ++ Enum.map(Enum.sort(structure_cells),fn {level,cell}=key ->
      %{seq: state.seq,level: level,cell: cell,structure: Map.get(state.structure,key,<<>>)}
    end)
    regions_done = System.monotonic_time(:microsecond)
    {state,metadata} = damage_geometry(before,state,cells,false)
    txn = Map.merge(%{seq: state.seq,entries: entries,coarse: []},metadata) |> Map.merge(settlement)
    with {:ok,chunks} <- canonical_changes(before,state,Enum.map(material_changes,&{0,&1})),
         collision_done = System.monotonic_time(:microsecond),
         :ok <- append_log(state,txn) do
      log_done = System.monotonic_time(:microsecond)
      state = %{state | entries: Map.put(state.entries,state.seq,txn)}
      fanout(state,txn)
      fanout_canonical(state,txn,chunks,keys,before)
      Logger.info("voxel_prefab seq=#{state.seq} cells=#{length(cells)} regions=#{region_count} structure_cells=#{length(structure_cells)} " <>
        "state_structure_us=#{structure_done-started} regions_us=#{regions_done-structure_done} " <>
        "collision_us=#{collision_done-regions_done} log_us=#{log_done-collision_done} " <>
        "fanout_us=#{System.monotonic_time(:microsecond)-log_done}")
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

  defp region_afterimages(state,keys,terrain_payloads,terrain_changes \\ []) do
    Enum.map_reduce(Enum.sort(Enum.uniq(keys)),state,fn {level,region}=key,s ->
      started = System.monotonic_time(:microsecond)
      s = %{cache_delete(s,key) | snapshots: MapSet.put(s.snapshots,key)}
      {bytes,s} = case Map.fetch(terrain_payloads,key) do
        {:ok,{prior,_}} ->
          details = with_refined(s,%Payload{level: level,region: region})
          overrides = for {^level,cell} <- terrain_changes,local = Payload.local(region,cell),
            Payload.in_span?(local),into: %{},do: {local,Map.fetch!(s.overlay,{level,cell})}
          bytes = if map_size(overrides)==0 do
            Payload.replace_details(prior,details,s.seq,s.cv)
          else
            Payload.replace_cells_and_details(prior,overrides,details,s.seq,s.cv)
          end
          {:ok,header} = Codec.decode_payload_header(bytes)
          {bytes,cache_put(s,key,bytes,header)}
        :error ->
          if needs_source?(s,key),do: :ok = s.source.ensure(s.source_state,level,region)
          {:ok,bytes,_,s} = payload_bytes(s,level,region)
          {bytes,s}
      end
      Logger.info("voxel_region_afterimage seq=#{s.seq} level=#{level} region=#{inspect(region)} reused=#{Map.has_key?(terrain_payloads,key)} elapsed_us=#{System.monotonic_time(:microsecond)-started}")
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
                # cell_value 优先读已解码真值；冷 miss 由源 read 自行物化，不逐采样预检文件。
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
    {state,region_keys(changed),changed}
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

  defp cache_clear(state), do: %{state | decoded: %{}, payloads: %{}, lru: :gb_trees.empty(), lru_ticks: %{}, lru_bytes: 0, resident_bytes: 0}

  defp count(state, field), do: %{state | cache_stats: Map.update!(state.cache_stats, field, &(&1 + 1))}

  defp decoded(state, level, region) do
    key = {level, region}

    case Map.fetch(state.region_bases,key) do
      {:ok,payload} -> {:ok,payload,state}
      :error -> decoded_source(state,key)
    end
  end

  defp decoded_source(state,{level,region}=key) do
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

  defp put_overlay(state, level, cell, value) do
    if Map.get(state.overlay,{level,cell}) == value do
      state
    else
      regions = region_keys([{level,cell}])
      Enum.reduce(regions, %{state | overlay: Map.put(state.overlay, {level, cell}, value)}, fn key, state ->
        %{cache_delete(state, key) | overlay_regions: Map.update(state.overlay_regions, key, MapSet.new([cell]), &MapSet.put(&1, cell))}
      end)
    end
  end

  # ---- 日志

  defp append_log(%{log: {backend, handle}}, txn), do: backend.append(handle, txn)

  defp replay_log(%{log: {backend, handle}} = state) do
    Enum.reduce(backend.replay(handle), state, fn txn, s ->
      s = replay_entry(s, txn) |> replay_damage(txn)
      %{s | seq: max(s.seq, txn.seq), entries: Map.put(s.entries, txn.seq, txn)}
    end)
  end

  # ---- 订阅

  defp fanout(state, entry) do
    Enum.each(state.subs, fn {pid, filter} -> send_filtered(pid, entry, filter) end)
  end

  # serve 与副本共用物化字节；快照头只推进到当前事务前缀。
  defp canonical_region_bytes(state,coord) do
    with {:ok,bytes,_,state} <- payload_bytes(state,0,coord) do
      {:ok,Codec.stamp_payload_seq(bytes,state.seq),state}
    end
  end

  defp canonical_regions(state, coords) do
    Enum.reduce_while(coords, {:ok, [], [], state}, fn coord, {:ok, regions, payloads, state} ->
      with {:ok, bytes, state} <- canonical_region_bytes(state, coord),
           {:ok, payload} <- Payload.decode(bytes) do
        {:cont, {:ok, regions ++ [{coord, bytes}], payloads ++ [{coord, payload}], state}}
      else
        _ -> {:halt, {:error, :canonical_incomplete}}
      end
    end)
  end

  defp canonical_chunks(state, coords) do
    groups = Enum.group_by(coords, &CollisionSource.region_coord/1)
    result = Enum.reduce_while(groups,{:ok,[],state},fn {region,coords},{:ok,chunks,s} ->
      case decoded(s,0,region) do
        {:ok,p,s} ->
          value_at = fn cell ->
            material = case Map.fetch(s.overlay,{0,cell}) do
              {:ok,{material,_}} -> material
              :error -> Payload.material(p,Payload.local(region,cell))
            end
            {material,Map.get(s.refined,cell,%{})}
          end
          {:cont,{:ok,Enum.map(coords,&CollisionSource.capture(&1,value_at))++chunks,s}}
        _ -> {:halt,{:error,:canonical_incomplete}}
      end
    end)
    case result do
      {:ok,chunks,_} -> {:ok,Enum.sort_by(chunks,& &1.coord)}
      error -> error
    end
  end

  defp capture_canonical_snapshot(state, {l0_min, l0_max} = box, include_chunks) do
    started = System.monotonic_time(:microsecond)
    with {:ok, regions, payloads, state} <- canonical_regions(state, CollisionSource.regions(box)) do
      regions_done = System.monotonic_time(:microsecond)
      chunks = if include_chunks, do: (payloads |> Enum.flat_map(fn {coord, payload} ->
        Enum.map(CollisionSource.chunk_coords(coord), &CollisionSource.capture(payload, &1))
      end) |> Enum.sort_by(& &1.coord)), else: []
      snapshot = %CanonicalSnapshot{content_version: state.cv, transaction_seq: state.seq,
        l0_min: l0_min, l0_max_exclusive: l0_max, regions: regions, chunks: chunks}
      chunks_done = System.monotonic_time(:microsecond)
      snapshot = Map.merge(snapshot, property_snapshot(state, box))
      Logger.info("voxel_window_prepare seq=#{state.seq} box=#{inspect(box)} regions_us=#{regions_done-started} collision_us=#{chunks_done-regions_done} properties_us=#{System.monotonic_time(:microsecond)-chunks_done}")
      Logger.info("voxel_region canonical_snapshot seq=#{state.seq} regions=#{length(regions)} chunks=#{length(chunks)} occupancy_bytes=#{Enum.sum(Enum.map(chunks, &byte_size(&1.cells)))} payload_bytes=#{Enum.sum(Enum.map(regions, &byte_size(elem(&1, 1))))} elapsed_us=#{System.monotonic_time(:microsecond)-started}")
      {:ok, snapshot, state}
    end
  end

  # 全局系统功能：占用与属性在同一 GenServer 提交点采样。
  defp property_context(state) do
    %{hp_enabled: state.properties != nil,
      digest: if(state.properties, do: state.properties.digest, else: <<0::256>>),
      thermal_enabled: state.thermal != nil,
      ambient_kelvin: if(state.thermal, do: state.thermal.config["ambient_kelvin"], else: 0.0)}
  end

  defp component_observations(%{properties: nil}, _box), do: []
  defp component_observations(state, box) do
    owners = for {cell, slots} <- state.refined,
      box == nil or VoxelRegion.PropertyObservation.contains?(cell, box),
      {slot, {material, {birth, _} = owner}} <- slots, into: %{} do
      {owner, %{micro: Prefab.micro_coord(cell, slot), granularity: 2,
        incarnation: birth, owner: owner, material: material}}
    end
    Enum.map(owners, fn {owner, target} ->
      property_state(state, target)
      |> Map.put(:observation_cells, subtree_cells(state, MapSet.new([owner])))
    end)
  end

  defp property_snapshot(state, box) do
    macros = for {_, t} <- state.damage, t.granularity == 0,
      VoxelRegion.PropertyObservation.relevant?(t, box), do: %{t | seq: state.seq, request_id: 0}
    %{property_states: macros ++ component_observations(state, box),
      property_context: property_context(state), epochs: state.epochs}
    |> VoxelRegion.PropertyObservation.project(box)
  end

  defp property_transaction(before, state, txn) do
    # 几何变化发布统一叶子汇总；删除保留提交前实际占用范围。
    changed_owners = if Map.get(txn, :entries, []) == [], do: MapSet.new(), else:
      MapSet.new(for cell <- Enum.uniq(Map.keys(before.refined) ++ Map.keys(state.refined)),
        Map.get(before.refined,cell) != Map.get(state.refined,cell),
        {_,{_,owner}} <- Map.to_list(Map.get(before.refined,cell,%{})) ++ Map.to_list(Map.get(state.refined,cell,%{})),
        do: owner)
    fresh = if MapSet.size(changed_owners) == 0, do: [], else:
      Enum.filter(component_observations(state, nil), &MapSet.member?(changed_owners, &1.owner))
    removed = if MapSet.size(changed_owners) == 0, do: [], else:
      component_observations(before, nil)
      |> Enum.filter(&(MapSet.member?(changed_owners, &1.owner) and not Map.has_key?(state.instances, &1.owner)))
      |> Enum.map(&%{&1 | seq: state.seq, hp: 0.0, flags: 1, request_id: 0})
    # 纯属性提交由唯一目标集合产生；只有几何变化合并三种来源时才需要按身份去重。
    rows = if MapSet.size(changed_owners) == 0, do: Map.get(txn, :property_states, []), else:
      (removed ++ Map.get(txn, :property_states, []) ++ fresh) |> Map.new(&{Damage.key(&1), &1}) |> Map.values()
    rows = Enum.map(rows, fn
      %{granularity: 2} = row ->
        cells = subtree_cells(before, MapSet.new([row.owner])) ++ subtree_cells(state, MapSet.new([row.owner]))
        Map.put(row, :observation_cells, Enum.uniq(cells))
      row -> row
    end)
    Map.merge(txn, %{property_states: rows, property_context: property_context(state)})
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

  defp fanout_canonical(%{canonical_subs: subs, replica_subs: replicas}, _txn, _chunks, _keys, _before)
       when map_size(subs) == 0 and map_size(replicas) == 0, do: :ok

  defp fanout_canonical(state, %{coord: _} = entry, chunks, keys, before) do
    fanout_canonical(state, Map.merge(%{seq: entry.seq, entries: [%{entry | coarse: []}], coarse: entry.coarse},Map.take(entry,[:property_states,:epochs])), chunks, keys, before)
  end

  defp fanout_canonical(state, transaction, chunks, keys, before) do
    transaction = property_transaction(before, state, transaction)
    Enum.each(state.canonical_subs, fn {pid, box} ->
      delta = %CanonicalDelta{transaction_seq: state.seq, transaction: VoxelRegion.PropertyObservation.project(transaction, box),
        chunks: Enum.filter(chunks, &CollisionSource.in_box?(&1.coord, box))}
      send(pid, {:canonical_delta, delta})
    end)

    # 两种提交入口都按实际变动格提供区域集合；条目的压缩形式不决定更新范围。
    wanted = state.replica_subs |> Map.values() |> Enum.flat_map(&CollisionSource.regions/1) |> MapSet.new()
    afterimages = Enum.reduce(transaction.entries,%{},fn
      %{payload: bytes},ready ->
        {:ok,h} = Codec.decode_payload_header(bytes)
        if h.level == 0,do: Map.put(ready,h.region,bytes),else: ready
      %{coord: _},ready -> ready
      %{structure: _},ready -> ready
    end)
    coords = for {0,region} <- keys,MapSet.member?(wanted,region),do: region
    coords = coords |> Enum.uniq() |> Enum.sort()
    # Replica 只消费字节；需要占用投影的快照/碰撞调用方才解码。
    {regions,_} = Enum.map_reduce(coords,state,fn coord,s ->
      case Map.fetch(afterimages,coord) do
        {:ok,bytes} -> {{coord,bytes},s}
        :error ->
          {:ok,bytes,s} = canonical_region_bytes(s,coord)
          {{coord,bytes},s}
      end
    end)
    Enum.each(state.replica_subs, fn {pid, box} ->
      wanted = MapSet.new(CollisionSource.regions(box))
      delta = %CanonicalDelta{transaction_seq: state.seq, transaction: VoxelRegion.PropertyObservation.project(transaction, box),
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

  defp matches?(%{structure: _,level: level,cell: cell},filter), do: matches_cell?(level,cell,filter)

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
      %{structure: _,level: l,cell: cell} -> l==level and Payload.in_span?(Payload.local(region,cell))
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
    rebase_region(state,p)
  end

  defp replay_entry(state, %{structure: grid,level: level,cell: cell}) do
    key={level,cell}
    structure=if grid==<<>>,do: Map.delete(state.structure,key),else: Map.put(state.structure,key,grid)
    Enum.reduce(region_keys([key]),%{state | structure: structure},fn region,s ->
      %{cache_delete(s,region) | snapshots: MapSet.put(s.snapshots,region)}
    end)
  end

  defp replay_entry(state, entry) do
    state = put_overlay(state, 0, entry.coord, {entry.material, MmoContracts.Voxel.Skins.uniform(entry.material)})
    Enum.reduce(entry.coarse, state, fn e, s -> put_overlay(s, e.level, e.cell, {e.material, e.skins}) end)
  end

  defp rebase_region(state,p) do
    key = {p.level,p.region}
    # 检查点已包含这个 core 的全部真值；移除已吸收的稀疏编辑及其邻区索引。
    core_cells = state.overlay_regions |> Map.get(key, MapSet.new()) |> Enum.filter(&(region_of(&1) == p.region))
    overlay = Map.drop(state.overlay, Enum.map(core_cells, &{p.level, &1}))
    {rx, ry, rz} = p.region
    neighbors = for x <- (rx-1)..(rx+1), y <- (ry-1)..(ry+1), z <- (rz-1)..(rz+1), do: {p.level, {x,y,z}}
    regions = Enum.reduce(Map.take(state.overlay_regions, neighbors), state.overlay_regions, fn {k,cells}, index ->
      Map.put(index, k, MapSet.filter(cells, &(region_of(&1) != p.region)))
    end)
    # 当前后缀由世界的 refined/instances/structure 唯一持有，基底只保留地形。
    p = %{p | refined: %{},instances: %{},structure: %{}}
    %{cache_clear(state) | region_bases: Map.put(state.region_bases,key,p),
      snapshots: MapSet.put(state.snapshots,key),overlay: overlay,overlay_regions: regions}
  end

  defp apply_batch(state, edits, legacy \\ false, settlement \\ %{}) do
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
            reduced = System.monotonic_time(:microsecond)
            state = %{state | seq: state.seq+1}
            state = refresh_macro_payloads(before,state,changed)
            cached = System.monotonic_time(:microsecond)
            terrain_payloads = Map.merge(before.payloads,state.payloads)
            {state,structure_keys,_} = refresh_structure(state,Enum.map(changed,&elem(&1,1)))
            structured = System.monotonic_time(:microsecond)
            legacy = legacy and structure_keys == []
            {txn,state} = if legacy do
              [{coord,material}]=edits
              coarse=for {level,cell} <- Enum.sort(all), level > 0 do
                {m,skins}=Map.fetch!(state.overlay,{level,cell})
                %{level: level,cell: cell,material: m,skins: skins}
              end
              {%{seq: state.seq,coord: coord,material: material,coarse: coarse},state}
            else
              # afterimage 已包含该 core 的地形与结构；选择前排除，避免完整编码两次。
              covered = MapSet.new(structure_keys)
              sparse = Enum.reject(all,fn {level,cell}->MapSet.member?(covered,{level,region_of(cell)}) end)
              select_transaction(state,sparse)
            end
            {txn,state} = if structure_keys == [] do
              {txn,state}
            else
              {afterimages,state} = region_afterimages(state,structure_keys,terrain_payloads,all)
              {%{txn | entries: txn.entries++afterimages},state}
            end
            {state,metadata} = damage_geometry(before,state,Enum.map(changed,&elem(&1,1)),true)
            imaged = System.monotonic_time(:microsecond)
            txn = Map.merge(txn,metadata) |> Map.merge(settlement)
            with {:ok, collision_chunks} <- canonical_changes(before, state, changed),
                 collided = System.monotonic_time(:microsecond),
                 :ok <- append_log(state,txn) do
            appended = System.monotonic_time(:microsecond)
            state = %{state | entries: Map.put(state.entries,state.seq,txn)}
            fanout(state,txn)
            fanout_canonical(state,txn,collision_chunks,region_keys(changed),before)
            Logger.info("voxel_macro_stages seq=#{state.seq} reduce_us=#{reduced-started} l0_cache_us=#{cached-reduced} structure_us=#{structured-cached} regions_us=#{imaged-structured} collision_us=#{collided-imaged} log_us=#{appended-collided} fanout_us=#{System.monotonic_time(:microsecond)-appended}")
            region_count = Enum.count(Map.get(txn,:entries,[]),&Map.has_key?(&1,:payload))
            Logger.info("voxel_region transaction seq=#{state.seq} canonical=#{length(changed)} reduced=#{visits} changed=#{length(all)} regions=#{region_count} bytes=#{IO.iodata_length(if legacy, do: Codec.encode_entry(txn), else: Codec.encode_transaction(txn))} elapsed_us=#{System.monotonic_time(:microsecond)-started}")
            {:ok,state}
            end
        end
    end
  end

  defp needs_source?(state,key),
    do: not Map.has_key?(state.region_bases,key) and not Map.has_key?(state.decoded,key)

  # 宏格编辑已排除refined cell，故L0细节后缀未变；仅更新已有热缓存，冷缺失仍由真值物化。
  defp refresh_macro_payloads(before,state,changed) do
    Enum.reduce(Enum.uniq(region_keys(changed)),state,fn {0,region}=key,s ->
      case Map.fetch(before.payloads,key) do
        {:ok,{prior,_}} ->
          materials = for {0,cell} <- changed,local=Payload.local(region,cell),Payload.in_span?(local),
            into: %{},do: {local,elem(Map.fetch!(s.overlay,{0,cell}),0)}
          bytes = Payload.replace_uniform_cells(prior,materials,s.seq,s.cv)
          {:ok,header} = Codec.decode_payload_header(bytes)
          cache_put(s,key,bytes,header)
        :error -> s
      end
    end)
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
    entry_overhead=4+IO.iodata_length(Codec.encode_entry(%{seq: state.seq,payload: <<>>}))
    minimum_region_bytes=entry_overhead+Codec.payload_min_bytes()
    groups=Enum.group_by(changed,fn {level,cell}->{level,region_of(cell)} end)
    Enum.reduce(Enum.sort(groups), {%{seq: state.seq,entries: [],coarse: []},state},fn {{level,region},keys},{txn,s}->
      started = System.monotonic_time(:microsecond)
      sparse=Enum.map(Enum.sort(keys),fn {level,cell}->
        {m,skins}=Map.fetch!(s.overlay,{level,cell})
        if level==0, do: %{seq: s.seq,coord: cell,material: m,coarse: []}, else: %{level: level,cell: cell,material: m,skins: skins}
      end)
      cell_bytes=Enum.reduce(sparse,0,fn e,n -> n+if(level==0,do: 4+IO.iodata_length(Codec.encode_entry(e)),else: IO.iodata_length(Codec.encode_coarse(e))) end)
      {bytes,s}=if cell_bytes > minimum_region_bytes do
        {:ok,bytes,_header,next}=payload_bytes(s,level,region)
        {bytes,next}
      else
        {nil,s}
      end
      Logger.info("voxel_select_region seq=#{s.seq} level=#{level} region=#{inspect(region)} sparse_bytes=#{cell_bytes} region_bytes=#{if bytes,do: byte_size(bytes),else: 0} elapsed_us=#{System.monotonic_time(:microsecond)-started}")
      if bytes != nil and cell_bytes > entry_overhead+byte_size(bytes) do
        {%{txn | entries: txn.entries++[region_entry(s.seq,bytes)]},s}
      else
        if level==0, do: {%{txn | entries: txn.entries++sparse},s}, else: {%{txn | coarse: txn.coarse++sparse},s}
      end
    end)
  end

  defp compact_log(%{seq: 0}=state), do: state
  defp compact_log(state) do
    # 检查点覆盖完整前缀；当前 seq 对任意更旧游标都是完整补丁。
    # 已有完整区域会在下方写入当前 after-image，不再先编码同一 core 的逐格条目。
    sparse = for {{level,cell}=key,_} <- state.overlay,
      not MapSet.member?(state.snapshots,{level,region_of(cell)}),do: key
    {txn,state}=select_transaction(state,sparse)
    {extra,state}=Enum.map_reduce(state.snapshots,state,fn {level,region},s ->
      {:ok,bytes,_,s}=payload_bytes(s,level,region)
      {region_entry(s.seq,bytes),s}
    end)
    txn=Map.merge(%{txn | entries: txn.entries++extra},%{property_states: Map.values(state.damage),epochs: state.epochs,material_balances: state.material_balances,thermal: state.thermal})
    {backend,handle}=state.log
    backend.checkpoint(handle,txn)
    state = Enum.reduce(txn.entries,state,fn
      %{payload: bytes},s ->
        {:ok,p} = Payload.decode(bytes)
        rebase_region(s,p)
      _,s -> s
    end)
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
  defp load_properties(opts) do
    case Keyword.get(opts,:property_catalog_path,Application.get_env(:voxel_region,:property_catalog_path)) do
      nil -> nil
      path -> Damage.load(path)
    end
  end

  defp target_at(micro,state) do
    {cell,slot} = Prefab.macro_slot(micro)
    case Map.fetch(state.refined,cell) do
      {:ok,slots} ->
        case Map.fetch(slots,slot) do
          {:ok,{material,{birth,_}=owner}} -> {%{micro: micro,granularity: 2,
            incarnation: birth,owner: owner,material: material},state}
          :error -> {nil,state}
        end
      :error ->
        {:ok,{material,_},state}=cell_value(state,0,cell)
        target = if material != 0,do: %{micro: cell |> Tuple.to_list() |> Enum.map(&(&1*@micro)) |> List.to_tuple(),
          granularity: 0,incarnation: Map.get(state.epochs,cell,0),owner: {0,0},material: material}
        {target,state}
    end
  end

  defp property_state(state,target) do
    m = Map.fetch!(state.properties.materials,target.material)
    case Map.fetch(state.damage,Damage.key(target)) do
      {:ok,t} -> Map.merge(t,target) |> Map.merge(%{seq: state.seq,request_id: 0,defense: m["defense"]*1.0})
      :error ->
        hp = if target.granularity==2,do: component_max_hp(state,target.owner),else: Damage.max_hp(m,0)
        row=Map.merge(target,%{seq: state.seq,request_id: 0,hp: hp,max_hp: hp,
          defense: m["defense"]*1.0,digest: state.properties.digest,flags: 0})
        if state.thermal && target.granularity==0 && Map.has_key?(m,"heat_capacity_per_macro"),
          do: Map.put(row,:temperature_kelvin,state.thermal.config["ambient_kelvin"]),else: row
    end
  end

  # 全局系统功能：温度和 HP 仍由同一个 World 的稀疏状态记录持有。
  # 首片每 500 ms 提交一次，内部执行十个 50 ms 模拟步；持久化先于观察广播。
  # 派生工作集不写日志；缓存只含身份、材质与暴露面，数值批次读取当前权威记录。
  defp empty_thermal_work, do: %{hot: MapSet.new(),cells: MapSet.new(),geometry: %{},edges: [],builds: 0,
    seeds: nil,ordered: [],indexed_edges: []}

  defp rebuild_thermal_work(%{thermal: nil}=state), do: %{state | thermal_work: empty_thermal_work()}
  defp rebuild_thermal_work(state) do
    hot=for {_,t}<-state.damage,Map.has_key?(t,:temperature_kelvin),
      abs(t.temperature_kelvin-state.thermal.config["ambient_kelvin"])>state.thermal.config["tolerance_kelvin"],
      into: MapSet.new(),do: Damage.macro(t)
    %{state | thermal_work: %{empty_thermal_work() | hot: hot}}
  end

  defp advance_thermal(state) do
    start=System.monotonic_time(:microsecond)
    before=state
    state=put_in(state.thermal_work.builds,0)
    {state,visited}=thermal_steps(state,10,MapSet.new())
    work=state.thermal_work
    Logger.info("voxel_thermal_sim steps=10 step_ms=50 elapsed_us=#{System.monotonic_time(:microsecond)-start} hot=#{MapSet.size(work.hot)} candidates=#{map_size(work.geometry)} geometry_builds=#{work.builds}")
    rows=for key<-visited,t<-[Map.fetch!(state.damage,key)],Map.get(before.damage,key)!=t,
      do: %{t | seq: state.seq+1,request_id: 0}
    dead=Enum.filter(rows,&(&1.hp==0.0))
    if dead==[] do
      thermal_commit(state,rows)
    else
      # 归零与占用删除在原宏格损伤事务中一起持久化，不能留下已提交的零血量实体。
      # 同一步其他节点的温度、热源余量也属于这笔事务；热损伤不发放采掘奖励。
      rows=Enum.map(rows,fn t -> if t.hp==0.0,do: %{t | flags: 1},else: t end)
      state=%{state | damage: Enum.reduce(rows,state.damage,fn t,all->Map.put(all,Damage.key(t),t) end)}
      {:ok,state}=apply_batch(state,Enum.map(dead,&{Damage.macro(&1),0}),false,%{property_states: rows})
      state
    end
  end

  defp thermal_steps(state,0,visited), do: {state,visited}
  defp thermal_steps(state,steps,visited) do
    {state,changed,done}=thermal_step(state,0.05,steps)
    thermal_steps(state,steps-done,MapSet.union(visited,changed))
  end

  defp thermal_step(state,dt,steps) do
    started=System.monotonic_time(:microsecond)
    config=state.thermal.config
    seeds=MapSet.union(state.thermal_work.hot,MapSet.new(Map.keys(state.thermal.sources)))
    # 热种子不变时复用六邻域；编辑仍通过 geometry 删除使拓扑失效。
    cells=if seeds==state.thermal_work.seeds,do: state.thermal_work.cells,
      else: seeds |> Enum.flat_map(&[&1|VoxelRegion.Thermal.neighbors(&1)]) |> MapSet.new()
    # 上批 geometry 的键恰好是 cells；编辑只会删键。集合未变且未删键时直接复用。
    reuse_geometry=cells==state.thermal_work.cells and map_size(state.thermal_work.geometry)==MapSet.size(cells)
    missing=if reuse_geometry,do: MapSet.new(),else: MapSet.difference(cells,MapSet.new(Map.keys(state.thermal_work.geometry)))
    neighborhood_done=System.monotonic_time(:microsecond)
    geometry=if reuse_geometry,do: state.thermal_work.geometry,else: Map.take(state.thermal_work.geometry,MapSet.to_list(cells))
    {geometry,state}=Enum.reduce(missing,{geometry,state},fn cell,{geometry,s} ->
      micro=cell |> Tuple.to_list() |> Enum.map(&(&1*@micro)) |> List.to_tuple()
      {target,s}=target_at(micro,s)
      material=if target,do: Map.fetch!(s.properties.materials,target.material)
      if target != nil and target.granularity==0 and Map.get(material,"heat_capacity_per_macro",0)>0 do
        {exposed,s}=Enum.reduce(VoxelRegion.Thermal.neighbors(cell),{0,s},fn neighbor,{n,s} ->
          micro=neighbor |> Tuple.to_list() |> Enum.map(&(&1*@micro)) |> List.to_tuple()
          {other,s}=target_at(micro,s)
          {n+if(other==nil,do: 1,else: 0),s}
        end)
        {Map.put(geometry,cell,%{target: target,material: material,exposed_faces: exposed}),s}
      else
        {Map.put(geometry,cell,nil),s}
      end
    end)
    geometry_done=System.monotonic_time(:microsecond)
    {ordered,edges,indexed_edges}=if cells==state.thermal_work.cells and MapSet.size(missing)==0 do
      {state.thermal_work.ordered,state.thermal_work.edges,state.thermal_work.indexed_edges}
    else
      nodes=Map.filter(geometry,fn {_,n}->n != nil end)
      ordered=Map.to_list(nodes)
      edges=VoxelRegion.Thermal.contacts(nodes)
      indices=ordered |> Enum.with_index() |> Map.new(fn {{cell,_},i}->{cell,i} end)
      {ordered,edges,for({a,b}<-edges,do: {Map.fetch!(indices,a),Map.fetch!(indices,b)})}
    end
    nodes_done=System.monotonic_time(:microsecond)
    work=%{state.thermal_work | geometry: geometry,cells: cells,edges: edges,
      seeds: seeds,ordered: ordered,indexed_edges: indexed_edges,
      builds: state.thermal_work.builds+MapSet.size(missing)}
    sources=Map.filter(state.thermal.sources,fn {cell,source} ->
      case Map.get(geometry,cell) do
        nil->false
        n->same_target?(source.target,n.target) and source.remaining_j>0
      end
    end)
    # 拓扑只缓存身份与材料；温度和 HP 每批从唯一权威记录取值。
    {targets,input}=Enum.map(ordered,fn {cell,n}->
      # Damage.key 含完整目标身份；已有记录直接读取，最终提交统一盖 seq/request_id。
      t=case Map.fetch(state.damage,Damage.key(n.target)) do
        {:ok,t}->t
        :error->property_state(state,n.target)
      end
      temperature=Map.get(t,:temperature_kelvin,config["ambient_kelvin"])
      source=Map.get(sources,cell)
      {{cell,t,temperature},{temperature,t.hp,t.max_hp,n.material["heat_capacity_per_macro"]*1.0,
        n.material["thermal_conductivity"]*1.0,n.material["heat_resistance_kelvin"]*1.0,n.exposed_faces*1.0,
        if(source,do: source.power_w*1.0,else: 0.0),if(source,do: source.remaining_j*1.0,else: 0.0),
        MapSet.member?(seeds,cell)}}
    end) |> Enum.unzip()
    # 被删除的旧活动种子没有原生节点；先完成一次原步进，让 World 收缩它的邻域。
    steps=if Enum.all?(seeds,&(Map.get(geometry,&1) != nil)),do: steps,else: 1
    prepared=System.monotonic_time(:microsecond)
    {done,result,supplied,environment}=VoxelRegion.ThermalNative.batch(input,indexed_edges,
      config["ambient_kelvin"]*1.0,config["environment_w_per_m2_k"]*1.0,config["tolerance_kelvin"]*1.0,dt,steps)
    calculated=System.monotonic_time(:microsecond)
    {changes,sources,hot}=Enum.zip_reduce(targets,result,{[],%{},[]},
      fn {cell,t,old_temperature},{temperature,hp,remaining},{changes,left,hot} ->
      left=if remaining>0,do: Map.put(left,cell,%{Map.fetch!(sources,cell) | remaining_j: remaining}),else: left
      hot=if abs(temperature-config["ambient_kelvin"])>config["tolerance_kelvin"],do: [cell|hot],else: hot
      if temperature==old_temperature and hp==t.hp do
        {changes,left,hot}
      else
        t=t |> Map.put(:temperature_kelvin,temperature) |> Map.put(:hp,hp)
        {[{Damage.key(t),t}|changes],left,hot}
      end
    end)
    damage=Map.merge(state.damage,Map.new(changes))
    changed=MapSet.new(changes,&elem(&1,0))
    hot=MapSet.new(hot)
    active=map_size(sources)>0 or MapSet.size(hot)>0
    thermal=%{state.thermal | sources: sources,elapsed_s: Enum.reduce(1..done,state.thermal.elapsed_s,fn _,t->t+dt end),active: active,
      supplied_j: state.thermal.supplied_j+supplied,environment_j: state.thermal.environment_j+environment}
    work=if active,do: %{work | hot: hot},else: %{empty_thermal_work() | builds: work.builds}
    Logger.info("voxel_thermal_kernel steps=#{done} nodes=#{length(input)} edges=#{length(indexed_edges)} prepare_us=#{prepared-started} nif_us=#{calculated-prepared} accept_us=#{System.monotonic_time(:microsecond)-calculated}")
    Logger.info("voxel_thermal_prepare neighborhood_us=#{neighborhood_done-started} geometry_us=#{geometry_done-neighborhood_done} nodes_us=#{nodes_done-geometry_done} input_us=#{prepared-nodes_done}")
    {%{state | damage: damage,thermal: thermal,thermal_work: work},changed,done}
  end

  defp thermal_commit(state,rows) do
    state=%{state | seq: state.seq+1,damage: Map.merge(state.damage,Map.new(rows,&{Damage.key(&1),&1}))}
    txn=%{seq: state.seq,entries: [],coarse: [],property_states: rows,thermal: state.thermal}
    start=System.monotonic_time(:microsecond)
    :ok=append_log(state,txn)
    persisted=System.monotonic_time(:microsecond)
    state=%{state | entries: Map.put(state.entries,state.seq,txn)}
    fanout(state,txn)
    fanout_canonical(state,txn,[],[],state)
    broadcast=System.monotonic_time(:microsecond)
    Logger.info("voxel_thermal_commit seq=#{state.seq} sim_s=#{state.thermal.elapsed_s} states=#{length(rows)} persist_us=#{persisted-start} broadcast_us=#{broadcast-persisted} active=#{state.thermal.active} supplied_j=#{state.thermal.supplied_j} environment_j=#{state.thermal.environment_j}")
    state
  end

  defp component_max_hp(state,owner) do
    for cell<-subtree_cells(state,MapSet.new([owner])),{_,{material,id}}<-Map.fetch!(state.refined,cell),id==owner,reduce: 0.0 do
      hp -> hp+Damage.max_hp(Map.fetch!(state.properties.materials,material),1)
    end
  end

  # Saved micro damage becomes one leaf pool without restoring missing geometry or HP.
  defp migrate_component_damage(state) do
    legacy=state.damage |> Map.values() |> Enum.filter(&(&1.granularity==1)) |> Enum.group_by(& &1.owner)
    Enum.reduce(legacy,state,fn {owner,rows},s ->
      hp=component_max_hp(s,owner)
      lost=Enum.reduce(rows,0.0,fn t,sum -> sum+t.max_hp-t.hp end)
      target=%{hd(rows) | granularity: 2,max_hp: hp,hp: hp-lost,seq: s.seq,request_id: 0}
      damage=Map.drop(s.damage,Enum.map(rows,&Damage.key/1)) |> Map.put(Damage.key(target),target)
      %{s | damage: damage}
    end)
  end

  defp same_target?(a,b), do: Enum.all?([:micro,:incarnation,:owner,:material],&(Map.fetch!(a,&1)==Map.fetch!(b,&1)))

  defp attack_target(before,state,actor,request,target,tool) do
    # 同一会话只比较 Gate 入口时钟；World/Player 的处理抖动不改变输入相位。
    now = actor.received_us
    previous = Map.get(state.tool_sessions,actor.player)
    interval = ceil(tool["interval_seconds"]*1_000_000)
    case Damage.admit_attack(previous,request.client_intent_seq,now,interval,actor.tick_us) do
      {:error,reason} ->
        Logger.info("voxel_tool_rate request_id=#{request.request_id} client_seq=#{request.client_intent_seq} result=#{reason} clock_node=#{actor.clock_node} received_us=#{now} tat_us=#{previous.next_us} tick_us=#{actor.tick_us}")
        {:reply,{:error,reason},state}
      {:ok,session} ->
        unless previous != nil,do: Process.monitor(actor.player)
        Logger.info("voxel_tool_rate request_id=#{request.request_id} client_seq=#{request.client_intent_seq} result=admitted clock_node=#{actor.clock_node} received_us=#{now} next_us=#{session.next_us} borrowed_us=#{max(0,session.next_us-interval-now)} tick_us=#{actor.tick_us}")
        state = %{state | tool_sessions: Map.put(state.tool_sessions,actor.player,session)}
        material = Map.fetch!(state.properties.materials,target.material)
        amount = Damage.amount(material,tool,target.granularity)
        target = %{target | hp: max(0.0,target.hp-amount),seq: state.seq+1}
        cond do
          target.granularity==2 and not leaf_component?(state,target.owner) -> {:reply,{:error,:not_a_leaf_component},before}
          amount == 0.0 -> {:reply,{:error,:ineffective_tool},state}
          request.action == 2 -> dismantle_target(before,state,actor,target)
          target.hp == 0.0 and target.granularity==2 -> dismantle_target(before,state,actor,target)
          target.hp == 0.0 ->
          {state,settlement} = if target.material in state.production_materials do
            settle_material(state,actor.cid,target.material,@micro*@micro*@micro)
          else
            {state,%{}}
          end
          destroy_target(before,%{state | damage: Map.put(state.damage,Damage.key(target),target)},target,settlement)
          true ->
          state = %{state | seq: state.seq+1,damage: Map.put(state.damage,Damage.key(target),target)}
          txn = %{seq: state.seq,entries: [],coarse: [],property_states: [target],epochs: %{}}
          case append_log(state,txn) do
            :ok ->
              state = %{state | entries: Map.put(state.entries,state.seq,txn)}
              fanout(state,txn)
              fanout_canonical(state,txn,[],[],state)
              Logger.info("voxel_damage seq=#{state.seq} target=#{inspect(target.micro)} material=#{target.material} hp=#{target.hp} max_hp=#{target.max_hp} geometry=false")
              {:reply,{:ok,state.seq},state}
            {:error,reason} -> {:reply,{:error,reason},before}
          end
        end
    end
  end

  defp leaf_component?(state,owner),do: not Enum.any?(state.instances,fn {_,i}->Map.get(i,:parent_id,{0,0})==owner end)

  defp dismantle_target(before,_state,_actor,%{granularity: 0}) do
    {:reply,{:error,:not_a_component},before}
  end
  defp dismantle_target(before,state,actor,target) do
    # 拆卸只认权威射线命中的叶子 occurrence，不采用客户端选中的父级。
    if not leaf_component?(state,target.owner) do
      {:reply,{:error,:not_a_leaf_component},before}
    else
      ids=MapSet.new([target.owner])
      cells=subtree_cells(state,ids)
      amounts=for cell<-cells,{_,{material,owner}}<-Map.fetch!(state.refined,cell),
        owner==target.owner and material in state.production_materials,reduce: %{} do
          counts -> Map.update(counts,material,1,&(&1+1))
        end
      {state,balances}=Enum.reduce(amounts,{state,%{}},fn {material,units},{s,balances}->
        {s,settlement}=settle_material(s,actor.cid,material,units)
        {s,Map.merge(balances,settlement.material_balances)}
      end)
      settlement=%{material_balances: balances}
      # Include a tombstone even when a small leaf dies on its first hit.
      damaged=%{before | damage: Map.put(before.damage,Damage.key(target),target)}
      case prefab_reply(damaged,clear_subtree(state,ids,cells),cells,settlement) do
        {:reply,{:error,reason},_} -> {:reply,{:error,reason},before}
        result -> result
      end
    end
  end

  defp destroy_target(before,state,%{granularity: 0}=target,settlement) do
    case apply_batch(state,[{Damage.macro(target),0}],false,settlement) do
      {:ok,next} -> {:reply,{:ok,next.seq},next}
      {:error,reason} -> {:reply,{:error,reason},before}
    end
  end

  # Macro epochs track replacement even back to the same material. Refined identity
  # is its exact micro + occurrence birth; neighbouring damage survives local edits.
  defp damage_geometry(before,state,cells,macro_edit) do
    cells = MapSet.new(cells)
    epochs = if macro_edit,do: Map.new(cells,&{&1,state.seq}),else: %{}
    removed = before.damage |> Map.values() |> Enum.filter(fn t ->
      if MapSet.member?(cells,Damage.macro(t)) do
        {current,_}=target_at(t.micro,%{state | epochs: Map.merge(state.epochs,epochs)})
        current == nil or Damage.key(current) != Damage.key(t)
      else
        false
      end
    end)
    damage = Map.drop(state.damage,Enum.map(removed,&Damage.key/1))
    states = Enum.map(removed,&%{&1 | hp: 0.0,flags: 1,seq: state.seq,request_id: 0})
    thermal=if state.thermal,do: %{state.thermal | active: true}
    metadata=%{property_states: states,epochs: epochs}
    metadata=if thermal,do: Map.put(metadata,:thermal,thermal),else: metadata
    affected=cells |> Enum.flat_map(&[&1|VoxelRegion.Thermal.neighbors(&1)])
    work=%{state.thermal_work | geometry: Map.drop(state.thermal_work.geometry,affected)}
    {%{state | damage: damage,epochs: Map.merge(state.epochs,epochs),thermal: thermal,thermal_work: work},metadata}
  end

  defp replay_damage(state,txn) do
    damage = Enum.reduce(Map.get(txn,:property_states,[]),state.damage,fn t,acc ->
      if t.flags == 1,do: Map.delete(acc,Damage.key(t)),else: Map.put(acc,Damage.key(t),t)
    end)
    %{state | damage: damage,epochs: Map.merge(state.epochs,Map.get(txn,:epochs,%{})),
      thermal: Map.get(txn,:thermal,state.thermal),
      material_balances: Map.merge(state.material_balances,Map.get(txn,:material_balances,%{}))}
  end

  defp balance_state(state,cid,material) do
    %{seq: state.seq,material: material,
      balance: Map.get(state.material_balances,{cid,material},0),cost: @micro*@micro*@micro}
  end

  defp settle_material(state,cid,material,delta) do
    key = {cid,material}
    balance = Map.get(state.material_balances,key,0)+delta
    {%{state | material_balances: Map.put(state.material_balances,key,balance)},%{material_balances: %{key=>balance}}}
  end

  defp build_target(before,actor,request) do
    # Scene 移交会换 Player 与 epoch，同一已鉴权连接的请求序号仍继续递增。
    previous = Map.get(before.build_sessions,actor.gate)
    cond do
      previous != nil and previous.request == request -> {:reply,previous.result,before}
      previous != nil and request.client_intent_seq <= previous.request.client_intent_seq ->
        {:reply,{:error,:replayed_build},before}
      true ->
        result = with :ok <- if(request.material in before.production_materials,do: :ok,else: {:error,:unknown_resource}),
          {:ok,tool} <- Map.fetch(before.properties.tools,request.tool_id),
          :ok <- build_reach(actor.eye,request.coord,tool["range_macro"]),
          :ok <- if(balance_state(before,actor.cid,request.material).balance >= @micro*@micro*@micro,do: :ok,else: {:error,:insufficient_material}),
          false <- Map.has_key?(before.refined,request.coord),
          {:ok,{0,_},state} <- cell_value(before,0,request.coord) do
          {state,settlement} = settle_material(state,actor.cid,request.material,-@micro*@micro*@micro)
          apply_batch(state,[{request.coord,request.material}],false,settlement)
        else
          :error -> {:error,:invalid_tool}
          true -> {:error,:occupied}
          {:ok,_,_} -> {:error,:occupied}
          {:error,reason} -> {:error,reason}
        end
        {reply,state} = case result do
          {:ok,state} -> {{:ok,state.seq},state}
          {:error,_}=error -> {error,before}
        end
        unless previous != nil,do: Process.monitor(actor.gate)
        state = %{state | build_sessions: Map.put(state.build_sessions,actor.gate,%{request: request,result: reply})}
        {:reply,reply,state}
    end
  end

  defp build_reach(eye,coord,range) do
    squared = Enum.zip(Tuple.to_list(eye),Tuple.to_list(coord))
      |> Enum.reduce(0.0,fn {a,b},sum -> sum+(a-b-0.5)*(a-b-0.5) end)
    if squared <= range*range,do: :ok,else: {:error,:out_of_reach}
  end

  defp validate_damage_catalog(state) do
    if map_size(state.damage)>0 do
      true = state.properties != nil and Enum.all?(state.damage,fn {_,t}->t.digest==state.properties.digest end)
    end
  end

  defp current_actor(actor) do
    try do
      with {:ok,current} <- actor.refresh.(actor.player,actor.identity) do
        {:ok,Map.merge(current,Map.take(actor,[:received_us,:clock_node]))}
      end
    catch
      :exit,_ -> {:error,:invalid_session}
    end
  end

end
