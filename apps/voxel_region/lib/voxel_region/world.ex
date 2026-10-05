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

  alias VoxelRegion.{Attachments, ThermalWork}
  require Logger
  import Bitwise
  alias VoxelRegion.{OverlayLog, Damage}
  alias VoxelRegion.{CollisionSource, FileStore, Prefab}
  alias VoxelRegion.{Phase, Protection}
  alias MmoContracts.Voxel.{Codec, Payload}
  alias VoxelRegion.World.Thermal
  import VoxelRegion.World.Canonical
  import VoxelRegion.World.{Payloads, Observation, Log, Edits, Prefabs, Casting, Tools, Production, Liquids, AttachmentOps, Claims, Catalogs, HeatCommit}
  use GenServer

  @micro VoxelRegion.Spatial.micro_resolution()
  @max_level 5
  @default_cache_bytes 512 * 1024 * 1024
  # 魔法增量 1：登录下发与无报价时的报价字段。
  @no_quote %{total_j: 0.0, structure: 0.0}
  @name __MODULE__

  # ---- API

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))

  def content_version(server \\ @name), do: GenServer.call(server, :content_version)
  def seq(server \\ @name), do: GenServer.call(server, :seq)
  def liquid_activity(server), do: GenServer.call(server, :liquid_activity)

  @doc "唯一 canonical authority 的 PID，供区域视图共享世界身份。"
  def authority_ref(server \\ @name) do
    # 进程身份来自 OTP 注册表，不读取世界真值；不能排在碰撞快照等重计算后面。
    case GenServer.whereis(server) do
      {name, remote} -> :erpc.call(remote, GenServer, :whereis, [name])
      pid -> pid
    end
  end

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

      error ->
        error
    end
  end

  defp valid_request_item?(%{level: level, region: region}) when level in 0..@max_level do
    step = 1 <<< level

    valid_region?(region, step)
  end

  defp valid_request_item?(_), do: false

  # 冷 miss 的 baseline 在调用方进程并发物化到磁盘缓存；结果不看——World 读时缺失就是 missing、损坏就是错误，语义不变。
  defp prepare(server, keys) do
    # 多人加入的快照共用此 mailbox；前置查询沿用后续快照的等待时限，
    # 避免 20 人实验中正常排队被默认 5 秒超时截断。
    {source, source_state, missing} = GenServer.call(server, {:prepare, Enum.uniq(keys)}, 300_000)

    Logger.info(
      "voxel_source_return caller=#{inspect(self())} at_us=#{System.system_time(:microsecond)} missing=#{length(missing)}"
    )

    ensure_source(source, source_state, missing)

    if missing != [],
      do: GenServer.call(server, {:adopt_liquid, Enum.uniq(for {0, region} <- keys, do: region)}, 300_000),
      else: :ok
  end

  defp ensure_source(source, source_state, missing) do
    missing
    |> Task.async_stream(fn {level, region} -> source.ensure(source_state, level, region) end,
      max_concurrency: Application.get_env(:voxel_region, :generation_concurrency, 8),
      ordered: false,
      timeout: :infinity
    )
    |> Stream.run()
  end

  # Resident intents prepare and commit in one owner turn; cold sources are ensured outside it.
  defp prepared_intent(server, message) do
    case GenServer.call(server, {:prepare_intent, message}, 300_000) do
      {:prepare, source, source_state, keys, missing, undecoded} ->
        ensure_source(source, source_state, missing)
        GenServer.call(server, {:prepared_intent, keys, message, decode_sources(source, source_state, undecoded)}, 300_000)
      result -> result
    end
  end

  # 来源载荷按内容版本不可变：L1+ 归约要读的冷区域在调用方解码，World 只接纳结果；读不到的仍由 World 按原语义处理。
  defp decode_sources(source, source_state, keys) do
    keys
    |> Task.async_stream(fn {level, region} = key ->
      with {:ok, bytes, _header} <- source.read(source_state, level, region),
           {:ok, payload} <- Payload.decode(bytes),
           do: {:decoded, key, payload}
    end, ordered: false, timeout: :infinity)
    |> Enum.flat_map(fn
      {:ok, {:decoded, key, payload}} -> [{key, payload}]
      _ -> []
    end)
  end

  @doc "一次 canonical 编辑：`{:ok, seq}`（seq = 提交的日志序号；no-op 时是当前 seq）/ `{:error, reason}`。"
  def apply_edit(server \\ @name, {_, _, _} = coord, material)
      when is_integer(material) and material >= 0 and material <= 255 do
    if valid_edit_coord?(coord) do
      prepare(server, edit_keys([coord]))
      GenServer.call(server, {:apply_edit, coord, material}, 60_000)
    else
      {:error, :invalid_coordinate}
    end
  end

  def publish_properties(server, path),
    do: GenServer.call(server, {:publish_properties, Damage.load(path)})

  @doc "全局系统作者入口：从明确的旧目录升级可玩参数，保留实例存量并记录热参考重标。"
  def publish_parameters(server, path, expected_digest),
    do: GenServer.call(server, {:publish_parameters, Damage.load(path), expected_digest}, 300_000)

  @doc "只测试作者入口：从资产导出的实验参数启动有限供能热源；不开放给 Gate 玩家意图。"
  def thermal_experiment(server, path),
    do: GenServer.call(server, {:thermal_experiment, Jason.decode!(File.read!(path))}, 300_000)

  @doc "Test-only: install an MCP-authored finite basin once, before player actions; never a refill source."
  def liquid_experiment(server, path) do
    data = Jason.decode!(File.read!(path))
    edits = Enum.map(data["deposits"], fn row -> {List.to_tuple(row["macro"]), row["material"]} end)
    prepare(server, edit_keys(Enum.map(edits, &elem(&1,0))))
    GenServer.call(server, {:liquid_experiment, edits}, 300_000)
  end

  @doc """
  全局系统作者入口：一笔事务写入受保护区域 `[%{holder, min: {x, z}, max: {x, z}}]`（闭区间宏格，y 不限），
  holder 为 `:reserved` 或 `{:character, cid}`；与既有区域或彼此重叠时整体拒绝。不经 Gate 暴露。
  """
  def author_regions(server, regions), do: GenServer.call(server, {:author_regions, regions}, 300_000)

  @doc "角色确认余额；单位为一个 canonical 微格体积。"
  def material_balances(server, cid),
    do: GenServer.call(server, {:material_balances, cid}, 300_000)

  @doc "全局系统功能：服务端授权供给材料，同角色/来源只记账一次；不经 Gate 暴露。"
  def material_supply(server, cid, supply_id, quantities),
    do: GenServer.call(server, {:material_supply, cid, supply_id, quantities}, 300_000)

  @doc "全局系统功能：同一事务位置下的指定角色余额与格占用投影；detail=:micro 增加细化格精确坐标，不读取热/液体模拟状态。"
  def material_snapshot(server, characters, cells, detail \\ :summary) when detail in [:summary, :micro] do
    prepare(server, Enum.uniq(Enum.map(cells, &{0, region_of(&1)})))
    message = if detail == :summary, do: {:material_snapshot, characters, cells},
      else: {:material_snapshot, characters, cells, detail}
    GenServer.call(server, message, 300_000)
  end

  @doc """
  全局系统功能：同一提交点的角色材料/相态库存、指定范围属性和有限液体数量。
  box 沿既有 canonical 的 region 半开范围；不生成区域、不初始化模拟、不返回配置或缓存。
  thermal_accounting 是整个世界累计结算账；做守恒比较的调用方必须独占该世界。
  """
  def simulation_snapshot(server, characters, box),
    do: GenServer.call(server, {:simulation_snapshot, characters, box})

  @doc "普通角色查询或付费建造，复用世界事务。"
  def production_intent(server, actor, request) do
    if request.action == 4 or valid_edit_coord?(request.coord),
      do: prepared_intent(server, {:production_intent, actor, request}),
      else: {:error, :invalid_coordinate}
  end

  @doc "全局系统功能：附件经已鉴权角色进入原子世界事务。"
  def attachment_intent(server, actor, request) do
    slots = Attachments.footprint(request.kind, request.axis, request.anchor, request.size)
    cells = Attachments.macros(slots)

    if Enum.all?(cells, &valid_edit_coord?/1) do
      case GenServer.call(server, {:tool_range, request.tool_id}, 300_000) do
        {:error, _} = error ->
          error

        range ->
          prepare(server, tool_regions(actor, range) ++ edit_keys(cells))
          GenServer.call(server, {:attachment_intent, actor, request}, 300_000)
      end
    else
      {:error, :invalid_coordinate}
    end
  end

  def tool_intent(server, actor, request) do
    started = System.monotonic_time(:microsecond)
    result = prepared_intent(server, {:tool_intent, actor, request})
    Logger.info("voxel_tool_call request_id=#{request.request_id} node=#{node()} elapsed_us=#{System.monotonic_time(:microsecond) - started}")
    result
  end

  @doc "Global system：读取现有作者工具定义，人物作用不借用体素 HP 参数。"
  def tool_definition(server, id), do: GenServer.call(server, {:tool_definition, id})

  @doc "异步停止旧 Player 的身体接触；同一 World 发出的既有 body_heat 先于 body_detached 到达。"
  def body_detach(server, cid, pid, ref), do: send(server, {:body_detach, cid, pid, ref})

  @doc "人物工具作用的世界授权：当前 canonical 遮挡和既有工具频率；身体提交由目标 owner 完成。"
  def body_tool(server, actor, request, distance) do
    prepare(server, tool_regions(actor, distance))
    GenServer.call(server, {:body_tool, actor, request, distance}, 300_000)
  end

  @doc """
  全局系统功能（魔法增量 1）：施法意图。action 0 = 报价（只算成本，不改世界）；1 = 施放。
  返回 `{:ok, %{seq, outcome, caster}}`（outcome：nil 正常 / `:misfire_energy` / `:misfire_coherence`，
  走火也是一笔已提交事务）或 `{:error, reason}`（不扣能量、不改世界）。
  施放（action 1）通过立即校验后先进入前摇（Voxim Docs/Magic.md §13.6），本调用在前摇结束、结算完成后才返回；
  前摇中同一施法者再施放立即返回 `{:error, :cast_too_soon}`。
  """
  def spell_intent(server, actor, request) do
    # 冷区域生成留在调用方进程；施法者射线在 owner 内对当时世界重新求交。
    with 1 <- request.action, range when is_number(range) <- GenServer.call(server, :magic_range, 300_000),
      do: prepare(server, tool_regions(actor, range))

    GenServer.call(server, {:spell_intent, actor, request}, 300_000)
  end

  @doc "全局系统功能（魔法增量 1）：施法者状态（登录时下发一次）；世界未配置魔法目录时 `{:error, :magic_unavailable}`。"
  def caster_state(server, cid), do: GenServer.call(server, {:caster_state, cid}, 300_000)

  @doc "全局系统功能：由 World 有序出口发送登录施法者状态，和报价、结算及身体变化共用同一发送者。"
  def send_caster_state(server, cid, request_id, recipient),
    do: GenServer.call(server, {:send_caster_state, cid, request_id, recipient}, 300_000)

  @doc "B6 玩家燃烧意图，复用 DamageInput 的目标、会话、射程与速率校验。"
  def combustion_intent(server, actor, request), do: tool_intent(server, actor, request)

  def place_prefab(server \\ @name, definition_id, anchor, orientation) do
    with {:ok, cells} <- prefab_cells(server, definition_id, anchor, orientation) do
      prepare(server, prefab_keys(cells))
      GenServer.call(server, {:place_prefab, definition_id, anchor, orientation, cells}, 300_000)
    end
  end

  @doc "全局系统功能：玩家 Prefab 建造、替换、拆解复用 B2 余额与请求身份；旧管理入口仅供夹具。"
  def prefab_intent(server, actor, kind, request) do
    cells =
      case kind do
        :voxel_prefab_place_v1 ->
          with {:ok, micro} <-
                 prefab_cells(server, request.definition_id, request.anchor, request.orientation),
               do: {:ok, footprint_macros(micro)}

        :voxel_prefab_remove_v1 ->
          instance_cells(server, request.instance_id)

        :voxel_prefab_replace_v1 ->
          replacement_cells(server, request.instance_id, request.definition_id)
      end

    if match?({:ok, _}, cells),
      do: prepare(server, region_keys(Enum.map(elem(cells, 1), &{0, &1})))

    GenServer.call(server, {:prefab_intent, actor, kind, request}, 300_000)
  end

  def remove_prefab(server \\ @name, instance_id),
    do: GenServer.call(server, {:remove_prefab, instance_id}, 300_000)

  def publish_prefabs(server \\ @name, path) do
    catalog = Prefab.load(path)
    GenServer.call(server, {:publish_prefabs, catalog}, 300_000)
  end

  # 全局系统功能：运行时内容发布与工作台只读目录；不产生体素事务。name 为玩家输入的名称，NPC 发布为空名。
  def publish_prefab(server, actor, bytes, name \\ ""),
    do: GenServer.call(server, {:publish_prefab, actor, bytes, name}, 300_000)

  def prefab_catalog(server \\ @name), do: GenServer.call(server, :prefab_catalog)

  @doc "全局系统功能（D3-2）：运行时发布的 {首个发布者 cid, 首次名称, 定义字节}，按发布序；不含作者目录。"
  def published_prefabs(server \\ @name), do: GenServer.call(server, :published_prefabs)
  def material_catalog(server \\ @name), do: GenServer.call(server, :material_catalog)

  def replace_prefab(server \\ @name, instance_id, definition_id) do
    started = System.monotonic_time(:microsecond)

    with {:ok, cells} <- replacement_cells(server, instance_id, definition_id) do
      range_done = System.monotonic_time(:microsecond)
      prepare(server, region_keys(Enum.map(cells, &{0, &1})))
      prepare_done = System.monotonic_time(:microsecond)
      result = GenServer.call(server, {:replace_prefab, instance_id, definition_id}, 300_000)

      Logger.info(
        "voxel_prefab_replace range_us=#{range_done - started} prepare_us=#{prepare_done - range_done} " <>
          "commit_us=#{System.monotonic_time(:microsecond) - prepare_done}"
      )

      result
    end
  end

  def replacement_cells(server, instance_id, definition_id),
    do: GenServer.call(server, {:replacement_cells, instance_id, definition_id}, 300_000)

  def prefab_cells(server, id, anchor, orientation),
    do: GenServer.call(server, {:prefab_cells, id, anchor, orientation})

  def instance_cells(server, id), do: GenServer.call(server, {:instance_cells, id})

  defp prefab_keys(cells) do
    cells |> footprint_macros() |> Enum.map(&{0, &1}) |> region_keys() |> Enum.uniq()
  end

  def subscribe(server \\ @name, pid, have_seq, {{_, _, _}, {_, _, _}} = box, coarse_min_level) do
    GenServer.call(server, {:subscribe, pid, have_seq, box, coarse_min_level})
  end

  def entries_after(server \\ @name, seq), do: GenServer.call(server, {:entries_after, seq})

  @doc "Prepare canonical L0 source, then atomically send its snapshot marker and subscribe to all subsequent transactions."
  def canonical_snapshot_and_subscribe(
        world_ref,
        l0_box,
        subscriber_pid,
        request_ref,
        include_chunks \\ true
      ) do
    started = System.monotonic_time(:microsecond)

    Logger.info(
      "voxel_window_stage stage=prepare_start request=#{inspect(request_ref)} pid=#{inspect(self())} at_us=#{System.system_time(:microsecond)}"
    )

    prepare(world_ref, Enum.map(CollisionSource.regions(l0_box), &{0, &1}))

    Logger.info(
      "voxel_window_stage stage=prepare_done request=#{inspect(request_ref)} pid=#{inspect(self())} at_us=#{System.system_time(:microsecond)} elapsed_us=#{System.monotonic_time(:microsecond) - started}"
    )

    GenServer.call(
      world_ref,
      {:canonical_snapshot, l0_box, subscriber_pid, request_ref, include_chunks},
      300_000
    )
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

        cache_limit =
          Keyword.get(
            opts,
            :payload_cache_bytes,
            Application.get_env(:voxel_region, :payload_cache_bytes, @default_cache_bytes)
          )

        # 允许常驻载荷达到既有缓存预算，避免过小的二进制阈值反复触发全堆 GC；不预分配内存。
        {:min_bin_vheap_size, min_bin_words} = Process.info(self(), :min_bin_vheap_size)

        Process.flag(
          :min_bin_vheap_size,
          max(min_bin_words, div(cache_limit, :erlang.system_info(:wordsize)))
        )

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
          attachments: %{},
          attachment_serial: 0,
          attachment_owners: %{},
          # Global system: finite quantity is canonical state, never reconstructed from rendering.
          liquid_units: %{},
          liquid_active: MapSet.new(),
          liquid_falls: %{},
          liquid_timer: nil,
          # Test-only first-slice domain; the demo supplies its closed experimental bounds.
          liquid_bounds: Keyword.get(opts, :liquid_bounds, Application.get_env(:voxel_region, :liquid_bounds)),
          damage: %{},
          epochs: %{},
          tool_sessions: %{},
          thermal: load_thermal_environment(opts),
          thermal_work: ThermalWork.new(),
          # 下一次热提交的墙钟到期时刻（毫秒，单调时钟）；nil 表示未排程（休眠，等事务或身体接触唤醒）。
          thermal_due: nil,
          # 待到期节拍的定时器；nil 表示没有（休眠，或进行中的提交完成时再排）。
          thermal_timer: nil,
          # 最近一次零功率热提交之后的事务号：此后没有新事务时，电路种子本身不再推进热提交。
          thermal_quiet_seq: nil,
          # 进行中的分步热提交；nil 表示两次提交之间。
          thermal_run: nil,
          material_balances: %{},
          # 魔法增量 1：施法者能量（cid => J）是权威真值，随日志／检查点持久化；不自动回复。
          caster_energy: %{},
          # Scene 每秒报来的施法者相干度系数（cid => {identity, factor}）；identity 只界定派生状态推送的去重范围。
          # 相干度 = 目录相干度 × 它（`coherence/2`）；派生、不持久化，未报过按 1.0。
          caster_coherence: %{},
          # 身体闭环 H2：死亡掉落概率（用户 2026-09-27 定：先留接口、不掉任何东西，默认 0；`death_drop/3`）。
          death_drop_probability: Keyword.get(opts, :death_drop_probability, 0.0),
          # 施法间隔会话（按 Player 进程，断开即忘，不持久化），与工具会话同一 GCRA。
          spell_sessions: %{},
          # 施放前摇（Voxim Docs/Magic.md §13.6）：待施放（cid => 广播记录、调用方与开始时捕获的施法者、
          # 意图、程序、报价），每施法者至多一条；不持久化，冷重启即丢（未扣能）。
          pending_casts: %{},
          # 魔法增量 4：Scene 每秒报来的身体接触（cid => 几何、皮肤温度与本次接触边），派生、不持久化；
          # 过期（2.5 s 未续报）即丢。身体真值在 Scene（SceneServer.Body）。
          bodies: %{},
          magic: load_magic(opts),
          material_supplies: %{},
          # 合成账（R8-04）：材料 => 合成造成的累计净单位变化；随日志／检查点持久化。
          craft_ledger: %{},
          # 食物账（身体闭环 H1）：材料 => 被吃掉的累计单位（物质离开世界进入身体）；随日志／检查点持久化。
          food_ledger: %{},
          food_receipts: %{},
          # 溯源：花材料放下的 macro 格 => 放置者 cid。作者入口写的格、天然地形、液体流动改的格都无主；格一被别的编辑改动就清掉。
          placed_by: %{},
          macro_owners: %{},
          # 受保护区域（全局系统）：唯一真值，随日志/检查点持久化；物理边界与意图许可都只读它。
          protection: Protection.new(),
          # 认领工具的待定第一角（玩家适配）：按 Player 进程保存，断开即忘，不持久化。
          claim_corners: %{},
          phase_inventory: %{},
          material_units_per_micro: 1,
          build_sessions: %{},
          production_materials:
            Keyword.get(
              opts,
              :production_materials,
              Application.get_env(:voxel_region, :production_materials, [])
            ),
          properties: load_properties(opts),
          structure: %{},
          instances: %{},
          prefab_dir: Path.join(world_dir, "prefabs"),
          published: Prefab.load_published(Path.join(world_dir, "prefabs")),
          prefabs:
            Prefab.load(
              Keyword.get(
                opts,
                :prefab_catalog_path,
                Application.get_env(:voxel_region, :prefab_catalog_path)
              ),
              Path.join(world_dir, "prefabs")
            ),
          overlay_regions: %{},
          seq: 0,
          entries: %{},
          checkpoint_timer: nil,
          checkpoints: 0,
          entry_regions: %{},
          subs: %{},
          canonical_subs: %{},
          canonical_feeds: %{},
          replica_subs: %{},
          log: {log, log.open(world_dir, cv)}
        }

        state = replay_log(state) |> environment_tolerance(state.thermal)
        # 施法的热只经有限热源进世界：有魔法目录的世界必须有热环境。
        true = state.magic == nil or state.thermal != nil

        state =
          if state.seq == 0,
            do: %{state | material_units_per_micro: Damage.material_units(state.properties)},
            else: state

        # 已有余额必须显式迁移，不能把旧整数静默解释成新量子。
        true = state.material_units_per_micro == Damage.material_units(state.properties)
        validate_damage_catalog(state)
        state = migrate_component_damage(state)
        {state, _, _} = refresh_structure(state, Map.keys(state.refined))
        state = if map_size(state.structure) > 0, do: compact_log(state), else: state
        state = Thermal.rebuild_work(state)

        Logger.info(
          "voxel_region world #{FileStore.hex(cv)} ready, seq=#{state.seq}, root=#{world_dir}"
        )

        state = schedule_liquid(state)
        state = Thermal.wake(state)
        {:ok, state}

      {:error, :no_world} ->
        {:stop, {:no_world, Keyword.fetch!(opts, :root)}}
    end
  end

  @impl true
  # 热提交进行中，原生热域可能有尚未写回的节点：调用先写回属性记录（唯一真值），读到的与逐步写回时相同。
  # 豁免的消息整条处理链都不读写属性记录（区域载荷、工具目录、版本号），不必写回；身体接触只读脚格温度，
  # 由 Thermal.body_contacts 直接读原生侧当前值。
  @unflushed [:serve_item, :tool_definition, :content_version, :seq, :body_coherence, :body_contact]

  def handle_call(message, from, %{thermal_work: %{domain: %{pending: true}}} = state)
      when not (is_tuple(message) and elem(message, 0) in @unflushed) and message not in @unflushed,
      do: handle_call(message, from, Thermal.flush(state, if(is_tuple(message), do: elem(message, 0), else: message)))

  def handle_call(:content_version, _from, state), do: {:reply, state.cv, state}
  def handle_call(:seq, _from, state), do: {:reply, state.seq, state}
  def handle_call(:liquid_activity, _from, state), do:
    {:reply, %{active_cells: MapSet.size(state.liquid_active), scheduled: state.liquid_timer != nil}, state}
  def handle_call(:source, _from, state), do: {:reply, {state.source, state.source_state}, state}

  def handle_call({:prepare, keys}, {caller, _}, state) do
    started = System.monotonic_time(:microsecond)
    at = System.system_time(:microsecond)
    # 已物化载荷可直接供 payload_bytes 读取；预备不再重复触碰来源磁盘。
    # decoded() 的来源需求仍独立判断，载荷缓存不升格为世界真值。
    missing =
      Enum.filter(keys, &(needs_source?(state, &1) and not Map.has_key?(state.payloads, &1)))

    Logger.info(
      "voxel_source_prepare caller=#{inspect(caller)} at_us=#{at} elapsed_us=#{System.monotonic_time(:microsecond) - started} keys=#{length(keys)} missing=#{length(missing)}"
    )

    # 已驻留时本次 owner 调用即可完成接纳，避免排到下一轮热提交之后。
    state = if missing == [],
      do: adopt_liquid_regions(state, Enum.uniq(for {0, region} <- keys, do: region)), else: state
    {:reply, {state.source, state.source_state, missing}, state}
  end

  def handle_call({:adopt_liquid, regions}, _, state) do
    {:reply, :ok, adopt_liquid_regions(state, regions)}
  end

  def handle_call({:prepare_intent, message}, from, state) do
    case intent_keys(state, message) do
      {:ok, keys} ->
        keys = Enum.uniq(keys)
        missing = Enum.filter(keys, &(needs_source?(state, &1) and not Map.has_key?(state.payloads, &1)))
        # 编辑链上的 L1+ 区域：载荷可能已缓存（供客户端），但归约读的是解码后的来源。
        undecoded = for {level, _} = key <- keys, level > 0, needs_source?(state, key), do: key
        if missing == [] and undecoded == [], do: handle_call({:prepared_intent, keys, message, []}, from, state),
          else: {:reply, {:prepare, state.source, state.source_state, keys, missing, undecoded}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:prepared_intent, keys, message, decoded}, from, state) do
    decoded = for {key, payload} <- decoded, needs_source?(state, key), into: state.decoded, do: {key, payload}
    state = adopt_liquid_regions(%{state | decoded: decoded}, Enum.uniq(for {0, region} <- keys, do: region))
    handle_call(message, from, state)
  end

  def handle_call({:publish_properties, catalog}, _, state) do
    compatible =
      Damage.material_units(catalog) == state.material_units_per_micro and
        (map_size(state.attachments) == 0 or
           Map.get(state.properties, :attachments) == Map.get(catalog, :attachments)) and
        Enum.all?(state.phase_inventory,fn {{cid,material},_}->
          fields = ~w(phase_peer_material_id phase_transition_kelvin latent_heat_per_macro_j heat_capacity_per_macro max_hp_per_macro)
          Map.get(state.material_balances,{cid,material},0)==0 or
            Map.take(state.properties.materials[material],fields)==Map.take(catalog.materials[material],fields)
        end) and
        Enum.all?(state.damage, fn {_, t} ->
          old = Map.fetch!(state.properties.materials, t.material)
          new = Map.fetch!(catalog.materials, t.material)

          fields =
            if Map.has_key?(t, :temperature_kelvin),
              do: [],
              else: ~w(heat_capacity_per_macro thermal_conductivity heat_resistance_kelvin)

          # B6 adds combustion material properties. A persisted B5 row has no
          # combustion state, so these fields are an additive catalog upgrade;
          # once a row carries fuel state, changing its combustion material
          # semantics must still be rejected like existing thermal properties.
          fields =
            fields ++
              Enum.filter(
                ~w(ignition_kelvin fuel_energy_per_macro_j burn_power_per_macro_w),
                fn key ->
                  not Map.has_key?(old, key) and not Map.has_key?(t, :remaining_fuel_j)
                end
              )

          fields = fields ++ Enum.filter(~w(phase_peer_material_id phase_transition_kelvin latent_heat_per_macro_j),
            &(not Map.has_key?(old,&1) and not Map.has_key?(t,:phase_energy_j)))
          Map.drop(old, ["electrical_conductivity" | fields]) ==
            Map.drop(new, ["electrical_conductivity" | fields]) and
            (not Map.has_key?(old, "electrical_conductivity") or
               old["electrical_conductivity"] == new["electrical_conductivity"])
        end)

    if compatible do
      publish_property_catalog(state, catalog, state.thermal, state.damage,
        %{attachments: state.attachments, slots: [], tombstones: []})
    else
      {:reply, {:error, :property_version_in_use}, state}
    end
  end

  def handle_call({:publish_parameters, catalog, expected_digest}, _, state) do
    cond do
      state.properties.digest != expected_digest ->
        {:reply, {:error, :property_version_mismatch}, state}

      not VoxelRegion.ParameterEvolution.compatible?(state.properties, catalog) ->
        {:reply, {:error, :property_version_in_use}, state}

      true ->
        thermal = VoxelRegion.ParameterEvolution.thermal_reference(state.thermal, state.damage, state.properties, catalog,
          &finite_volume(state, &1))
        {damage, thermal} = VoxelRegion.ParameterEvolution.combustion(state.damage, thermal, state.properties, catalog)
        # R8-04 增量 2：目录撤下的设备工具在同一笔发布事务里迁移成材料面（D8）。
        migration = VoxelRegion.ParameterEvolution.retire_devices(damage, state.attachments, thermal, state.properties, catalog)
        publish_property_catalog(state, catalog, migration.thermal, migration.damage, migration)
    end
  end

  # D3：在原热账上累加。已有热账（环境资产、迁移、燃烧、电路、拟态……）逐键保留，时钟与各账从当前值继续；
  # 配置只覆盖实验文件给出的键（未给出的如气候区沿用原环境）。实验换了环境温度或气候区时，
  # 存量热行的显热参考按 ParameterEvolution.ambient_reference 重标进参数重标账，账仍闭合。
  # 新热源与同格未放完的热源合并（余量、功率相加），和其他有限热源一样只在放出时记入供热账。
  # 没有热环境时从空热账开始。电路零功率阈值随原环境配置继承（D1），实验文件不必再写。
  def handle_call({:thermal_experiment, experiment}, _, state) do
    true = experiment["classification"] == "Test-only"
    base = state.thermal || empty_thermal(experiment)
    config = Map.merge(base.config, experiment)

    true =
      config["ambient_kelvin"] > 0 and config["environment_w_per_m2_k"] > 0 and
        config["tolerance_kelvin"] > 0 and radiation_config?(config) and
        VoxelRegion.Climate.valid?(config)

    true = experiment["power_w"] > 0 and experiment["energy_j"] > 0
    micro = experiment["source_macro"] |> Enum.map(&(&1 * @micro)) |> List.to_tuple()
    {%{granularity: 0} = target, state} = target_at(micro, state)
    true = Map.fetch!(state.properties.materials, target.material)["heat_capacity_per_macro"] > 0
    source = %{target: target, power_w: experiment["power_w"], remaining_j: experiment["energy_j"]}

    sources = Map.update(base.sources, Damage.macro(target), source, fn old ->
      %{source | power_w: old.power_w + source.power_w, remaining_j: old.remaining_j + source.remaining_j}
    end)

    reference = ~w(ambient_kelvin climate_zones)

    base =
      if Map.take(config, reference) == Map.take(base.config, reference),
        do: base,
        else: VoxelRegion.ParameterEvolution.ambient_reference(base, config, state.damage, state.properties,
          &finite_volume(state, &1))

    thermal = %{base | config: config, sources: sources, active: true}
    state = thermal_commit(Thermal.rebuild_work(%{state | thermal: thermal}), [])
    {:reply, :ok, state}
  end

  # 一次 owner 调用提供一致投影；物化缓存仍可丢弃。
  def handle_call({:material_snapshot, characters, cells}, from, state),
    do: handle_call({:material_snapshot, characters, cells, :summary}, from, state)

  def handle_call({:material_snapshot, characters, cells, detail}, _, state) do
    {occupancy, state} = Enum.map_reduce(cells, state, fn cell, s ->
      {:ok, {material, _}, s} = cell_value(s, 0, cell)
      refined = Map.get(s.refined, cell, %{})
      slots = refined |> Map.values() |> Enum.group_by(fn {m, owner} -> {m, owner} end)
        |> Enum.map(fn {{m, {birth, occurrence}}, values} ->
          %{material: m, instance: [birth, occurrence], count: length(values)}
        end)
      row = %{cell: Tuple.to_list(cell), material: material, refined: map_size(refined) > 0, slots: slots,
         placed_by: Map.get(s.placed_by, cell)}
      row = if detail == :micro and map_size(refined) > 0 do
        Map.put(row, :micro_cells, for({slot,{m,owner}} <- Enum.sort(refined),
          do: %{micro: Prefab.micro_coord(cell,slot),material: m,instance: owner}))
      else
        row
      end
      {row, s}
    end)
    balances = balance_projection(state.material_balances, characters)
    snapshot = %{seq: state.seq,
      catalog: if(state.properties, do: Base.encode16(state.properties.digest, case: :lower), else: nil),
      capacity_units: liquid_capacity(state), material_balances: balances, craft_ledger: state.craft_ledger,
      food_ledger: state.food_ledger, probe_occupancy: occupancy}
    {:reply, snapshot, state}
  end

  def handle_call({:simulation_snapshot, characters, box}, _, state) do
    in_box = &VoxelRegion.PropertyObservation.contains?(&1, box)
    properties = property_snapshot(state, box)
    snapshot = Map.merge(properties, %{
      seq: state.seq,
      material_balances: balance_projection(state.material_balances, characters),
      liquid_quantities: Map.filter(state.liquid_units, fn {cell, _} -> in_box.(cell) end),
      phase_inventory: Map.filter(state.phase_inventory, fn {{cid, _}, _} -> cid in characters end),
      thermal_accounting: thermal_accounting(state.thermal, in_box)
    })
    {:reply, snapshot, state}
  end

  # 只测试作者供给入口；不可由 Gate 玩家消息调用。
  def handle_call({:liquid_experiment, edits}, _, state) do
    true = liquid_enabled?(state)
    true = Enum.all?(edits, fn {cell,_} -> valid_edit_coord?(cell) and liquid_inside?(cell,state.liquid_bounds) end)
    changes = for {cell,m} <- edits, Phase.liquid?(m) or phase_material?(state,m) or Map.has_key?(state.liquid_units,cell),
      into: %{}, do: {cell,if(Phase.liquid?(m) or phase_material?(state,m),do: liquid_capacity(state),else: 0)}
    values = for {cell,m} <- edits, phase_material?(state,m), into: %{},
      do: {cell,{Phase.energy(%{material: m},1.0,state.properties.materials[m],ambient_at(state,cell)),liquid_capacity(state)*1.0}}
    # 一次作者初态沿原事务保存独立参考账，不能算成模拟供热。
    thermal=if state.thermal,do: Enum.reduce(values,state.thermal,fn {_,{energy,integrity}},t->
      t |> Map.update(:phase_authored_energy_j,energy,&(&1+energy))
        |> Map.update(:phase_authored_units,round(integrity),&(&1+round(integrity)))
    end),else: nil
    case apply_batch(%{state | thermal: thermal}, edits, false, %{liquid_changes: changes,phase_values: values}) do
      {:ok,next} -> {:reply,{:ok,next.seq},next}
      {:error,reason} -> {:reply,{:error,reason},state}
    end
  end

  def handle_call({:author_regions, regions}, _, state) do
    true = regions != [] and Enum.all?(regions, fn r ->
      (r.holder == :reserved or match?({:character, cid} when is_integer(cid) and cid > 0, r.holder)) and
        elem(r.min, 0) <= elem(r.max, 0) and elem(r.min, 1) <= elem(r.max, 1)
    end)

    {delta, _} =
      regions
      |> Enum.with_index(1)
      |> Enum.map_reduce(state.protection, fn {r, n}, p ->
        region = %{holder: r.holder, min: r.min, max: r.max, created_seq: state.seq + 1, created_by: nil}
        {{{state.seq + 1, n}, if(Protection.overlaps?(p, r.min, r.max), do: :overlap, else: region)},
         Protection.apply(p, %{{state.seq + 1, n} => region})}
      end)

    if Enum.any?(delta, &(elem(&1, 1) == :overlap)),
      do: {:reply, {:error, :region_overlap}, state},
      else: commit_protection(state, state, Map.new(delta))
  end

  def handle_call(:magic_range, _, state), do: {:reply, state.magic && state.magic.range_m, state}

  def handle_call({:caster_state, cid}, _, state) do
    reply = if state.magic, do: {:ok, caster_view(state, cid, @no_quote, 0.0, 0.0)}, else: {:error, :magic_unavailable}
    {:reply, reply, state}
  end

  def handle_call({:send_caster_state, cid, request_id, recipient}, from, state) do
    {:reply, result, state} = handle_call({:caster_state, cid}, from, state)
    case result do
      {:ok, caster} -> publish_caster_state(recipient, request_id, caster)
      {:error, _} -> :ok
    end
    {:reply, result, state}
  end

  def handle_call({:spell_intent, actor, request}, from, state) do
    case current_actor(actor) do
      {:ok, current} -> prepare_spell(state, from, Map.put(current, :action_key, {actor.identity, request.client_intent_seq}), request)
      error -> {:reply, error, state}
    end
  end

  def handle_call({:tool_range, id}, _, state), do: {:reply, tool_range(state, id), state}

  def handle_call({:tool_definition, id}, _, state),
    do: {:reply, Map.fetch(state.properties.tools, id), state}

  def handle_call({:body_tool, actor, request, distance}, _, state) do
    tool = Map.fetch!(state.properties.tools, request.tool_id)
    previous = state.tool_sessions[actor.player]
    interval = ceil(tool["interval_seconds"] * 1_000_000)
    # 和地形攻击共用 GCRA，不能交替打人／挖地规避频率。
    with true <- distance <= tool["range_macro"],
         {:error, :no_target, _} <- Damage.raycast(actor.eye, request.direction, distance, state, &target_at/2),
         {:ok, session} <- if(request.action == 0,
           do: {:ok, nil}, else: Damage.admit_attack(previous, request.client_intent_seq, actor.received_us, interval, actor.tick_us)) do
      if session == nil do
        {:reply, :ok, state}
      else
        if previous == nil, do: Process.monitor(actor.player)
        {:reply, :ok, %{state | tool_sessions: Map.put(state.tool_sessions, actor.player, session)}}
      end
    else
      false -> {:reply, {:error, :out_of_reach}, state}
      {:ok, _, _} -> {:reply, {:error, :occluded}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:material_balances, cid}, _, state),
    do: {:reply, Enum.map(state.production_materials, &balance_state(state, cid, &1)), state}

  def handle_call({:material_supply, cid, supply_id, quantities}, _, state) do
    key = {cid, supply_id}
    case Map.fetch(state.material_supplies, key) do
      {:ok, receipt} -> {:reply, {:ok, receipt.seq}, state}
      :error ->
        valid = is_integer(cid) and cid > 0 and is_binary(supply_id) and byte_size(supply_id) > 0 and
          is_map(quantities) and map_size(quantities) > 0 and
          Enum.all?(quantities, fn {material, units} ->
            material in state.production_materials and is_integer(units) and units > 0 and
              (not phase_material?(state, material) or state.thermal != nil)
          end)
        if valid do
          supply_materials(state, key, quantities)
        else
          {:reply, {:error, :invalid_material_supply}, state}
        end
    end
  end

  def handle_call({:production_intent, actor, request}, _, state) do
    with {:ok, actor} <- current_actor(actor), true <- state.production_materials != [] do
      build_target(state, actor, request)
    else
      false -> {:reply, {:error, :production_unavailable}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:attachment_intent, actor, request}, _, state) do
    with {:ok, actor} <- current_actor(actor), true <- state.properties != nil do
      attachment_target(state, actor, request)
    else
      false -> {:reply, {:error, :production_unavailable}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:tool_intent, actor, request}, _, state) do
    started = System.monotonic_time(:microsecond)
    before = state
    tool = Map.fetch!(state.properties.tools, request.tool_id)

    result =
      case current_actor(actor) do
        {:error, reason} ->
          {:reply, {:error, reason}, before}

        {:ok, actor} ->
          refreshed = System.monotonic_time(:microsecond)

          Logger.info(
            "voxel_tool_owner request_id=#{request.request_id} node=#{node()} started_us=#{started} refresh_us=#{refreshed - started}"
          )

          case tool_target(state, actor, request, tool) do
            {:error, reason, _} ->
              {:reply, {:error, reason}, before}

            {:ok, target, state} ->
              target = property_state(state, target)

              cond do
                request.action == 0 ->
                  {:reply, {:ok, public_property(%{target | request_id: request.request_id})}, state}

                Phase.liquid?(target.material) and tool["action"] not in ["phase.cool", "phase.heat"] ->
                  {:reply, {:error, :use_liquid_tool}, before}

                # R8-07：散体格只能舀取（工具 11），镐采与拆解都不接受；点燃、认领等非损伤工具照常。
                loose_cell?(state, target) and String.starts_with?(tool["action"], "damage") ->
                  {:reply, {:error, :use_liquid_tool}, before}

                not same_tool_target?(target, request) ->
                  {:reply, {:error, :stale_target}, state}

                # 受保护区域许可：认领工具自身的规则在其适配里裁决。
                tool["action"] != "protection.claim" and
                    not Protection.permitted?(state.protection, {:character, actor.cid}, target_cells(state, target)) ->
                  {:reply, {:error, :protected_region}, state}

                true ->
                  attack_target(before, state, actor, request, target, tool)
              end
          end
      end

    Logger.info(
      "voxel_tool_owner_done request_id=#{request.request_id} node=#{node()} elapsed_us=#{System.monotonic_time(:microsecond) - started}"
    )

    result
  end

  def handle_call({:publish_prefabs, catalog}, _from, state) do
    {:reply, :ok, %{state | prefabs: Map.merge(state.prefabs, catalog)}}
  end

  def handle_call(:prefab_catalog, _, state), do: {:reply, state.prefabs, state}

  def handle_call(:published_prefabs, _, state),
    do: {:reply, Enum.map(state.published, &{&1.publisher, &1.name, &1.bytes}), state}
  def handle_call(:material_catalog, _, state), do: {:reply, state.properties, state}

  def handle_call({:publish_prefab, actor, bytes, name}, _, state) do
    with {:ok, actor} <- current_actor(actor),
         :ok <- Prefab.check_name(name),
         {:ok, id, compiled} <- Prefab.compile(bytes, state.prefabs),
         {:ok, published} <- persist_prefab(state, actor.cid, name, id, bytes) do
      {:reply, {:ok, id},
       %{state | prefabs: Map.put(state.prefabs, id, compiled), published: published}}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:prefab_cells, id, anchor, orientation}, _from, state) do
    result =
      with {:ok, cells, _macros} <- definition_cells(state, id, anchor, orientation),
           do: {:ok, cells}

    {:reply, result, state}
  end

  def handle_call({:instance_cells, id}, _from, state) do
    cells = owner_cells(state, id)
    {:reply, if(cells == [], do: {:error, :instance_not_found}, else: {:ok, cells}), state}
  end

  def handle_call({:replacement_cells, target, id}, _from, state) do
    result =
      with {:ok, instance} <- fetch_instance(state, target),
           {:ok, _cells, macros} <-
             definition_cells(state, id, instance.anchor, instance.orientation) do
        {:ok, Enum.uniq(owner_cells(state, target) ++ macros)}
      end

    {:reply, result, state}
  end

  def handle_call({:place_prefab, id, anchor, orientation, _cells}, _from, state) do
    place_tree(state, state, Map.fetch!(state.prefabs, id), anchor, orientation, {0, 0}, 0, [])
  end

  def handle_call({:prefab_intent, actor, kind, request}, _, state) do
    with {:ok, actor} <- current_actor(actor) do
      request = Map.put(request, :prefab_operation, kind)
      previous = Map.get(state.build_sessions, actor.gate)

      cond do
        previous != nil and previous.request == request ->
          {:reply, previous.result, state}

        previous != nil and request.client_intent_seq <= previous.request.client_intent_seq ->
          {:reply, {:error, :replayed_build}, state}

        true ->
          {:reply, reply, next} =
            if Protection.permitted?(state.protection, {:character, actor.cid}, prefab_intent_cells(state, kind, request)),
              do: player_prefab(state, actor, kind, request),
              else: {:reply, {:error, :protected_region}, state}
          unless previous != nil, do: Process.monitor(actor.gate)

          next = %{
            next
            | build_sessions:
                Map.put(next.build_sessions, actor.gate, %{request: request, result: reply})
          }

          {:reply, reply, next}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:remove_prefab, id}, _from, state) do
    ids = subtree_ids(state, id)

    case subtree_cells(state, ids) do
      [] -> {:reply, {:error, :instance_not_found}, state}
      cells -> prefab_reply(state, clear_subtree(state, ids, cells), cells)
    end
  end

  def handle_call({:replace_prefab, target, id}, _from, state) do
    with {:ok, instance} <- fetch_instance(state, target),
         {:ok, definition} <- Map.fetch(state.prefabs, id) do
      ids = subtree_ids(state, target)
      cells = subtree_cells(state, ids)
      next = clear_subtree(state, ids, cells)

      place_tree(
        state,
        next,
        definition,
        instance.anchor,
        instance.orientation,
        Map.get(instance, :parent_id, {0, 0}),
        Map.get(instance, :component_slot, 0),
        cells
      )
    else
      :error -> {:reply, {:error, :definition_not_found}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:stats, _from, state) do
    stats =
      Map.merge(state.cache_stats, %{
        entries: map_size(state.payloads),
        retained_transactions: map_size(state.entries),
        checkpoint_scheduled: state.checkpoint_timer != nil,
        checkpoints: state.checkpoints,
        lru_bytes: state.lru_bytes,
        resident_bytes: state.resident_bytes,
        cache_limit: state.cache_limit,
        overlay_cells: map_size(state.overlay),
        overlay_regions: map_size(state.overlay_regions),
        snapshot_regions: MapSet.size(state.snapshots),
        decoded_regions: map_size(state.decoded),
        region_bases: map_size(state.region_bases),
        refined_macros: map_size(state.refined),
        attachment_slots: map_size(state.attachments),
        attachment_bytes: :erlang.external_size(state.attachments),
        instances: map_size(state.instances),
        damaged_targets: map_size(state.damage),
        damage_state_bytes: :erlang.external_size(state.damage),
        property_digest:
          if(state.properties, do: Base.encode16(state.properties.digest, case: :lower)),
        generated: state.source.generated(state.source_state)
      })

    {:reply, stats, state}
  end

  def handle_call({:serve_item, client_version, item}, _from, state) do
    started = System.monotonic_time(:microsecond)

    case serve_item(state, client_version, item) do
      {:error, reason, _state} ->
        {:reply, {:error, reason}, state}

      # 浏览请求只保留最终载荷缓存，期间解码的源数据随本区域释放。
      {reply, served} ->
        Logger.info(
          "voxel_serve_item level=#{item.level} region=#{inspect(item.region)} reply=#{elem(reply, 0)} " <>
            "hit=#{Map.has_key?(state.payloads, {item.level, item.region})} us=#{System.monotonic_time(:microsecond) - started}"
        )

        {:reply, {:ok, reply}, %{served | decoded: state.decoded}}
    end
  end

  def handle_call({:apply_edit, coord, material}, from, state) do
    result = with :ok <- raw_liquid_edit(state, [{coord, material}]),
      do: do_apply_edit(state, coord, material)
    case result do
      {:ok, :noop, state} ->
        acknowledge_noop(state, from)
        {:reply, {:ok, state.seq}, state}

      {:ok, entry, state} ->
        {:reply, {:ok, entry.seq}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
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

  # 供测试与诊断读历史：纯属性事务在内存只留投影字段，正文从持久日志补回。
  def handle_call({:entries_after, seq}, _from, %{log: {backend, handle}} = state) do
    retained = state.entries |> Enum.filter(fn {s, _} -> s > seq end) |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

    bodies =
      if Enum.any?(retained, &match?(%{entries: [], coarse: []}, &1)),
        do: Map.new(for(txn <- backend.replay(handle), txn.seq > seq, do: {txn.seq, txn})),
        else: %{}

    {:reply, Enum.map(retained, &if(match?(%{entries: [], coarse: []}, &1), do: Map.fetch!(bodies, &1.seq), else: &1)), state}
  end

  # 区域字节与属性在 World 内按同一 seq 取好；解码与碰撞投影交给该订阅者的发送进程（CanonicalFeed），它发出快照后答复调用方。
  def handle_call({:canonical_snapshot, box, pid, request, include_chunks}, from, state) do
    started = System.monotonic_time(:microsecond)

    Logger.info(
      "voxel_window_stage stage=world_start request=#{inspect(request)} pid=#{inspect(self())} at_us=#{System.system_time(:microsecond)}"
    )

    case capture_canonical_snapshot(state, box) do
      {:ok, snapshot, state} ->
        unless Map.has_key?(state.canonical_subs, pid), do: Process.monitor(pid)
        feed = Map.get_lazy(state.canonical_feeds, pid, fn -> VoxelRegion.CanonicalFeed.start_link(pid) end)
        send(feed, {:snapshot, request, snapshot, include_chunks, liquid_capacity(state), from})

        Logger.info(
          "voxel_window_stage stage=world_send request=#{inspect(request)} pid=#{inspect(self())} at_us=#{System.system_time(:microsecond)} elapsed_us=#{System.monotonic_time(:microsecond) - started}"
        )

        {:noreply, %{state | canonical_subs: Map.put(state.canonical_subs, pid, box),
          canonical_feeds: Map.put(state.canonical_feeds, pid, feed)}}

      {:error, :canonical_incomplete} ->
        {:reply, {:error, :canonical_incomplete}, state}
    end
  end

  def handle_call({:replica_snapshot, box, pid}, _from, state) do
    case capture_canonical_snapshot(state, box) do
      {:ok, snapshot, state} ->
        unless Map.has_key?(state.replica_subs, pid), do: Process.monitor(pid)
        snapshot = %{snapshot | chunks: CollisionSource.snapshot_chunks(snapshot.regions, liquid_capacity(state))}
        {:reply, {:ok, snapshot}, %{state | replica_subs: Map.put(state.replica_subs, pid, box)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:apply_edits, edits}, from, state) do
    result = with :ok <- raw_liquid_edit(state, edits), do: apply_batch(state, edits)
    case result do
      {:ok, next_state} ->
        if next_state.seq == state.seq, do: acknowledge_noop(next_state, from)
        {:reply, {:ok, next_state.seq}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:compact, _from, state) do
    {:reply, :ok, compact_log(state), {:continue, :checkpoint_gc}}
  end

  @impl true
  def handle_continue(:checkpoint_gc, state) do
    # 历史已释放，下一回调再 full GC，避免旧 state 在上一调用栈继续存活。
    :erlang.garbage_collect(self())
    {:memory, memory} = Process.info(self(), :memory)
    Logger.info("voxel_checkpoint_gc seq=#{state.seq} memory_bytes=#{memory}")
    {:noreply, state}
  end

  @impl true
  # 同上：热提交自己的节拍与步消息之外，其他消息都先写回原生热域的变化。
  def handle_info(message, %{thermal_work: %{domain: %{pending: true}}} = state)
      when message != :thermal_tick and not (is_tuple(message) and elem(message, 0) in [:thermal_step | @unflushed]),
      do: handle_info(message, Thermal.flush(state, if(is_tuple(message), do: elem(message, 0), else: message)))

  def handle_info({:timeout, ref, :checkpoint}, %{checkpoint_timer: ref} = state),
    do: {:noreply, compact_log(state), {:continue, :checkpoint_gc}}

  def handle_info({:timeout, _cancelled, :checkpoint}, state), do: {:noreply, state}

  def handle_info(:liquid_commit, state) do
    if state.liquid_timer, do: Process.cancel_timer(state.liquid_timer)
    active = state.liquid_active
    state = advance_liquid(%{state | liquid_active: MapSet.new(), liquid_timer: nil}, active)
    {:noreply, schedule_liquid(state)}
  end

  # 魔法增量 4：Scene 的 Player 每秒报一次身体（脚位、身高、半径、皮肤温度与热容、体表面积、局部接触组织块的温度 / 热容 /
  # 与皮肤的导热）；本次算出的接触边留到下一次热提交使用。无接触且组织块与皮肤已在容差内平衡即注销。无热环境的世界忽略。
  def handle_info({:body_contact, cid, pid, body}, %{thermal: thermal} = state) when thermal != nil do
    {contacts, immersed, sole, state} = Thermal.body_contacts(state, body)

    bodies =
      if contacts == [] and abs(body.tissue_k - body.skin_k) <= thermal.config["tolerance_kelvin"] do
        Thermal.detach_body(state.bodies, cid)
      else
        {bodies, monitor} = case Map.get(state.bodies, cid) do
          %{pid: ^pid, monitor: monitor} -> {state.bodies, monitor}
          _ -> {Thermal.detach_body(state.bodies, cid), Process.monitor(pid)}
        end
        Map.put(bodies, cid, Map.merge(body, %{pid: pid, monitor: monitor, contacts: contacts,
          immersed: immersed, sole: sole, at: System.monotonic_time(:millisecond)}))
      end

    {:noreply, Thermal.wake(%{state | bodies: bodies})}
  end

  def handle_info({:body_contact, _cid, _pid, _body}, state), do: {:noreply, state}

  # 全局系统功能：Scene seal/退出等待此 fence，先吸收旧 owner 已收到的热量，再交接身体。
  # 热内核每步同步回传；后续步从当前 bodies 取节点。迟到的旧 PID 不得摘掉新 Scene 的接触。
  def handle_info({:body_detach, cid, pid, ref}, state) do
    bodies = case Map.get(state.bodies, cid) do
      %{pid: ^pid} -> Thermal.detach_body(state.bodies, cid)
      _ -> state.bodies
    end
    send(pid, {:body_detached, ref})
    {:noreply, %{state | bodies: bodies}}
  end

  # 身体系数变化沿既有 0x83 推送本人；request 0 只刷新状态，报价与支出仍属于各自请求。
  # 会话身份交给 Gate 的既有出站边界拒旧；seal/stop 的 body_detach fence 已排在旧 owner 的消息之后。
  def handle_info({:body_coherence, cid, factor, gate, identity}, state) do
    value = {identity, factor}
    changed = Map.get(state.caster_coherence, cid) != value
    state = %{state | caster_coherence: Map.put(state.caster_coherence, cid, value)}

    if changed and state.magic != nil do
      publish_caster_state({gate, identity}, 0, caster_view(state, cid, @no_quote, 0.0, 0.0))
    end

    {:noreply, state}
  end

  # 身体闭环 H2：角色死亡（Scene 送来脚位），按 `death_drop/3` 裁决掉落并记账。
  def handle_info({:body_death, cid, feet}, state) do
    {result, state} = death_drop(state, cid, feet)
    Logger.info("voxel_death_drop " <> Enum.map_join(Map.put(result, :cid, cid), " ", fn {k, v} -> "#{k}=#{inspect(v)}" end))
    {:noreply, schedule_liquid(state)}
  end

  # 全局系统：Player 是唯一前摇/授权 owner，World 仅保存待支付的领域负载。
  def handle_info({:quote_cast, actor, request, from}, state) do
    {:reply, result, next} = prepare_spell(state, from, actor, request)
    publish_cast_reply(actor, request, result)
    GenServer.reply(from, result)
    {:noreply, next}
  end
  def handle_info({:prepare_cast, key, actor, request, from}, state) do
    case prepare_spell(state, from, Map.put(actor, :action_key, key), request) do
      {:noreply, next} -> {:noreply, next}
      {:reply, result, next} ->
        send(actor.player, {:cast_failed, key})
        GenServer.reply(from, result)
        {:noreply, next}
    end
  end
  def handle_info({:authorize_cast, key, actor, request}, state) do
    case state.pending_casts[actor.cid] do
      %{actor: %{action_key: ^key, player: player}} = pending when player == actor.player ->
        # 授权快照来自角色 owner，同一消息携带姿态与 Body；不再同步回调 Player。
        Process.demonitor(pending.monitor, [:flush])
        current = Map.merge(pending.actor, actor)
        pending = %{pending | actor: current, request: %{pending.request | direction: request.direction}}
        next = %{state | pending_casts: Map.delete(state.pending_casts, actor.cid),
          caster_coherence: Map.put(state.caster_coherence, actor.cid, {actor.identity, actor.coherence_factor})}
        {reply, next} = settle_cast(next, pending)
        publish_cast_reply(pending.actor, pending.request, reply)
        GenServer.reply(pending.from, reply)
        {:noreply, next}
      _ -> {:noreply, state}
    end
  end
  def handle_info({:cancel_cast, key, reason}, state), do: {:noreply, cancel_pending_cast(state, key, reason)}

  # 定时提交按内核步分成多条消息推进，步间先处理已排队的工具、建造和查询调用；整段仍作为一笔热事务提交。
  # 无可推进的状态时休眠：不再排下一拍，直到事务或身体接触唤醒（R8-05）。
  def handle_info(:thermal_tick, %{thermal_run: nil} = state) do
    state = state |> Thermal.fired() |> Thermal.begin()
    {:noreply, if(state.thermal_run, do: step_thermal(state), else: Thermal.rest(state))}
  end

  # 进行中的提交完成时才排下一次；此时到期的节拍不另起提交。
  def handle_info(:thermal_tick, state), do: {:noreply, Thermal.fired(state)}

  def handle_info({:thermal_step, ref}, %{thermal_run: %{ref: ref}} = state), do: {:noreply, step_thermal(state)}
  def handle_info({:thermal_step, _ref}, state), do: {:noreply, state}

  # 直接投递的提交在本次回调内完整执行；先完成进行中的定时提交，不把两段模拟混入同一事务。
  def handle_info(:thermal_commit, state) do
    state = state |> drain_thermal() |> Thermal.begin() |> drain_thermal()
    {:noreply, Thermal.wake(state)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = Enum.reduce(state.pending_casts, state, fn {_, pending}, acc ->
      if pending.actor.player == pid, do: cancel_pending_cast(acc, pending.actor.action_key, :invalid_session), else: acc
    end)
    bodies = Enum.reduce(state.bodies, state.bodies, fn {cid, body}, bodies ->
      if body.pid == pid, do: Thermal.detach_body(bodies, cid), else: bodies
    end)
      {:noreply,
       %{
         state
         | bodies: bodies,
           subs: Map.delete(state.subs, pid),
           canonical_subs: Map.delete(state.canonical_subs, pid),
           canonical_feeds: Map.delete(state.canonical_feeds, pid),
           replica_subs: Map.delete(state.replica_subs, pid),
           tool_sessions: Map.delete(state.tool_sessions, pid),
           spell_sessions: Map.delete(state.spell_sessions, pid),
           claim_corners: Map.delete(state.claim_corners, pid),
           build_sessions: Map.delete(state.build_sessions, pid)
       }}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp step_thermal(state) do
    case Thermal.tick(state) do
      {:more, state} -> send(self(), {:thermal_step, state.thermal_run.ref}); state
      {:done, state, commit} -> state |> commit_thermal(commit) |> Thermal.wake()
    end
  end

  defp drain_thermal(%{thermal_run: nil} = state), do: state

  defp drain_thermal(state) do
    case Thermal.tick(state) do
      {:more, state} -> drain_thermal(state)
      {:done, state, commit} -> commit_thermal(state, commit)
    end
  end

  @impl true
  def code_change(:region_bases, state, _extra), do: {:ok, Map.put_new(state, :region_bases, %{})}
end
