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

  alias VoxelRegion.{Attachments, ThermalWork, LogProjection}
  use GenServer
  require Logger
  import Bitwise
  alias VoxelRegion.{OverlayLog, Damage}
  alias VoxelRegion.{CollisionSource, FileStore, Prefab, Reducer}
  alias VoxelRegion.{Combustion, Liquid, Phase, Protection, Transform}
  alias VoxelRegion.Magic
  alias MmoContracts.Voxel.{CanonicalDelta, CanonicalSnapshot, Codec, Payload}

  @micro VoxelRegion.Spatial.micro_resolution()
  @max_level 5
  @resident_level 4
  @default_cache_bytes 512 * 1024 * 1024
  # 魔法增量 1：登录下发与无报价时的报价字段。
  @no_quote %{total_j: 0.0, structure: 0.0}
  # 施法留热、走火与取能损耗以有限热源落地，在一个 500 ms 热提交内放完（热源机制要求有限功率）。
  @deposit_seconds 0.5
  # 魔法增量 2：emit = hand 的拟态在眼前 0.5 m（沿眼睛方向）成形；弹道从这里出发。
  @hand_reach 0.5
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

    Logger.info(
      "voxel_source_return caller=#{inspect(self())} at_us=#{System.system_time(:microsecond)} missing=#{length(missing)}"
    )

    missing
    |> Task.async_stream(fn {level, region} -> source.ensure(source_state, level, region) end,
      max_concurrency: Application.get_env(:voxel_region, :generation_concurrency, 8),
      ordered: false,
      timeout: :infinity
    )
    |> Stream.run()

    GenServer.call(server, {:adopt_liquid, Enum.uniq(for {0, region} <- keys, do: region)}, 300_000)
  end

  defp edit_keys(coords) do
    for {x, y, z} <- coords, level <- 0..@max_level do
      step = 1 <<< level
      {level, region_of({floor_div(x, step), floor_div(y, step), floor_div(z, step)})}
    end
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
    if request.action == 4 or valid_edit_coord?(request.coord) do
      if request.action in [2,3] do
        case GenServer.call(server, {:tool_range, request.tool_id}, 300_000) do
          {:error,_}=error -> error
          range ->
            prepare(server, edit_keys([request.coord]) ++ tool_regions(actor,range))
            GenServer.call(server, {:production_intent, actor, request}, 300_000)
        end
      else
        if request.action == 1, do: prepare(server, edit_keys([request.coord]))
        GenServer.call(server, {:production_intent, actor, request}, 300_000)
      end
    else
      {:error, :invalid_coordinate}
    end
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
    # Cold generation remains outside the World mailbox; the authoritative ray is
    # evaluated again inside the atomic owner after preparation.
    range = GenServer.call(server, {:tool_range, request.tool_id}, 300_000)

    case range do
      {:error, _} = error ->
        error

      range ->
        if not valid_edit_coord?(Damage.macro(request)) do
          {:error, :invalid_coordinate}
        else
          prepare(server, tool_regions(actor, range))
          if request.action == 1, do: prepare(server, edit_keys([Damage.macro(request)]))
          prepared = System.monotonic_time(:microsecond)
          result = GenServer.call(server, {:tool_intent, actor, request}, 300_000)

          Logger.info(
            "voxel_tool_call request_id=#{request.request_id} node=#{node()} prepare_us=#{prepared - started} owner_call_us=#{System.monotonic_time(:microsecond) - prepared}"
          )

          result
        end
    end
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
          # 下一次热提交的墙钟到期时刻（毫秒，单调时钟）；nil 表示尚未排程。
          thermal_due: nil,
          material_balances: %{},
          # 魔法增量 1：施法者能量（cid => J）是权威真值，随日志／检查点持久化；不自动回复。
          caster_energy: %{},
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
        state = rebuild_thermal_work(state)

        Logger.info(
          "voxel_region world #{FileStore.hex(cv)} ready, seq=#{state.seq}, root=#{world_dir}"
        )

        state = schedule_liquid(state)
        state = if state.thermal, do: schedule_thermal(state), else: state
        {:ok, state}

      {:error, :no_world} ->
        {:stop, {:no_world, Keyword.fetch!(opts, :root)}}
    end
  end

  @impl true
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

    {:reply, {state.source, state.source_state, missing}, state}
  end

  def handle_call({:adopt_liquid, regions}, _, state) do
    state = if liquid_enabled?(state),
      do: Enum.reduce(regions, state, &adopt_liquid_sources(&2, &1)), else: state
    {:reply, :ok, state}
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

  def handle_call({:thermal_experiment, config}, _, state) do
    true = config["classification"] == "Test-only"

    true =
      config["ambient_kelvin"] > 0 and config["environment_w_per_m2_k"] > 0 and
        config["tolerance_kelvin"] > 0 and radiation_config?(config) and
        VoxelRegion.Climate.valid?(config)

    true = config["power_w"] > 0 and config["energy_j"] > 0
    micro = config["source_macro"] |> Enum.map(&(&1 * @micro)) |> List.to_tuple()
    {%{granularity: 0} = target, state} = target_at(micro, state)
    true = Map.fetch!(state.properties.materials, target.material)["heat_capacity_per_macro"] > 0
    source = %{target: target, power_w: config["power_w"], remaining_j: config["energy_j"]}

    thermal = %{
      config: config,
      sources: %{Damage.macro(target) => source},
      elapsed_s: 0.0,
      supplied_j: 0.0,
      environment_j: 0.0,
      combustion_j: 0.0,
      combustion_removed_j: 0.0,
      active: true
    }

    state = if state.thermal == nil, do: schedule_thermal(state), else: state
    state = thermal_commit(rebuild_thermal_work(%{state | thermal: thermal}), [])
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

  def handle_call({:spell_intent, actor, request}, from, state) do
    with {:ok, actor} <- current_actor(actor),
         true <- state.magic != nil and state.magic.digest == request.catalog_digest,
         {:ok, program} <- Magic.Program.parse(request.program, state.magic),
         :ok <- warm_semblance(program, state.thermal.config["ambient_kelvin"]) do
      quote = Magic.Cost.quote(program, state.magic, state.thermal.config["ambient_kelvin"])

      if request.action == 0,
        do: {:reply, {:ok, %{seq: state.seq, outcome: nil, caster: caster_view(state, actor.cid, quote, 0.0, quote.windup_s)}}, state},
        else: cast_spell(state, from, actor, request, program, quote)
    else
      false -> {:reply, {:error, :stale_magic_catalog}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:tool_range, id}, _, state) do
    result =
      with %{tools: tools} <- state.properties,
           {:ok, tool} <- Map.fetch(tools, id),
           do: tool["range_macro"]

    {:reply, if(is_number(result), do: result, else: {:error, :invalid_tool}), state}
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
    case serve_item(state, client_version, item) do
      {:error, reason, _state} -> {:reply, {:error, reason}, state}
      # 浏览请求只保留最终载荷缓存，期间解码的源数据随本区域释放。
      {reply, served} -> {:reply, {:ok, reply}, %{served | decoded: state.decoded}}
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

  def handle_call({:entries_after, seq}, _from, state) do
    {:reply,
     state.entries
     |> Enum.filter(fn {s, _} -> s > seq end)
     |> Enum.sort_by(&elem(&1, 0))
     |> Enum.map(&elem(&1, 1)), state}
  end

  def handle_call({:canonical_snapshot, box, pid, request, include_chunks}, _from, state) do
    started = System.monotonic_time(:microsecond)

    Logger.info(
      "voxel_window_stage stage=world_start request=#{inspect(request)} pid=#{inspect(self())} at_us=#{System.system_time(:microsecond)}"
    )

    case capture_canonical_snapshot(state, box, include_chunks) do
      {:ok, snapshot, state} ->
        unless Map.has_key?(state.canonical_subs, pid), do: Process.monitor(pid)
        sending = System.monotonic_time(:microsecond)

        Logger.info(
          "voxel_window_stage stage=world_send request=#{inspect(request)} pid=#{inspect(self())} at_us=#{System.system_time(:microsecond)} elapsed_us=#{sending - started}"
        )

        send(pid, {:canonical_snapshot, request, snapshot})

        Logger.info(
          "voxel_window_stage stage=world_sent request=#{inspect(request)} pid=#{inspect(self())} at_us=#{System.system_time(:microsecond)} elapsed_us=#{System.monotonic_time(:microsecond) - sending}"
        )

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
  def handle_info({:timeout, ref, :checkpoint}, %{checkpoint_timer: ref} = state) do
    started = System.monotonic_time(:microsecond)
    retained = map_size(state.entries)
    next = compact_log(state)
    Logger.info("voxel_checkpoint seq=#{next.seq} retained_before=#{retained} retained_after=#{map_size(next.entries)} elapsed_us=#{System.monotonic_time(:microsecond) - started}")
    {:noreply, next, {:continue, :checkpoint_gc}}
  end

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
    {contacts, immersed, sole, state} = body_contacts(state, body)

    bodies =
      if contacts == [] and abs(body.tissue_k - body.skin_k) <= thermal.config["tolerance_kelvin"],
        do: Map.delete(state.bodies, cid),
        else: Map.put(state.bodies, cid, Map.merge(body, %{pid: pid, contacts: contacts, immersed: immersed, sole: sole,
          at: System.monotonic_time(:millisecond)}))

    {:noreply, %{state | bodies: bodies}}
  end

  def handle_info({:body_contact, _cid, _pid, _body}, state), do: {:noreply, state}

  # 施放前摇到期：用开始时捕获的施法者、意图与程序走现有结算路径；回执此时才回给施放调用方。
  # 到期消息以记录的 t0_us 标识这条待施放；已结算的旧定时器（t0 不符）直接忽略。
  def handle_info({:settle_cast, cid, t0_us}, state) do
    case state.pending_casts do
      %{^cid => %{record: %{t0_us: ^t0_us}} = pending} ->
        {reply, state} = settle_cast(%{state | pending_casts: Map.delete(state.pending_casts, cid)}, pending)
        GenServer.reply(pending.from, reply)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:thermal_commit, state) do
    started = System.monotonic_time(:microsecond)
    now = System.monotonic_time(:millisecond)
    state = %{state | bodies: Map.filter(state.bodies, fn {_, b} -> now - b.at <= 2_500 end)}

    {state, transform_us} =
      if state.thermal.active or circuit_seeds(state) != [] or semblances(state) != %{} or state.bodies != %{} do
        state = advance_thermal(state)
        advanced = System.monotonic_time(:microsecond)
        state = transform_heated_materials(state)
        {state, System.monotonic_time(:microsecond) - advanced}
      else
        {state, 0}
      end

    state = schedule_thermal(state)

    if state.thermal.active,
      do:
        Logger.info(
          "voxel_thermal_callback elapsed_us=#{System.monotonic_time(:microsecond) - started} transform_us=#{transform_us} sim_s=#{state.thermal.elapsed_s} seq=#{state.seq}"
        )

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do:
      {:noreply,
       %{
         state
         | subs: Map.delete(state.subs, pid),
           canonical_subs: Map.delete(state.canonical_subs, pid),
           replica_subs: Map.delete(state.replica_subs, pid),
           tool_sessions: Map.delete(state.tool_sessions, pid),
           spell_sessions: Map.delete(state.spell_sessions, pid),
           claim_corners: Map.delete(state.claim_corners, pid),
           build_sessions: Map.delete(state.build_sessions, pid)
       }}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def code_change(:region_bases, state, _extra), do: {:ok, Map.put_new(state, :region_bases, %{})}

  # ---- 应答

  defp serve_item(state, client_version, %{
         level: level,
         region: region,
         have_seq: have_seq,
         have_hash: have_hash
       }) do
    case payload_bytes(state, level, region) do
      {:ok, bytes, header, state} ->
        key = {level, region}
        known = Map.get(state.served_headers, key) == {have_seq, have_hash}

        served = %{
          state
          | served_headers: Map.put(state.served_headers, key, {header.seq, header.hash})
        }

        cond do
          client_version == state.cv and header.hash == have_hash and header.seq == have_seq ->
            {{:unchanged, level, region}, served}

          client_version != state.cv or have_seq == 0 or not known ->
            {{:payload, level, region, bytes}, served}

          true ->
            transactions = LogProjection.since(state.entry_regions, state.entries, level, region, have_seq)
            entry_reply = {:entries, level, region, transactions}
            payload_reply = {:payload, level, region, bytes}

            if transactions != :region and transactions != [] and
                 IO.iodata_length(Codec.encode_reply(state.cv, [entry_reply])) <
                   IO.iodata_length(Codec.encode_reply(state.cv, [payload_reply])) do
              {entry_reply, state}
            else
              {payload_reply, served}
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
        bases = neighboring_bases(state, level, region)

        if MapSet.size(cells) == 0 and not MapSet.member?(state.snapshots, key) and bases == [] do
          case state.source.read(state.source_state, level, region) do
            {:ok, bytes, header} -> {:ok, bytes, header, cache_put(state, key, bytes, header)}
            {:error, :missing} -> {:error, :missing, state}
            {:error, reason} -> {:error, reason, state}
          end
        else
          case decoded(state, level, region) do
            {:ok, payload, state} ->
              overrides =
                Map.new(cells, fn cell ->
                  {Payload.local(region, cell), Map.fetch!(state.overlay, {level, cell})}
                end)

              overrides = Map.merge(ring_overrides(bases, region), overrides)
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
  defp neighboring_bases(state, level, {rx, ry, rz}) do
    for dx <- -1..1,
        dy <- -1..1,
        dz <- -1..1,
        {dx, dy, dz} != {0, 0, 0},
        {:ok, p} <- [Map.fetch(state.region_bases, {level, {rx + dx, ry + dy, rz + dz}})],
        do: {p, {dx, dy, dz}}
  end

  defp ring_overrides(bases, region) do
    {ox, oy, oz} = Payload.origin(region)

    for {p, {dx, dy, dz}} <- bases,
        x <- ring_axis(dx),
        y <- ring_axis(dy),
        z <- ring_axis(dz),
        into: %{},
        do: {{x, y, z}, Payload.value(p, Payload.local(p.region, {ox + x, oy + y, oz + z}))}
  end

  defp ring_axis(-1), do: 0..0
  defp ring_axis(0), do: 1..(Payload.extent() - 2)
  defp ring_axis(1), do: (Payload.extent() - 1)..(Payload.extent() - 1)

  defp with_refined(state, %Payload{level: 0, region: region} = payload) do
    refined =
      for {cell, slots} <- state.refined,
          local = Payload.local(region, cell),
          Payload.in_span?(local),
          into: %{},
          do: {Payload.cell_index(local), slots}

    macro_owners = Map.filter(state.macro_owners, fn {cell, _} -> Payload.in_span?(Payload.local(region, cell)) end)
    ids = live_instance_ids(refined, state.instances, macro_owners)

    %{
      payload
      | liquid_units: for({cell, units} <- state.liquid_units,
            local = Payload.local(region, cell), Payload.in_span?(local),
            into: %{}, do: {Payload.cell_index(local), units}),
        attachments: Attachments.extract(state.attachments, region),
        refined: refined,
        instances: Map.take(state.instances, ids),
        format_version: if(ids != [] or payload.format_version == 5, do: 5, else: 4)
    }
  end

  defp with_refined(state, %Payload{level: level, region: region} = payload) do
    structure =
      for {{^level, cell}, grid} <- state.structure,
          local = Payload.local(region, cell),
          Payload.in_span?(local),
          into: %{},
          do: {Payload.cell_index(local), grid}

    %{payload | structure: structure}
  end

  defp definition_cells(state, id, anchor, orientation) do
    with {:ok, definition} <- Map.fetch(state.prefabs, id), true <- orientation in 0..23,
         :ok <- prefab_alignment(definition, anchor) do
      # Callers use these samples to prepare/check macro bounds, never as micro volume.
      cells = Prefab.footprint(definition, anchor, orientation) ++
        Enum.map(Prefab.macro_footprint(definition, anchor, orientation), fn {cell,m} -> {Prefab.micro_coord(cell,0),m} end)
      macros = footprint_macros(cells)

      if Enum.all?(macros, &valid_edit_coord?/1),
        do: {:ok, cells, macros},
        else: {:error, :invalid_coordinate}
    else
      :error -> {:error, :definition_not_found}
      false -> {:error, :invalid_orientation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prefab_alignment(%{has_macro_cells: true}, {x,y,z}) when rem(x,@micro) != 0 or rem(y,@micro) != 0 or rem(z,@micro) != 0,
    do: {:error, :misaligned}
  defp prefab_alignment(_, _), do: :ok

  defp footprint_macros(cells) do
    cells |> Enum.map(fn {micro, _} -> elem(Prefab.macro_slot(micro), 0) end) |> Enum.uniq()
  end

  defp fetch_instance(state, id) do
    case Map.fetch(state.instances, id) do
      {:ok, instance} -> {:ok, instance}
      :error -> {:error, :instance_not_found}
    end
  end

  defp subtree_ids(state, id) do
    children =
      Enum.group_by(
        state.instances,
        fn {_, i} -> Map.get(i, :parent_id, {0, 0}) end,
        &elem(&1, 0)
      )

    descendants(children, [id], MapSet.new())
  end

  defp descendants(_, [], ids), do: ids

  defp descendants(children, [id | rest], ids),
    do: descendants(children, Map.get(children, id, []) ++ rest, MapSet.put(ids, id))

  defp owner_cells(state, id) do
    subtree_cells(state, subtree_ids(state, id))
  end

  defp subtree_cells(state, ids) do
    macro = for {cell, owner} <- state.macro_owners, MapSet.member?(ids, owner), do: cell
    Enum.uniq(micro_owner_cells(state,ids) ++ macro)
  end

  defp micro_owner_cells(state,ids) do
    for {cell,slots} <- state.refined,
      Enum.any?(slots,fn {_,{_,owner}} -> MapSet.member?(ids,owner) end),do: cell
  end

  defp clear_subtree(state, ids, cells) do
    next =
      Enum.reduce(cells, state, fn cell, s ->
        slots =
          Map.get(s.refined, cell, %{})
          |> Map.reject(fn {_, {_, owner}} -> MapSet.member?(ids, owner) end)

        refined =
          if map_size(slots) == 0,
            do: Map.delete(s.refined, cell),
            else: Map.put(s.refined, cell, slots)

        put_overlay(%{s | refined: refined, macro_owners: Map.delete(s.macro_owners,cell),
          placed_by: Map.delete(s.placed_by,cell), liquid_units: Map.delete(s.liquid_units,cell)},
          0, cell, {0, MmoContracts.Voxel.Skins.uniform(0)})
      end)

    live = live_instance_ids(next.refined,next.instances,next.macro_owners) |> MapSet.new()
    dead = MapSet.difference(ids,live)
    owned =
      Map.filter(next.attachment_owners, fn {_, {owner, _}} -> MapSet.member?(dead, owner) end)
      |> Map.keys()
      |> MapSet.new()

    %{
      next
      | instances: Map.drop(next.instances, MapSet.to_list(dead)),
        attachments:
          Map.reject(next.attachments, fn {_, {id, _}} -> MapSet.member?(owned, id) end),
        attachment_owners: Map.drop(next.attachment_owners, MapSet.to_list(owned))
    }
  end

  defp player_prefab(state, actor, :voxel_prefab_place_v1, r) do
    with {:ok, definition} <- Map.fetch(state.prefabs, r.definition_id) do
      place_tree(state, state, definition, r.anchor, r.orientation, {0, 0}, 0, [], actor)
    else
      :error -> {:reply, {:error, :definition_not_found}, state}
    end
  end

  defp player_prefab(state, actor, kind, r) do
    with {:ok, instance} <- fetch_instance(state, r.instance_id) do
      ids = subtree_ids(state, r.instance_id)
      cells = subtree_cells(state, ids)
      next = clear_subtree(state, ids, cells)

      case kind do
        :voxel_prefab_remove_v1 ->
          prefab_settle(state, next, cells, actor)

        :voxel_prefab_replace_v1 ->
          case Map.fetch(state.prefabs, r.definition_id) do
            {:ok, definition} ->
              place_tree(
                state,
                next,
                definition,
                instance.anchor,
                instance.orientation,
                instance.parent_id,
                instance.component_slot,
                cells,
                actor
              )

            :error ->
              {:reply, {:error, :definition_not_found}, state}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp prefab_settle(before, state, cells, nil), do: prefab_reply(before, state, cells)

  defp prefab_settle(before, state, cells, actor) do
    case prefab_reach(state, actor, cells) do
      :ok -> prefab_reply(before, state, cells, %{prefab_actor: actor})
      {:error, reason} -> {:reply, {:error, reason}, before}
    end
  end

  defp prefab_payment(before, state, cells, %{prefab_actor: actor}) do
    # 支撑裁剪完成后，只按实际前后差额一次结算；可用本次回收支付替换，不从模板退款。
    removed_macros = changed_prefab_macros(before,state,cells)
    added_macros = changed_prefab_macros(state,before,cells)
    delta = Enum.reduce(removed_macros,%{},fn {cell,m},delta ->
      units = if Phase.liquid?(m) or phase_material?(before,m) do
        Map.get(before.liquid_units,cell,liquid_capacity(before))
      else
        {target,_} = target_at(Prefab.micro_coord(cell,0),before)
        recover_units(before,target,liquid_capacity(before))
      end
      Map.update(delta,m,units,&(&1+units))
    end)
    delta = Enum.reduce(added_macros,delta,fn {_,m},delta ->
      Map.update(delta,m,-liquid_capacity(state),&(&1-liquid_capacity(state)))
    end)
    delta =
      Enum.reduce(cells, delta, fn cell, delta ->
        n = state.material_units_per_micro

        delta =
          Enum.reduce(Map.get(before.refined, cell, %{}), delta, fn {slot, {m, owner}=value}, d ->
            if Map.get(Map.get(state.refined,cell,%{}),slot)==value do
              Map.update(d,m,n,&(&1+n))
            else
              row=%{micro: Prefab.micro_coord(cell,slot),granularity: 1,incarnation: elem(owner,0),owner: owner,material: m}
              recovered=recover_units(before,row,n)
              Map.update(d,m,recovered,&(&1+recovered))
            end
          end)

        Enum.reduce(Map.get(state.refined, cell, %{}), delta, fn {_, {m, _}}, d ->
          Map.update(d, m, -n, &(&1 - n))
        end)
      end)

    delta =
      Enum.reduce(state.attachments, delta, fn {slot, {_, m}} = entry, d ->
        n = Attachments.units([slot], state.properties)

        if Map.get(before.attachments, slot) == elem(entry, 1),
          do: d,
          else: Map.update(d, m, -n, &(&1 - n))
      end)

    old_changed =
      Map.filter(before.attachments, fn {slot, value} ->
        Map.get(state.attachments, slot) != value
      end)

    delta =
      Enum.reduce(old_changed, delta, fn {slot, {_, m}}, d ->
        n = attachment_recovery(before,[slot])
        Map.update(d, m, n, &(&1 + n))
      end)

    delta = Map.reject(delta, fn {_, n} -> n == 0 end)

    with :ok <-
           if(Enum.all?(delta, fn {m, _} -> m in state.production_materials end),
             do: :ok,
             else: {:error, :unknown_resource}
           ),
         :ok <-
           if(
             Enum.all?(delta, fn {m, n} -> balance_state(state, actor.cid, m).balance + n >= 0 end),
             do: :ok,
             else: {:error, :insufficient_material}
           ),
         {:ok,state,phase} <- prefab_phase_payment(before,state,removed_macros,added_macros,cells,actor.cid) do
      {next, balances} =
        Enum.reduce(delta, {state, %{}}, fn {m, n}, {s, b} ->
          {s, paid} = settle_material(s, actor.cid, m, n)
          {s, Map.merge(b, paid.material_balances)}
        end)

      {:ok, next, Map.put(phase,:material_balances,balances)}
    else
      {:error, _} = error -> error
    end
  end

  defp prefab_payment(before, state, cells, settlement) do
    # 作者入口与既有 liquid_experiment 一样，首次给宏格建立有限相态。
    added = changed_prefab_macros(state,before,cells)
    values = for {cell,m} <- added,phase_material?(state,m),into: %{},
      do: {cell,{Phase.energy(%{material: m},1.0,state.properties.materials[m],ambient_at(state,cell)),liquid_capacity(state)*1.0}}
    quantities = for {cell,m} <- added,Phase.liquid?(m) or phase_material?(state,m),into: %{},
      do: {cell,liquid_capacity(state)}
    thermal = if state.thermal,do: Enum.reduce(values,state.thermal,fn {_,{energy,integrity}},thermal ->
      thermal |> Map.update(:phase_authored_energy_j,energy,&(&1+energy))
        |> Map.update(:phase_authored_units,round(integrity),&(&1+round(integrity)))
    end)
    {:ok,%{state | liquid_units: Liquid.apply_changes(state.liquid_units,quantities),thermal: thermal},
      Map.put(settlement,:prefab_phase_values,values)}
  end

  defp changed_prefab_macros(state, other, cells) do
    for cell <- cells, Map.has_key?(state.macro_owners,cell),
      Map.get(state.macro_owners,cell) != Map.get(other.macro_owners,cell) do
      {:ok,{material,_},_} = cell_value(state,0,cell)
      {cell,material}
    end
  end

  # 余额继续由 prefab_payment 一次结算；micro 复用既有逐槽温度及整件 HP。
  defp prefab_phase_payment(before,state,removed,added,cells,cid) do
    quantities = for {cell,m} <- added,Phase.liquid?(m) or phase_material?(state,m),into: %{},
      do: {cell,liquid_capacity(state)}
    removed = Enum.filter(removed,fn {_,m} -> phase_material?(before,m) end)
    added = Enum.filter(added,fn {_,m} -> phase_material?(state,m) end)
    {old_values,_} = phase_values(before,Enum.map(removed,&elem(&1,0)))
    removed_micro = changed_phase_micro(before,state,cells)
    added_micro = changed_phase_micro(state,before,cells)
    ratios = removed_micro |> Enum.uniq_by(& &1.owner) |> Map.new(fn target ->
      component = property_state(before,%{target | granularity: 2})
      {target.owner,component.hp/component.max_hp}
    end)
    removed = Enum.map(removed,fn {cell,m} ->
      {m,Map.get(before.liquid_units,cell,liquid_capacity(before)),Phase.pair(Map.fetch!(old_values,cell))}
    end) ++ Enum.map(removed_micro,fn target ->
      row = property_state(before,target)
      energy = Phase.energy(row,Damage.volume(1),before.properties.materials[target.material],ambient_at(before,Damage.macro(target)))
      {target.material,before.material_units_per_micro,{energy,before.material_units_per_micro*ratios[target.owner]}}
    end)
    {inventory,balances} = Enum.reduce(removed,{%{},state.material_balances},fn {m,q,value},{inventory,balances} ->
      key = {cid,m}
      balance = Map.get(balances,key,0)
      carried = Map.get_lazy(inventory,key,fn -> inventory_phase(state,cid,m,balance) end)
      {_,carried} = Phase.transfer(value,carried,q,q,:scoop)
      {Map.put(inventory,key,carried),Map.put(balances,key,balance+q)}
    end)
    added = Enum.map(added,fn {cell,m} -> {{:macro,cell},m,liquid_capacity(state)} end) ++
      Enum.map(added_micro,fn target -> {{:micro,target},target.material,state.material_units_per_micro} end)
    Enum.reduce_while(added,{:ok,inventory,balances,%{},[]},fn {address,m,q},{:ok,inventory,balances,values,micro_values} ->
      key = {cid,m}
      balance = Map.get(balances,key,0)
      carried = Map.get_lazy(inventory,key,fn -> inventory_phase(state,cid,m,balance) end)
      if not Phase.liquid?(m) and elem(carried,1) <= 0 do
        {:halt,{:error,:broken_material}}
      else
        {value,carried} = Phase.transfer({0.0,0.0},carried,balance,q,:pour)
        {values,micro_values} = case address do
          {:macro,cell} -> {Map.put(values,cell,value),micro_values}
          {:micro,target} -> {values,[{target,value} | micro_values]}
        end
        {:cont,{:ok,Map.put(inventory,key,carried),Map.put(balances,key,balance-q),values,micro_values}}
      end
    end)
    |> case do
      {:ok,inventory,_balances,values,micro_values} ->
        {:ok,%{state | phase_inventory: Map.merge(state.phase_inventory,inventory),
          liquid_units: Liquid.apply_changes(state.liquid_units,quantities)},
          %{phase_inventory: inventory,prefab_phase_values: values,prefab_phase_micro: micro_values,
            prefab_phase_preserved: MapSet.new(removed_micro,&Damage.key/1)}}
      {:error,_}=error -> error
    end
  end

  defp changed_phase_micro(state,other,cells) do
    for cell <- cells,{slot,{material,{birth,_}=owner}=value} <- Map.get(state.refined,cell,%{}),
      Map.get(Map.get(other.refined,cell,%{}),slot) != value,phase_material?(state,material),
      do: %{micro: Prefab.micro_coord(cell,slot),granularity: 1,incarnation: birth,owner: owner,material: material}
  end

  defp put_prefab_phase_micro(state,values) do
    {state,rows,pools} = Enum.reduce(values,{state,[],%{}},fn {target,{energy,integrity}},{s,rows,pools} ->
      material = s.properties.materials[target.material]
      volume = Damage.volume(1)
      latent = if Phase.liquid?(target.material),do: material["latent_heat_per_macro_j"],else: 0.0
      # Micro 仍是既有显热节点；平台内的焓转回等量显热，不能新增第二套微格相变模型。
      temperature = material["phase_transition_kelvin"] + (energy/volume-latent)/material["heat_capacity_per_macro"]
      row = property_state(s,target) |> Map.put(:temperature_kelvin,temperature)
      loss = row.max_hp*(1.0-max(0.0,min(1.0,integrity/s.material_units_per_micro)))
      pools = Map.update(pools,target.owner,{target,loss},fn {previous,total} -> {previous,total+loss} end)
      s = %{s | damage: Map.put(s.damage,Damage.key(row),row)}
      s = %{s | thermal: %{s.thermal | active: true},
        thermal_work: %{s.thermal_work | hot: MapSet.put(s.thermal_work.hot,Damage.macro(target))}}
      {s,[row | rows],pools}
    end)
    Enum.reduce(pools,{state,rows},fn {_owner,{target,loss}},{s,rows} ->
      row = property_state(s,%{target | granularity: 2})
      row = %{row | hp: row.max_hp-loss}
      {%{s | damage: Map.put(s.damage,Damage.key(row),row)},[row | rows]}
    end)
  end

  defp prefab_reach(state, actor, cells) do
    range = state.properties.tools[1]["range_macro"]

    if Enum.any?(cells, &(build_reach(actor.eye, &1, range) == :ok)),
      do: :ok,
      else: {:error, :out_of_reach}
  end

  defp place_tree(
         before,
         state,
         definition,
         anchor,
         orientation,
         parent,
         slot,
         changed,
         actor \\ nil
       ) do
    case prefab_alignment(definition, anchor) do
      :ok -> place_aligned_tree(before,state,definition,anchor,orientation,parent,slot,changed,actor)
      {:error,reason} -> {:reply,{:error,reason},before}
    end
  end

  defp place_aligned_tree(before,state,definition,anchor,orientation,parent,slot,changed,actor) do
    nodes = Prefab.occurrences(definition, anchor, orientation, before.seq + 1, parent, slot)
    macro_nodes = Prefab.macro_occurrences(definition, anchor, orientation, before.seq + 1, parent, slot)
    macro_additions = for {owner,_,cells} <- macro_nodes, {cell,m} <- cells, into: %{}, do: {cell,{m,owner}}

    # 已发布定义保证 slot 不重叠；按 canonical macro 汇集后，每格只更新一次世界索引和缓存。
    additions =
      for {owner, _, cells} <- nodes, {micro, material} <- cells, reduce: %{} do
        acc ->
          {cell, micro_slot} = Prefab.macro_slot(micro)

          Map.update(
            acc,
            cell,
            %{micro_slot => {material, owner}},
            &Map.put(&1, micro_slot, {material, owner})
          )
      end

    # 在当前权威提交中检查这次实际构造的占用，不另展开一份模板作预检。
    result =
      if Enum.all?(Map.keys(additions) ++ Map.keys(macro_additions), &valid_edit_coord?/1) do
        Enum.reduce_while(macro_additions, {:ok,state}, fn {cell,{m,owner}}, {:ok,s} ->
          case cell_value(s,0,cell) do
            {:ok,{0,_},s} when not is_map_key(s.refined,cell) ->
              s = %{s | macro_owners: Map.put(s.macro_owners,cell,owner),
                placed_by: if(actor,do: Map.put(s.placed_by,cell,actor.cid),else: Map.delete(s.placed_by,cell))}
              {:cont,{:ok,put_overlay(s,0,cell,{m,MmoContracts.Voxel.Skins.uniform(m)})}}
            {:ok,_,_} -> {:halt,{:error,:occupied}}
            {:error,reason,_} -> {:halt,{:error,reason}}
          end
        end)
        |> then(fn result -> Enum.reduce_while(additions, result, fn
          _, {:error,_}=error -> {:halt,error}
          {cell, added}, {:ok, s} ->
          slots = Map.get(s.refined, cell, %{})

          case cell_value(s, 0, cell) do
            {:ok, {0, _}, s} ->
              if Enum.any?(added, fn {slot, _} -> Map.has_key?(slots, slot) end) do
                {:halt, {:error, :occupied}}
              else
                s = %{s | refined: Map.put(s.refined, cell, Map.merge(slots, added))}
                {:cont, {:ok, put_overlay(s, 0, cell, {0, MmoContracts.Voxel.Skins.uniform(0)})}}
              end

            {:ok, _, _} ->
              {:halt, {:error, :occupied}}

            {:error, reason, _} ->
              {:halt, {:error, reason}}
          end
        end) end)
      else
        {:error, :invalid_coordinate}
      end

    case result do
      {:ok, next} ->
        instances =
          Enum.reduce(nodes, next.instances, fn {owner, instance, _}, acc ->
            Map.put(acc, owner, Map.put(instance,:placed_by,if(actor,do: actor.cid)))
          end)

        groups = Prefab.attachments(definition, anchor, orientation, before.seq + 1)
        slots = Enum.flat_map(groups, & &1.slots)

        if Enum.any?(slots, &Map.has_key?(next.attachments, &1)) do
          {:reply, {:error, :occupied}, before}
        else
          next =
            Enum.reduce(groups, %{next | instances: instances}, fn g, s ->
              id = max(s.attachment_serial, before.seq) + 1
              values = Map.new(g.slots, &{&1, {id, g.material}})

              %{
                s
                | attachment_serial: id,
                  attachments: Map.merge(s.attachments, values),
                  attachment_owners: Map.put(s.attachment_owners, id, {g.owner, g.slot})
              }
            end)

          prefab_settle(
            before,
            next,
            Enum.uniq(Map.keys(additions) ++ Map.keys(macro_additions) ++ changed ++ Attachments.macros(slots)),
            actor
          )
        end

      {:error, reason} ->
        {:reply, {:error, reason}, before}
    end
  end

  defp live_instance_ids(refined, instances, macro_owners) do
    owners =
      Enum.reduce(refined, %{}, fn {_, slots}, acc ->
        local = Enum.reduce(slots, %{}, fn {_, {_, id}}, owners -> Map.put(owners, id, true) end)
        Map.merge(acc, local)
      end)

    MmoContracts.Voxel.Refined.ancestors(instances, Enum.uniq(Map.keys(owners) ++ Map.values(macro_owners)))
  end

  defp prefab_reply(before, state, cells, settlement \\ %{}) do
    started = System.monotonic_time(:microsecond)
    removed = Map.keys(before.attachments) -- Map.keys(state.attachments)
    cells = Enum.uniq(cells ++ Attachments.macros(removed))

    state = %{
      state
      | seq: before.seq + 1,
        instances: Map.take(state.instances, live_instance_ids(state.refined, state.instances, state.macro_owners))
    }

    macro_changes = Enum.filter(cells, fn cell ->
      {:ok,old,_} = cell_value(before,0,cell)
      {:ok,new,_} = cell_value(state,0,cell)
      old != new
    end)
    macro_identity_changes = Enum.uniq(macro_changes ++
      Enum.filter(cells,&(Map.get(before.macro_owners,&1) != Map.get(state.macro_owners,&1))))

    # owner 更换仍发布完整 L0；只有实际 slot/材质变化才重建结构和碰撞。
    material_changes =
      Enum.filter(cells, fn cell ->
        old = Map.get(before.refined, cell, %{})
        new = Map.get(state.refined, cell, %{})

        cell in macro_changes or map_size(old) != map_size(new) or
          Enum.any?(old, fn {slot, {material, _}} ->
            case Map.get(new, slot) do
              {^material, _} -> false
              _ -> true
            end
          end)
      end)

    state = wake_liquid(state, cells)
    {state, attachment_keys, settlement} = prune_attachments(before, state, cells, settlement)

    with {:ok, state, settlement} <- prefab_payment(before, state, cells, settlement) do
      {phase_values,settlement} = Map.pop(settlement,:prefab_phase_values,%{})
      {phase_micro,settlement} = Map.pop(settlement,:prefab_phase_micro,[])
      {phase_preserved,settlement} = Map.pop(settlement,:prefab_phase_preserved,MapSet.new())
      {products,settlement} = Map.pop(settlement,:transform_products,%{})
      {carried_rows,settlement} = Map.pop(settlement,:property_states,[])
      # 同材质替换也可能把半格相态补满；碰撞必须消费最终有限数量。
      material_changes = Enum.uniq(material_changes ++ Enum.filter(cells,fn cell ->
        Map.get(before.liquid_units,cell) != Map.get(state.liquid_units,cell)
      end))
      {:ok, coarse, state, _} = reduce_batch(state, attachment_dirty(state, cells), 1, [], 0)
      {coarse_txn, state} = select_transaction(state, coarse)
      macro_dirty = Enum.map(macro_changes,&{0,&1})
      state = refresh_macro_payloads(before,state,macro_dirty)
      terrain_payloads = Map.merge(before.payloads,state.payloads)
      {state, structure_keys, structure_cells} = refresh_structure(state, cells)
      structure_done = System.monotonic_time(:microsecond)
      l0_keys = Enum.uniq(region_keys(Enum.map(cells, &{0, &1})) ++ attachment_keys)
      keys = l0_keys ++ structure_keys
      {entries, state} = region_afterimages(state, l0_keys, terrain_payloads,macro_dirty)
      region_count = length(entries)

      entries = entries ++ structure_entries(state, structure_cells)

      regions_done = System.monotonic_time(:microsecond)
      {state, metadata} = damage_geometry(before, state, cells, macro_identity_changes,phase_preserved)
      {state,phase_rows} = put_phase_values(state,phase_values)
      {state,micro_rows} = put_prefab_phase_micro(state,phase_micro)
      {state,product_rows} = put_transform_products(state,products)
      rows = metadata.property_states ++ phase_rows ++ micro_rows ++ product_rows
      # 调用方随带的行只补本笔几何未改写的键；几何移除与新身份行为准。
      written = MapSet.new(rows,&Damage.key/1)
      metadata = %{metadata | property_states:
        Enum.reject(carried_rows,&MapSet.member?(written,Damage.key(&1))) ++ rows}
      metadata = if state.thermal,do: Map.put(metadata,:thermal,state.thermal),else: metadata

      txn =
        Map.merge(%{coarse_txn | entries: entries ++ coarse_txn.entries}, metadata)
        |> Map.merge(settlement)
        |> ownership_metadata(before,state,cells)

      with {:ok, chunks} <- canonical_changes(before, state, Enum.map(material_changes, &{0, &1})),
           collision_done = System.monotonic_time(:microsecond),
           :ok <- append_log(state, txn) do
        log_done = System.monotonic_time(:microsecond)
        state = remember_entry(state, txn)
        fanout(state, txn)
        fanout_canonical(state, txn, chunks, keys, before)

        Logger.info(
          "voxel_prefab seq=#{state.seq} cells=#{length(cells)} regions=#{region_count} structure_cells=#{length(structure_cells)} " <>
            "state_structure_us=#{structure_done - started} regions_us=#{regions_done - structure_done} " <>
            "collision_us=#{collision_done - regions_done} log_us=#{log_done - collision_done} " <>
            "fanout_us=#{System.monotonic_time(:microsecond) - log_done}"
        )

        {:reply, {:ok, state.seq}, schedule_liquid(state)}
      else
        {:error, reason} -> {:reply, {:error, reason}, before}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, before}
    end
  end

  defp region_keys(cells), do: LogProjection.region_keys(cells)

  # 全局系统功能：结构增量与地形独立；空字节删除该格，消费者同时更新 core/ring。
  defp structure_entries(state, cells) do
    Enum.map(Enum.sort(cells), fn {level, cell} = key ->
      %{seq: state.seq, level: level, cell: cell, structure: Map.get(state.structure, key, <<>>)}
    end)
  end

  defp region_afterimages(state, keys, terrain_payloads, terrain_changes \\ []) do
    Enum.map_reduce(Enum.sort(Enum.uniq(keys)), state, fn {level, region} = key, s ->
      started = System.monotonic_time(:microsecond)
      s = %{cache_delete(s, key) | snapshots: MapSet.put(s.snapshots, key)}

      {bytes, s} =
        case Map.fetch(terrain_payloads, key) do
          {:ok, {prior, _}} ->
            details = with_refined(s, %Payload{level: level, region: region})

            overrides =
              for {^level, cell} <- terrain_changes,
                  local = Payload.local(region, cell),
                  Payload.in_span?(local),
                  into: %{},
                  do: {local, Map.fetch!(s.overlay, {level, cell})}

            bytes =
              if map_size(overrides) == 0 do
                Payload.replace_details(prior, details, s.seq, s.cv)
              else
                Payload.replace_cells_and_details(prior, overrides, details, s.seq, s.cv)
              end

            {:ok, header} = Codec.decode_payload_header(bytes)
            {bytes, cache_put(s, key, bytes, header)}

          :error ->
            if needs_source?(s, key), do: :ok = s.source.ensure(s.source_state, level, region)
            {:ok, bytes, _, s} = payload_bytes(s, level, region)
            {bytes, s}
        end

      Logger.info(
        "voxel_region_afterimage seq=#{s.seq} level=#{level} region=#{inspect(region)} reused=#{Map.has_key?(terrain_payloads, key)} elapsed_us=#{System.monotonic_time(:microsecond) - started}"
      )

      {region_entry(s.seq, bytes), s}
    end)
  end

  # 结构与地形分别派生；地形 early-stop 不得截断仍会变化的局部细化。
  defp refresh_structure(state, cells) do
    cells = attachment_dirty(state, cells) |> Enum.map(&elem(&1, 1))
    faces = Attachments.l1_faces(state.attachments, Enum.map(cells, &parent_of/1))

    {state, _, changed} =
      Enum.reduce(1..@max_level, {state, cells, []}, fn level, {s, dirty, changed} ->
        parents = dirty |> Enum.map(&parent_of/1) |> Enum.uniq()

        {s, changed} =
          Enum.reduce(parents, {s, changed}, fn {px, py, pz} = parent, {s, changed} ->
            children =
              for oct <- 0..7,
                  do:
                    {px * 2 + (oct &&& 1), py * 2 + (oct >>> 1 &&& 1), pz * 2 + (oct >>> 2 &&& 1)}

            has_structure =
              Enum.any?(children, fn cell ->
                if level == 1,
                  do: Map.has_key?(s.refined, cell),
                  else: Map.has_key?(s.structure, {level - 1, cell})
              end)

            {grid, s} =
              if has_structure do
                {values, s} =
                  Enum.map_reduce(children, s, fn cell, s ->
                    case if(level == 1,
                           do: Map.fetch(s.refined, cell),
                           else: Map.fetch(s.structure, {level - 1, cell})
                         ) do
                      {:ok, value} ->
                        {value, s}

                      :error ->
                        # cell_value 优先读已解码真值；冷 miss 由源 read 自行物化，不逐采样预检文件。
                        {:ok, {m, _}, s} = cell_value(s, level - 1, cell)
                        {m, s}
                    end
                  end)

                if level == 1 do
                  VoxelRegion.Structure.project_attachments(
                    VoxelRegion.Structure.from_canonical(values),
                    parent,
                    Map.get(faces, parent, []),
                    fn micro, world ->
                      {target, world} = target_at(micro, world)
                      {if(target, do: target.material, else: 0), world}
                    end,
                    s
                  )
                else
                  {VoxelRegion.Structure.reduce(values), s}
                end
              else
                {nil, s}
              end

            key = {level, parent}

            if grid == Map.get(s.structure, key) do
              {s, changed}
            else
              structure =
                if grid == nil,
                  do: Map.delete(s.structure, key),
                  else: Map.put(s.structure, key, grid)

              keys = region_keys([key])

              s =
                Enum.reduce(keys, %{s | structure: structure}, fn k, s ->
                  %{cache_delete(s, k) | snapshots: MapSet.put(s.snapshots, k)}
                end)

              {s, [key | changed]}
            end
          end)

        {s, parents, changed}
      end)

    {state, region_keys(changed), changed}
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

      %{
        state
        | lru: :gb_trees.insert({tick, key}, true, state.lru),
          lru_ticks: Map.put(state.lru_ticks, key, tick),
          tick: tick,
          lru_bytes: state.lru_bytes + byte_size(bytes)
      }
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

          %{
            state
            | payloads: payloads,
              lru: :gb_trees.delete({tick, key}, state.lru),
              lru_ticks: ticks,
              lru_bytes: state.lru_bytes - byte_size(bytes)
          }
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

  defp cache_clear(state),
    do: %{
      state
      | decoded: %{},
        payloads: %{},
        lru: :gb_trees.empty(),
        lru_ticks: %{},
        lru_bytes: 0,
        resident_bytes: 0
    }

  defp count(state, field),
    do: %{state | cache_stats: Map.update!(state.cache_stats, field, &(&1 + 1))}

  defp decoded(state, level, region) do
    key = {level, region}

    case Map.fetch(state.region_bases, key) do
      {:ok, payload} -> {:ok, payload, state}
      :error -> decoded_source(state, key)
    end
  end

  defp decoded_source(state, {level, region} = key) do
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
          {:ok, payload, state} ->
            {:ok, Payload.value(payload, Payload.local(region, cell)), state}

          {:error, :missing, state} ->
            {:error, :missing, state}

          {:error, reason, state} ->
            {:error, reason, state}
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
    if Map.get(state.overlay, {level, cell}) == value do
      state
    else
      regions = region_keys([{level, cell}])

      Enum.reduce(
        regions,
        %{state | overlay: Map.put(state.overlay, {level, cell}, value)},
        fn key, state ->
          %{
            cache_delete(state, key)
            | overlay_regions:
                Map.update(state.overlay_regions, key, MapSet.new([cell]), &MapSet.put(&1, cell))
          }
        end
      )
    end
  end

  # ---- 日志

  defp append_log(%{log: {backend, handle}} = state, txn),
    do: backend.append(handle, attachment_metadata(state, Map.drop(txn, [:liquid_falls, :casts])))

  # canonical 附件归属与ID分配水位随同一日志／检查点持久化；网络槽副本仍只需要全局ID。
  defp attachment_metadata(state, txn),
    do:
      Map.merge(txn, %{
        attachment_serial: state.attachment_serial,
        attachment_owners: state.attachment_owners,
        prefab_instances: state.instances,
        material_units_per_micro: state.material_units_per_micro,
        liquid_active: Enum.to_list(state.liquid_active)
      })

  # 事务正文唯一持有；区域索引只由成功提交、重放或压实的同一条目派生。
  defp remember_entry(state, txn) do
    # 实时落体帧与待施放记录只随本次广播，不进日志、检查点与回放尾。
    txn = Map.drop(txn, [:liquid_falls, :casts])
    state = %{state | entries: Map.put(state.entries, txn.seq, txn),
      entry_regions: LogProjection.index(state.entry_regions, txn)}
    # 单个完整检查点不再生长；只有新历史出现时安排一次维护。
    if map_size(state.entries) > 1 and state.checkpoint_timer == nil,
      do: %{state | checkpoint_timer: :erlang.start_timer(60_000, self(), :checkpoint)},
      else: state
  end

  defp replay_log(%{log: {backend, handle}} = state) do
    Enum.reduce(backend.replay(handle), state, fn txn, s ->
      s = replay_entry(s, txn) |> replay_damage(txn)
      remember_entry(%{s | seq: max(s.seq, txn.seq)}, txn)
    end)
  end

  # ---- 订阅

  defp fanout(state, entry) do
    Enum.each(state.subs, fn {pid, filter} -> send_filtered(pid, entry, filter) end)
  end

  # 采掘基准只属于服务端持久状态，对外属性观察不携带该内部字段。
  defp public_property(row), do: Map.delete(row, :pick_baseline_hp)
  defp public_properties(%{property_states: rows} = value),
    do: %{value | property_states: Enum.map(rows, &public_property/1)}
  defp public_properties(value), do: value

  # serve 与副本共用物化字节；快照头只推进到当前事务前缀。
  defp canonical_region_bytes(state, coord) do
    with {:ok, bytes, _, state} <- payload_bytes(state, 0, coord) do
      {:ok, Codec.stamp_payload_seq(bytes, state.seq), state}
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

    result =
      Enum.reduce_while(groups, {:ok, [], state}, fn {region, coords}, {:ok, chunks, s} ->
        case decoded(s, 0, region) do
          {:ok, p, s} ->
            value_at = fn cell ->
              material =
                case Map.fetch(s.overlay, {0, cell}) do
                  {:ok, {material, _}} -> material
                  :error -> Payload.material(p, Payload.local(region, cell))
                end

              {material, CollisionSource.phase_slots(material,Map.get(s.refined,cell,%{}),Map.get(s.liquid_units,cell),liquid_capacity(s))}
            end

            {:cont, {:ok, Enum.map(coords, &CollisionSource.capture(&1, value_at)) ++ chunks, s}}

          _ ->
            {:halt, {:error, :canonical_incomplete}}
        end
      end)

    case result do
      {:ok, chunks, _} -> {:ok, Enum.sort_by(chunks, & &1.coord)}
      error -> error
    end
  end

  defp capture_canonical_snapshot(state, {l0_min, l0_max} = box, include_chunks) do
    started = System.monotonic_time(:microsecond)

    with {:ok, regions, payloads, state} <- canonical_regions(state, CollisionSource.regions(box)) do
      regions_done = System.monotonic_time(:microsecond)

      chunks =
        if include_chunks,
          do:
            payloads
            |> Enum.flat_map(fn {coord, payload} ->
              Enum.map(CollisionSource.chunk_coords(coord), &CollisionSource.capture(payload, &1, liquid_capacity(state)))
            end)
            |> Enum.sort_by(& &1.coord),
          else: []

      snapshot = %CanonicalSnapshot{
        content_version: state.cv,
        transaction_seq: state.seq,
        l0_min: l0_min,
        l0_max_exclusive: l0_max,
        regions: regions,
        chunks: chunks
      }

      chunks_done = System.monotonic_time(:microsecond)
      snapshot = Map.merge(snapshot, property_snapshot(state, box))

      Logger.info(
        "voxel_window_prepare seq=#{state.seq} box=#{inspect(box)} regions_us=#{regions_done - started} collision_us=#{chunks_done - regions_done} properties_us=#{System.monotonic_time(:microsecond) - chunks_done}"
      )

      Logger.info(
        "voxel_region canonical_snapshot seq=#{state.seq} regions=#{length(regions)} chunks=#{length(chunks)} occupancy_bytes=#{Enum.sum(Enum.map(chunks, &byte_size(&1.cells)))} payload_bytes=#{Enum.sum(Enum.map(regions, &byte_size(elem(&1, 1))))} elapsed_us=#{System.monotonic_time(:microsecond) - started}"
      )

      {:ok, snapshot, state}
    end
  end

  defp balance_projection(balances, characters) do
    for {{cid, material}, units} <- Enum.sort(balances), cid in characters,
      do: %{character: cid, material: material, units: units}
  end

  defp thermal_accounting(nil, _in_box), do: nil
  defp thermal_accounting(thermal, in_box) do
    ledger = Map.take(thermal, [:active, :elapsed_s, :supplied_j, :environment_j,
      :removed_j, :discarded_source_j, :combustion_j, :combustion_removed_j,
      :fuel_initialized_j, :discarded_fuel_j, :circuit_supplied_j, :circuit_charged_j, :circuit_thermoelectric_j,
      :circuit_light_j, :circuit_removed_j, :parameter_rebase_j, :fuel_rebase_j,
      :phase_paid_j, :phase_unused_j, :phase_supplied_j, :phase_authored_units, :phase_authored_energy_j,
      :transform_j, :transform_units, :transform_reductant_fuel_j,
      :caster_drawn_j, :draw_loss_j, :cast_waste_j, :spell_heat_j,
      :semblance_created_j, :semblance_exchanged_j, :semblance_light_j, :semblance_released_j, :body_exchange_j])
    sources = for {cell, source} <- thermal.sources, in_box.(cell), into: %{},
      do: {cell, Map.take(source, [:remaining_j, :power_w])}
    ledger = Map.put(ledger, :sources, sources)

    # 拟态账的剩余项是整个世界的快照：显热 ΣC(T − T_amb) 与其余存量（飞行动能 + 发光余量）；只在出现过拟态的世界里有。
    # 闭合：semblance_created_j = exchanged + light + released + thermal + stored。
    case thermal do
      %{semblances: semblances} ->
        live = Map.values(semblances)
        ambient = thermal.config["ambient_kelvin"]
        thermal_j = Enum.sum(Enum.map(live, &Magic.Semblance.thermal_j(&1, ambient))) * 1.0
        stored_j = Enum.sum(Enum.map(live, &Magic.Semblance.stored_j(&1, ambient))) * 1.0
        Map.merge(ledger, %{semblance_thermal_j: thermal_j, semblance_stored_j: stored_j - thermal_j})

      _ ->
        ledger
    end
  end

  # 全局系统功能：占用与属性在同一 GenServer 提交点采样。
  # 有气候区时附上同一份区表（Scene 的身体按所在格取空气温度，VoxelRegion.Climate.air_k/2）；没有时不加键。
  defp property_context(state) do
    context = %{
      hp_enabled: state.properties != nil,
      digest: if(state.properties, do: state.properties.digest, else: <<0::256>>),
      thermal_enabled: state.thermal != nil,
      ambient_kelvin: if(state.thermal, do: state.thermal.config["ambient_kelvin"], else: 0.0)
    }

    context =
      if state.thermal && VoxelRegion.Climate.zoned?(state.thermal.config),
        do: Map.put(context, :climate_zones, state.thermal.config["climate_zones"]),
        else: context

    # 身体闭环 H1：愈合时间压缩系数随热环境发布（身体只在有热环境时推进），原样带给 Scene；没发布时不加键（Player 入场显式失败）。
    case state.thermal && state.thermal.config["heal_time_compression"] do
      k when is_number(k) -> Map.put(context, :heal_time_compression, k)
      _ -> context
    end
  end

  defp component_observations(%{properties: nil}, _box), do: []

  defp component_observations(state, box) do
    # Request-local projection: each exact leaf's full geometry is scanned once.
    # The window selects representatives, not which slots contribute to leaf HP.
    owners = Enum.reduce(state.refined, %{}, fn {cell, slots}, owners ->
      visible = box == nil or VoxelRegion.PropertyObservation.contains?(cell, box)
      Enum.reduce(slots, owners, fn {slot, {material, {birth, _} = owner}}, acc ->
        target = if visible, do: %{micro: Prefab.micro_coord(cell, slot), granularity: 2,
          incarnation: birth, owner: owner, material: material}
        hp = Damage.max_hp(Map.fetch!(state.properties.materials, material), 1)
        case Map.fetch(acc, owner) do
          :error -> Map.put(acc, owner, {target, MapSet.new([cell]), hp})
          {:ok, {previous, cells, total}} ->
            Map.put(acc, owner, {if(visible, do: target, else: previous), MapSet.put(cells, cell), total + hp})
        end
      end)
    end)

    for {_, {target, cells, hp}} <- owners, target != nil do
      property_state(state, target, hp)
      |> Map.put(:observation_cells, MapSet.to_list(cells))
    end
  end

  defp property_snapshot(state, box) do
    macros =
      for {_, t} <- state.damage,
          t.granularity in [0, 1, 4],
          VoxelRegion.PropertyObservation.relevant?(t, box),
          do: %{t | seq: state.seq, request_id: 0}

    macros = (macros ++ owned_macro_observations(state,box)) |> Map.new(&{Damage.key(&1),&1}) |> Map.values()
    %{
      property_states:
        macros ++ component_observations(state, box) ++ attachment_observations(state, box),
      property_context: property_context(state),
      epochs: state.epochs,
      protection: state.protection.regions,
      semblances: semblances(state),
      casts: Map.new(state.pending_casts, fn {cid, pending} -> {cid, pending.record} end)
    }
    |> public_properties()
    |> VoxelRegion.PropertyObservation.project(box)
  end

  defp owned_macro_observations(%{properties: nil}, _box), do: []
  defp owned_macro_observations(state, box) do
    for {cell,_} <- state.macro_owners,
        micro = Prefab.micro_coord(cell,0),
        box == nil or VoxelRegion.PropertyObservation.relevant?(%{micro: micro,granularity: 0},box) do
      {target,_} = target_at(micro,state)
      property_state(state,target)
    end
  end

  defp property_transaction(before, state, txn) do
    # 几何变化发布统一叶子汇总；删除保留提交前实际占用范围。
    changed_owners =
      if Map.get(txn, :entries, []) == [],
        do: MapSet.new(),
        else:
          MapSet.new(
            for cell <- Enum.uniq(Map.keys(before.refined) ++ Map.keys(state.refined)),
                Map.get(before.refined, cell) != Map.get(state.refined, cell),
                {_, {_, owner}} <-
                  Map.to_list(Map.get(before.refined, cell, %{})) ++
                    Map.to_list(Map.get(state.refined, cell, %{})),
                do: owner
          )

    fresh =
      if MapSet.size(changed_owners) == 0,
        do: [],
        else:
          Enum.filter(
            component_observations(state, nil),
            &MapSet.member?(changed_owners, &1.owner)
          )

    removed =
      if MapSet.size(changed_owners) == 0,
        do: [],
        else:
          component_observations(before, nil)
          |> Enum.filter(
            &(MapSet.member?(changed_owners, &1.owner) and
                not Map.has_key?(state.instances, &1.owner))
          )
          |> Enum.map(&%{&1 | seq: state.seq, hp: 0.0, flags: 1, request_id: 0})

    # 纯属性提交由唯一目标集合产生；只有几何变化合并三种来源时才需要按身份去重。
    rows =
      if MapSet.size(changed_owners) == 0,
        do: Map.get(txn, :property_states, []),
        else:
          (removed ++ Map.get(txn, :property_states, []) ++ fresh)
          |> Map.new(&{Damage.key(&1), &1})
          |> Map.values()

    rows =
      if before.attachments == state.attachments,
        do: rows,
        else:
          (rows ++ attachment_observations(state, nil))
          |> Map.new(&{Damage.key(&1), &1})
          |> Map.values()

    changed_macros = Enum.uniq(Map.keys(before.macro_owners) ++ Map.keys(state.macro_owners))
      |> Enum.filter(fn cell -> Map.get(before.macro_owners,cell) != Map.get(state.macro_owners,cell) or
        Map.get(before.epochs,cell) != Map.get(state.epochs,cell) end)
      |> MapSet.new()
    rows = if MapSet.size(changed_macros) == 0 do
      rows
    else
      removed = owned_macro_observations(before,nil)
        |> Enum.filter(&MapSet.member?(changed_macros,Damage.macro(&1)))
        |> Enum.map(&%{&1 | seq: state.seq,hp: 0.0,flags: 1,request_id: 0})
      fresh = owned_macro_observations(state,nil)
        |> Enum.filter(&MapSet.member?(changed_macros,Damage.macro(&1)))
      (removed ++ rows ++ fresh) |> Map.new(&{Damage.key(&1),&1}) |> Map.values()
    end

    rows =
      Enum.map(rows, fn
        %{granularity: 3} = row ->
          cells =
            Attachments.macros(
              attachment_slots(before, row.incarnation) ++
                attachment_slots(state, row.incarnation)
            )

          Map.put(row, :observation_cells, cells)

        %{granularity: 2} = row ->
          cells =
            micro_owner_cells(before, MapSet.new([row.owner])) ++
              micro_owner_cells(state, MapSet.new([row.owner]))

          Map.put(row, :observation_cells, Enum.uniq(cells))

        row ->
          row
      end)

    Map.merge(txn, %{property_states: rows, property_context: property_context(state)})
    |> public_properties()
  end

  # Capture both versions while the pre-commit state still exists. Never sample after fanout.
  defp canonical_changes(%{canonical_subs: subs, replica_subs: replicas}, _after, _changed)
       when map_size(subs) == 0 and map_size(replicas) == 0, do: {:ok, []}

  defp canonical_changes(before, after_state, changed) do
    started = System.monotonic_time(:microsecond)
    boxes = (Map.values(before.canonical_subs) ++ Map.values(before.replica_subs)) |> Enum.uniq()

    coords =
      changed
      |> Enum.map(fn {0, cell} -> CollisionSource.chunk_coord(cell) end)
      |> Enum.uniq()
      |> Enum.filter(fn coord -> Enum.any?(boxes, &CollisionSource.in_box?(coord, &1)) end)
      |> Enum.sort()

    with {:ok, old} <- canonical_chunks(before, coords),
         {:ok, new} <- canonical_chunks(after_state, coords) do
      chunks =
        Enum.zip(old, new)
        |> Enum.flat_map(fn {a, b} -> if a.cells == b.cells, do: [], else: [b] end)

      Logger.info(
        "voxel_region canonical_delta seq=#{after_state.seq} chunks=#{length(chunks)} occupancy_bytes=#{Enum.sum(Enum.map(chunks, &byte_size(&1.cells)))} capture_us=#{System.monotonic_time(:microsecond) - started}"
      )

      {:ok, chunks}
    end
  end

  defp fanout_canonical(
         %{canonical_subs: subs, replica_subs: replicas},
         _txn,
         _chunks,
         _keys,
         _before
       )
       when map_size(subs) == 0 and map_size(replicas) == 0, do: :ok

  defp fanout_canonical(state, %{coord: _} = entry, chunks, keys, before) do
    fanout_canonical(
      state,
      Map.merge(
        %{seq: entry.seq, entries: [%{entry | coarse: []}], coarse: entry.coarse},
        Map.take(entry, [:property_states, :epochs])
      ),
      chunks,
      keys,
      before
    )
  end

  defp fanout_canonical(state, transaction, chunks, keys, before) do
    transaction = property_transaction(before, state, transaction)

    Enum.each(state.canonical_subs, fn {pid, box} ->
      # 只读验收证据：真实 canonical 订阅的投影前流动帧，保留排他上界。
      if falls = Map.get(transaction, :liquid_falls) do
        {lo, hi} = box
        Logger.info(Jason.encode!(%{event: "liquid_projection", path: "canonical", stream_pid: inspect(pid),
          seq: transaction.seq, material: falls.material, box_min: Tuple.to_list(lo),
          box_max: Tuple.to_list(hi),
          source: Enum.map(falls.transfers, fn {{x,y,z},units} -> [x,y,z,units] end)}))
      end
      delta = %CanonicalDelta{
        transaction_seq: state.seq,
        transaction: VoxelRegion.PropertyObservation.project(transaction, box),
        chunks: Enum.filter(chunks, &CollisionSource.in_box?(&1.coord, box))
      }

      send(pid, {:canonical_delta, delta})
    end)

    # 两种提交入口都按实际变动格提供区域集合；条目的压缩形式不决定更新范围。
    wanted =
      state.replica_subs
      |> Map.values()
      |> Enum.flat_map(&CollisionSource.regions/1)
      |> MapSet.new()

    afterimages =
      Enum.reduce(transaction.entries, %{}, fn
        %{payload: bytes}, ready ->
          {:ok, h} = Codec.decode_payload_header(bytes)
          if h.level == 0, do: Map.put(ready, h.region, bytes), else: ready

        %{coord: _}, ready ->
          ready

        %{structure: _}, ready ->
          ready
      end)

    coords = for {0, region} <- keys, MapSet.member?(wanted, region), do: region
    coords = coords |> Enum.uniq() |> Enum.sort()
    # Replica 只消费字节；需要占用投影的快照/碰撞调用方才解码。
    {regions, _} =
      Enum.map_reduce(coords, state, fn coord, s ->
        case Map.fetch(afterimages, coord) do
          {:ok, bytes} ->
            {{coord, bytes}, s}

          :error ->
            {:ok, bytes, s} = canonical_region_bytes(s, coord)
            {{coord, bytes}, s}
        end
      end)

    Enum.each(state.replica_subs, fn {pid, box} ->
      wanted = MapSet.new(CollisionSource.regions(box))

      delta = %CanonicalDelta{
        transaction_seq: state.seq,
        transaction: VoxelRegion.PropertyObservation.project(transaction, box),
        chunks: Enum.filter(chunks, &CollisionSource.in_box?(&1.coord, box))
      }

      send(
        pid,
        {:canonical_replica_delta, delta,
         Enum.filter(regions, &MapSet.member?(wanted, elem(&1, 0)))}
      )
    end)
  end

  defp send_filtered(pid, entry, filter) do
    if message = VoxelRegion.LogProjection.message(entry, filter), do: send(pid, message)
  end

  defp replay_entry(state, %{entries: entries, coarse: coarse}) do
    state = Enum.reduce(entries, state, &replay_entry(&2, &1))

    Enum.reduce(coarse, state, fn e, s ->
      put_overlay(s, e.level, e.cell, {e.material, e.skins})
    end)
  end

  defp replay_entry(state, %{payload: bytes}) do
    {:ok, p} = Payload.decode(bytes)

    state =
      if p.level == 0 do
        {ox, oy, oz} = Payload.origin(p.region)

        core =
          for {index, slots} <- p.refined,
              x = rem(index, 66),
              y = rem(div(index, 66), 66),
              z = div(index, 66 * 66),
              x in 1..64 and y in 1..64 and z in 1..64,
              into: %{},
              do: {{ox + x, oy + y, oz + z}, slots}

        refined =
          state.refined
          |> Map.reject(fn {cell, _} -> region_of(cell) == p.region end)
          |> Map.merge(core)

        instances = Map.merge(state.instances, p.instances)
        ids = live_instance_ids(refined, instances, state.macro_owners)

        attachments =
          state.attachments
          |> Map.reject(fn {slot, _} -> Attachments.region(slot) == p.region end)
          |> Map.merge(
            Map.filter(p.attachments, fn {slot, _} -> Attachments.region(slot) == p.region end)
          )

        liquid_core = for {index, units} <- p.liquid_units,
          x = rem(index,66), y = rem(div(index,66),66), z = div(index,66*66),
          x in 1..64 and y in 1..64 and z in 1..64, into: %{},
          do: {{ox+x,oy+y,oz+z}, units}
        liquid_units = state.liquid_units
          |> Map.reject(fn {cell,_} -> region_of(cell) == p.region end)
          |> Map.merge(liquid_core)
        %{state | liquid_units: liquid_units, attachments: attachments, refined: refined, instances: Map.take(instances, ids)}
      else
        state
      end

    rebase_region(state, p)
  end

  defp replay_entry(state, %{structure: grid, level: level, cell: cell}) do
    key = {level, cell}

    structure =
      if grid == <<>>,
        do: Map.delete(state.structure, key),
        else: Map.put(state.structure, key, grid)

    Enum.reduce(region_keys([key]), %{state | structure: structure}, fn region, s ->
      %{cache_delete(s, region) | snapshots: MapSet.put(s.snapshots, region)}
    end)
  end

  defp replay_entry(state, entry) do
    state =
      put_overlay(
        state,
        0,
        entry.coord,
        {entry.material, MmoContracts.Voxel.Skins.uniform(entry.material)}
      )

    Enum.reduce(entry.coarse, state, fn e, s ->
      put_overlay(s, e.level, e.cell, {e.material, e.skins})
    end)
  end

  defp rebase_region(state, p) do
    key = {p.level, p.region}

    # 检查点已包含这个 core 的全部真值；移除已吸收的稀疏编辑及其邻区索引。
    core_cells =
      state.overlay_regions
      |> Map.get(key, MapSet.new())
      |> Enum.filter(&(region_of(&1) == p.region))

    overlay = Map.drop(state.overlay, Enum.map(core_cells, &{p.level, &1}))
    {rx, ry, rz} = p.region

    neighbors =
      for x <- (rx - 1)..(rx + 1),
          y <- (ry - 1)..(ry + 1),
          z <- (rz - 1)..(rz + 1),
          do: {p.level, {x, y, z}}

    regions =
      Enum.reduce(Map.take(state.overlay_regions, neighbors), state.overlay_regions, fn {k, cells},
                                                                                        index ->
        Map.put(index, k, MapSet.filter(cells, &(region_of(&1) != p.region)))
      end)

    # 当前后缀由世界的 refined/instances/structure 唯一持有，基底只保留地形。
    p = %{p | refined: %{}, instances: %{}, structure: %{}, attachments: %{}, liquid_units: %{}}

    %{
      cache_clear(state)
      | region_bases: Map.put(state.region_bases, key, p),
        snapshots: MapSet.put(state.snapshots, key),
        overlay: overlay,
        overlay_regions: regions
    }
  end

  defp apply_batch(
         state,
         edits,
         legacy \\ false,
         settlement \\ %{},
         removed_owners \\ MapSet.new(),
         removed_attachments \\ MapSet.new()
       ) do
    before = state
    started = System.monotonic_time(:microsecond)
    {phase_values, settlement} = Map.pop(settlement, :phase_values, %{})
    {liquid_changes, settlement} = Map.pop(settlement, :liquid_changes, %{})
    {liquid_wake, settlement} = Map.pop(settlement, :liquid_wake, true)
    {placed, settlement} = Map.pop(settlement, :placed, %{})

    liquid_dirty = Enum.map(Map.keys(liquid_changes), &{0,&1})
    state = %{state | liquid_units: Liquid.apply_changes(state.liquid_units, liquid_changes)}

    removed_slots =
      for {slot, {id, _}} <- state.attachments, MapSet.member?(removed_attachments, id), do: slot

    state = %{state | attachments: Map.drop(state.attachments, removed_slots)}

    removed_cells =
      if MapSet.size(removed_owners) == 0, do: [], else: micro_owner_cells(state, removed_owners)

    state =
      if removed_cells == [],
        do: state,
        else:
          clear_subtree(state, removed_owners, removed_cells)
          |> then(fn s ->
            %{s | instances: Map.take(s.instances, live_instance_ids(s.refined, s.instances, s.macro_owners))}
          end)

    # 地面花草失去支撑即消失：下方格变成不挡移动的材质（挖空、液体、花草）时，同一事务里清掉上面的花草。
    with {:ok,unsupported,state} <-
      Enum.reduce_while(edits, {:ok,[],state}, fn {{x, y, z}, m}, {:ok,found,s} ->
        above = {x, y + 1, z}

        if MmoContracts.VoxelMaterialCatalog.blocks_movement?(m) or List.keymember?(edits, above, 0) or is_map_key(s.refined, above) do
          {:cont,{:ok,found,s}}
        else
          case cell_value(s,0,above) do
            {:ok,{top,_},s} ->
              {:cont,{:ok,if(MmoContracts.VoxelMaterialCatalog.flora?(top),do: [{above,0}|found],else: found),s}}
            {:error,:missing,_} -> {:halt,{:error,:missing_region}}
          end
        end
      end) do

    edits = edits ++ unsupported
    legacy = legacy and unsupported == []

    # 概率掉落：这一笔里被销毁 / 替换 / 失去支撑的、带掉落表的格，按表发给造成它的人（攻击者或放置者）；
    # 没有操作者（作者入口、液体、热）就直接消失。骰子由 (世界, 事务序号, 格, 表项) 决定，重放同一笔结果相同。
    drop_cid = settlement[:recovery_cid] || (placed |> Map.values() |> List.first())

    {state, settlement} =
      if drop_cid == nil do
        {state, settlement}
      else
        Enum.reduce(edits, {state, settlement}, fn {cell, m}, {s, paid} ->
          with false <- is_map_key(s.refined, cell),
               {:ok, {old, _}, s} when old != m <- cell_value(s, 0, cell),
               [_ | _] = table <- drop_table(s, old) do
            table
            |> Enum.with_index()
            |> Enum.filter(fn {d, i} -> drop_roll(s, cell, i) < d["probability"] end)
            |> Enum.reduce({s, paid}, fn {d, _}, {s, paid} ->
              {s, granted} = settle_material(s, drop_cid, d["material_id"], d["units"])
              {s, Map.update(paid, :material_balances, granted.material_balances, &Map.merge(&1, granted.material_balances))}
            end)
          else
            {:ok, _, s} -> {s, paid}
            _ -> {s, paid}
          end
        end)
      end

    result =
      Enum.reduce_while(Map.new(edits), {Enum.map(removed_cells, &{0, &1}), state}, fn {cell, m},
                                                                                       {changed,
                                                                                        s} ->
        case if(Map.has_key?(s.refined, cell),
               do: {:error, :refined_cell, s},
               else: cell_value(s, 0, cell)
             ) do
          {:ok, {old, _}, s} when old == m ->
            {:cont, {changed, s}}

          {:ok, _, s} ->
            s = %{s | macro_owners: Map.delete(s.macro_owners,cell),
              placed_by: merge_placed(s.placed_by,%{cell => Map.get(placed,cell)})}
            {:cont,
             {[{0, cell} | changed],
              put_overlay(s, 0, cell, {m, MmoContracts.Voxel.Skins.uniform(m)})}}

          {:error, :missing, _} ->
            {:halt, {:error, :missing_region}}

          {:error, reason, _} ->
            {:halt, {:error, reason}}
        end
      end)

    case result do
      {:error, reason} ->
        {:error, reason}

      {[], state} when map_size(liquid_changes) == 0 ->
        cond do
          removed_slots != [] -> commit_attachment(before, state, removed_slots, settlement)
          Map.has_key?(settlement, :liquid_falls) ->
            next = %{state | seq: state.seq + 1}
            txn = %{seq: next.seq, entries: [], coarse: [], liquid_falls: settlement.liquid_falls}
            with :ok <- append_log(next, txn) do
              next = remember_entry(next, txn)
              fanout(next, txn)
              fanout_canonical(next, txn, [], [], before)
              {:ok, next}
            end
          true -> {:ok, state}
        end

      {geometry_changed, state} ->
        state = %{state | instances: Map.take(state.instances,live_instance_ids(state.refined,state.instances,state.macro_owners))}
        # 换了材料却没有随笔数量的格（挖掉、热毁、作者覆盖）不再是那份有限量：删除其数量记录（R8-07）。
        stale = for {0, cell} <- geometry_changed, not Map.has_key?(liquid_changes, cell),
          Map.has_key?(state.liquid_units, cell), do: cell
        state = %{state | liquid_units: Map.drop(state.liquid_units, stale)}
        liquid_dirty = liquid_dirty ++ Enum.map(stale, &{0, &1})
        changed = Enum.uniq(geometry_changed ++ liquid_dirty)
        state = if liquid_wake, do: wake_liquid(state, Enum.map(changed, &elem(&1,1))), else: state
        # Quantity-only changes require a new seq and full owner/ring afterimages,
        # but never a fresh solid identity, HP invalidation or collision edit.
        case reduce_batch(
               state,
               attachment_dirty(
                 state,
                 Enum.map(geometry_changed, &elem(&1, 1)) ++ Attachments.macros(removed_slots)
               ),
               1,
               geometry_changed,
               0
             ) do
          {:error, reason} ->
            {:error, reason}

          {:ok, all, state, visits} ->
            reduced = System.monotonic_time(:microsecond)

            {state, attachment_keys, settlement} =
              prune_attachments(before, state, Enum.map(geometry_changed, &elem(&1, 1)), settlement)

            state = %{state | seq: state.seq + 1}
            state = refresh_macro_payloads(before, state, geometry_changed)
            cached = System.monotonic_time(:microsecond)
            terrain_payloads = Map.merge(before.payloads, state.payloads)

            {state, _structure_keys, structure_cells} =
              refresh_structure(
                state,
                Enum.uniq(Enum.map(geometry_changed, &elem(&1, 1)) ++ Attachments.macros(removed_slots))
              )

            afterimage_keys =
              Enum.uniq(
                attachment_keys ++
                  region_keys(Enum.map(removed_cells, &{0, &1})) ++ region_keys(liquid_dirty)
              )

            structured = System.monotonic_time(:microsecond)
            legacy = legacy and afterimage_keys == [] and structure_cells == []

            {txn, state} =
              if legacy do
                [{coord, material}] = edits

                coarse =
                  for {level, cell} <- Enum.sort(all), level > 0 do
                    {m, skins} = Map.fetch!(state.overlay, {level, cell})
                    %{level: level, cell: cell, material: m, skins: skins}
                  end

                {%{seq: state.seq, coord: coord, material: material, coarse: coarse}, state}
              else
                # afterimage 已包含该 core 的地形与结构；选择前排除，避免完整编码两次。
                covered = MapSet.new(afterimage_keys)

                sparse =
                  Enum.reject(all, fn {level, cell} ->
                    MapSet.member?(covered, {level, region_of(cell)})
                  end)

                select_transaction(state, sparse)
              end

            {txn, state} =
              if legacy do
                {txn, state}
              else
                {afterimages, state} =
                  region_afterimages(state, afterimage_keys, terrain_payloads, all)

                {%{txn | entries: txn.entries ++ afterimages ++ structure_entries(state, structure_cells)}, state}
              end

            # 随笔搬运值覆盖的有限宏格：其热与燃料已随数量搬走或结算，清空时不再记为移除。
            carried = for {key, %{granularity: 0} = t} <- before.damage,
              Map.has_key?(phase_values, Damage.macro(t)), into: MapSet.new(), do: key

            {state, metadata} =
              damage_geometry(before, state, Enum.map(geometry_changed, &elem(&1, 1)), Enum.map(geometry_changed, &elem(&1, 1)), carried)

            {state, phase_rows} = put_phase_values(state, phase_values)
            metadata = Map.update!(metadata, :property_states, &(&1 ++ phase_rows))
            if_phase_dirty = Map.keys(phase_values) |> Enum.flat_map(&[&1 | VoxelRegion.Thermal.neighbors(&1)])
            state = drop_thermal_geometry(state, if_phase_dirty)
            metadata = if state.thermal, do: Map.put(metadata,:thermal,state.thermal), else: metadata
            imaged = System.monotonic_time(:microsecond)
            txn = Map.merge(txn, metadata) |> Map.merge(settlement)
              |> ownership_metadata(before,state,Enum.map(geometry_changed,&elem(&1,1)))

            txn =
              if Map.has_key?(settlement, :property_states),
                do:
                  Map.put(
                    txn,
                    :property_states,
                    Map.new(
                      settlement.property_states ++ metadata.property_states,
                      &{Damage.key(&1), &1}
                    )
                    |> Map.values()
                  ),
                else: txn

            with {:ok, collision_chunks} <- canonical_changes(before, state, Enum.uniq(geometry_changed ++
                   Enum.filter(liquid_dirty,fn {0,c}->
                     {:ok,{m,_},_}=cell_value(state,0,c); MmoContracts.VoxelMaterialCatalog.blocks_movement?(m)
                   end))),
                 collided = System.monotonic_time(:microsecond),
                 :ok <- append_log(state, txn) do
              appended = System.monotonic_time(:microsecond)
              state = remember_entry(state, txn)
              fanout(state, txn)

              fanout_canonical(
                state,
                txn,
                collision_chunks,
                region_keys(changed) ++ attachment_keys,
                before
              )

              Logger.info(
                "voxel_macro_stages seq=#{state.seq} reduce_us=#{reduced - started} l0_cache_us=#{cached - reduced} structure_us=#{structured - cached} regions_us=#{imaged - structured} collision_us=#{collided - imaged} log_us=#{appended - collided} fanout_us=#{System.monotonic_time(:microsecond) - appended}"
              )

              region_count = Enum.count(Map.get(txn, :entries, []), &Map.has_key?(&1, :payload))

              Logger.info(
                "voxel_region transaction seq=#{state.seq} canonical=#{length(changed)} reduced=#{visits} changed=#{length(all)} regions=#{region_count} structure_cells=#{length(structure_cells)} bytes=#{IO.iodata_length(if legacy, do: Codec.encode_entry(txn), else: Codec.encode_transaction(txn))} elapsed_us=#{System.monotonic_time(:microsecond) - started}"
              )

              {:ok, schedule_liquid(state)}
            end
        end
    end
    end
  end

  defp needs_source?(state, key),
    do: not Map.has_key?(state.region_bases, key) and not Map.has_key?(state.decoded, key)

  # 宏格编辑已排除refined cell，故L0细节后缀未变；仅更新已有热缓存，冷缺失仍由真值物化。
  defp refresh_macro_payloads(before, state, changed) do
    Enum.reduce(Enum.uniq(region_keys(changed)), state, fn {0, region} = key, s ->
      case Map.fetch(before.payloads, key) do
        {:ok, {prior, _}} ->
          materials =
            for {0, cell} <- changed,
                local = Payload.local(region, cell),
                Payload.in_span?(local),
                into: %{},
                do: {local, elem(Map.fetch!(s.overlay, {0, cell}), 0)}

          bytes = Payload.replace_uniform_cells(prior, materials, s.seq, s.cv)
          {:ok, header} = Codec.decode_payload_header(bytes)
          cache_put(s, key, bytes, header)

        :error ->
          s
      end
    end)
  end

  defp reduce_batch(state, [], _level, all, visits), do: {:ok, all, state, visits}

  defp reduce_batch(state, _dirty, level, all, visits) when level > @max_level,
    do: {:ok, all, state, visits}

  defp reduce_batch(state, dirty, level, all, visits) do
    parents = dirty |> Enum.map(fn {_, c} -> parent_of(c) end) |> Enum.uniq()
    faces = if level == 1, do: Attachments.l1_faces(state.attachments, parents), else: %{}

    result =
      Enum.reduce_while(parents, {[], state}, fn parent, {changed, s} ->
        case child_values(s, level, parent) do
          {:ok, children, s} ->
            case cell_value(s, level, parent) do
              {:ok, old, s} ->
                {material, skins} = Reducer.reduce_cell(children, level)

                {skins, s} =
                  if level == 1 do
                    Attachments.project_l1(
                      parent,
                      skins,
                      Map.get(faces, parent, []),
                      fn micro, world ->
                        {target, world} = target_at(micro, world)
                        {if(target, do: target.material, else: 0), world}
                      end,
                      s
                    )
                  else
                    {skins, s}
                  end

                new = {material, skins}

                next =
                  if new == old,
                    do: {changed, s},
                    else: {[{level, parent} | changed], put_overlay(s, level, parent, new)}

                {:cont, next}

              {:error, :missing, s} ->
                Logger.warning(
                  "voxel_region: L#{level} around #{inspect(parent)} not baked; reduce chain stops here"
                )

                {:cont, {changed, s}}

              {:error, reason, _s} ->
                {:halt, {:error, reason}}
            end

          {:error, :missing, s} ->
            Logger.warning(
              "voxel_region: L#{level} around #{inspect(parent)} not baked; reduce chain stops here"
            )

            {:cont, {changed, s}}

          {:error, reason, _s} ->
            {:halt, {:error, reason}}
        end
      end)

    case result do
      {:error, reason} ->
        {:error, reason}

      {changed, state} ->
        reduce_batch(state, changed, level + 1, changed ++ all, visits + length(parents))
    end
  end

  defp child_values(state, level, {px, py, pz}) do
    result =
      Enum.reduce_while(0..7, {[], state}, fn oct, {children, s} ->
        cell = {px * 2 + (oct &&& 1), py * 2 + (oct >>> 1 &&& 1), pz * 2 + (oct >>> 2 &&& 1)}

        case cell_value(s, level - 1, cell) do
          {:ok, value, s} -> {:cont, {[value | children], s}}
          {:error, reason, s} -> {:halt, {:error, reason, s}}
        end
      end)

    case result do
      {:error, reason, state} -> {:error, reason, state}
      {children, state} -> {:ok, Enum.reverse(children), state}
    end
  end

  defp select_transaction(state, changed) do
    entry_overhead = 4 + IO.iodata_length(Codec.encode_entry(%{seq: state.seq, payload: <<>>}))
    minimum_region_bytes = entry_overhead + Codec.payload_min_bytes()
    groups = Enum.group_by(changed, fn {level, cell} -> {level, region_of(cell)} end)

    Enum.reduce(
      Enum.sort(groups),
      {%{seq: state.seq, entries: [], coarse: []}, state},
      fn {{level, region}, keys}, {txn, s} ->
        started = System.monotonic_time(:microsecond)

        sparse =
          Enum.map(Enum.sort(keys), fn {level, cell} ->
            {m, skins} = Map.fetch!(s.overlay, {level, cell})

            if level == 0,
              do: %{seq: s.seq, coord: cell, material: m, coarse: []},
              else: %{level: level, cell: cell, material: m, skins: skins}
          end)

        cell_bytes =
          Enum.reduce(sparse, 0, fn e, n ->
            n +
              if(level == 0,
                do: 4 + IO.iodata_length(Codec.encode_entry(e)),
                else: IO.iodata_length(Codec.encode_coarse(e))
              )
          end)

        {bytes, s} =
          if cell_bytes > minimum_region_bytes do
            {:ok, bytes, _header, next} = payload_bytes(s, level, region)
            {bytes, next}
          else
            {nil, s}
          end

        Logger.info(
          "voxel_select_region seq=#{s.seq} level=#{level} region=#{inspect(region)} sparse_bytes=#{cell_bytes} region_bytes=#{if bytes, do: byte_size(bytes), else: 0} elapsed_us=#{System.monotonic_time(:microsecond) - started}"
        )

        if bytes != nil and cell_bytes > entry_overhead + byte_size(bytes) do
          {%{txn | entries: txn.entries ++ [region_entry(s.seq, bytes)]}, s}
        else
          if level == 0,
            do: {%{txn | entries: txn.entries ++ sparse}, s},
            else: {%{txn | coarse: txn.coarse ++ sparse}, s}
        end
      end
    )
  end

  defp compact_log(%{seq: 0} = state), do: state

  defp compact_log(state) do
    # 检查点覆盖完整前缀；当前 seq 对任意更旧游标都是完整补丁。
    # 已有完整区域会在下方写入当前 after-image，不再先编码同一 core 的逐格条目。
    sparse =
      for {{level, cell} = key, _} <- state.overlay,
          not MapSet.member?(state.snapshots, {level, region_of(cell)}),
          do: key

    {txn, state} = select_transaction(state, sparse)

    {extra, state} =
      Enum.map_reduce(state.snapshots, state, fn {level, region}, s ->
        {:ok, bytes, _, s} = payload_bytes(s, level, region)
        {region_entry(s.seq, bytes), s}
      end)

    txn =
      Map.merge(%{txn | entries: txn.entries ++ extra}, %{
        property_states: Map.values(state.damage),
        epochs: state.epochs,
        material_balances: state.material_balances,
        caster_energy: state.caster_energy,
        material_supplies: state.material_supplies,
        craft_ledger: state.craft_ledger,
        food_ledger: state.food_ledger,
        placed_by: state.placed_by,
        macro_owners: state.macro_owners,
        protection: state.protection.regions,
        phase_inventory: state.phase_inventory,
        thermal: state.thermal
      })

    {backend, handle} = state.log
    backend.checkpoint(handle, attachment_metadata(state, txn))

    state =
      Enum.reduce(txn.entries, state, fn
        %{payload: bytes}, s ->
          {:ok, p} = Payload.decode(bytes)
          rebase_region(s, p)

        _, s ->
          s
      end)

    if state.checkpoint_timer, do: Process.cancel_timer(state.checkpoint_timer)
    # Replicas mirror this history horizon; sent after every delta up to this seq.
    Enum.each(Map.keys(state.replica_subs), &send(&1, {:canonical_replica_checkpoint, state.seq}))
    remember_entry(%{state | entries: %{}, entry_regions: %{}, checkpoint_timer: nil,
      checkpoints: state.checkpoints + 1}, txn)
  end

  # no-op 不追加日志；只向发起连接确认当前游标，排在此连接已有的 World 消息之后。
  defp acknowledge_noop(state, {pid, _tag}) do
    if Map.has_key?(state.subs, pid) do
      bytes =
        Codec.encode_transaction(%{seq: state.seq, entries: [], coarse: []})
        |> IO.iodata_to_binary()

      send(pid, {:voxel_log_transaction_payload, bytes})
    end
  end

  defp region_entry(seq, bytes), do: %{seq: seq, payload: Codec.stamp_payload_seq(bytes, seq)}

  defp load_properties(opts) do
    case Keyword.get(
           opts,
           :property_catalog_path,
           Application.get_env(:voxel_region, :property_catalog_path)
         ) do
      nil -> nil
      path -> Damage.load(path)
    end
  end

  defp load_magic(opts) do
    case Keyword.get(opts, :magic_catalog_path, Application.get_env(:voxel_region, :magic_catalog_path)) do
      nil -> nil
      path -> Magic.Catalog.load(path)
    end
  end

  # 全局系统功能：平衡容差是求解分辨率，辐射参数随本变更引入、旧存档没有，二者以环境资产为准；
  # 回放的热账（环境温度、换热系数、能量账）保持存档值。
  # 气候区与愈合时间压缩系数同理以资产为准：资产没有该字段时回放后也没有（与引入前的配置逐字节相同）。
  defp environment_tolerance(%{thermal: %{config: config} = thermal} = state, %{config: asset}),
    do: %{state | thermal: %{thermal | config: config
      |> Map.merge(Map.take(asset, ~w(tolerance_kelvin emissivity view_range_cells climate_zones heal_time_compression)))
      |> then(&Map.drop(&1, for(key <- ~w(climate_zones heal_time_compression), not Map.has_key?(asset, key), do: key)))}}

  defp environment_tolerance(state, _), do: state

  # 辐射环境字段必须显式发布：发射率 ∈ [0, 1]（0 = 关闭辐射），视距为正整数宏格。
  defp radiation_config?(config) do
    is_number(config["emissivity"]) and config["emissivity"] >= 0 and config["emissivity"] <= 1 and
      is_integer(config["view_range_cells"]) and config["view_range_cells"] > 0
  end

  # 全局环境不包含测试源；玩家设施只从已经支付的燃料获得能量。
  defp load_thermal_environment(opts) do
    case Keyword.get(
           opts,
           :thermal_environment_path,
           Application.get_env(:voxel_region, :thermal_environment_path)
         ) do
      nil ->
        nil

      path ->
        config =
          Jason.decode!(File.read!(path))
          |> Map.take(~w(ambient_kelvin environment_w_per_m2_k tolerance_kelvin emissivity view_range_cells climate_zones heal_time_compression))

        true =
          Enum.all?(
            ~w(ambient_kelvin environment_w_per_m2_k tolerance_kelvin),
            &is_number(config[&1])
          ) and
            config["ambient_kelvin"] > 0 and config["environment_w_per_m2_k"] >= 0 and
            config["tolerance_kelvin"] > 0 and radiation_config?(config) and
            VoxelRegion.Climate.valid?(config) and
            (not Map.has_key?(config, "heal_time_compression") or
               (is_number(config["heal_time_compression"]) and config["heal_time_compression"] > 0))

        %{
          config: config,
          sources: %{},
          elapsed_s: 0.0,
          supplied_j: 0.0,
          environment_j: 0.0,
          combustion_j: 0.0,
          combustion_removed_j: 0.0,
          active: false
        }
    end
  end

  defp target_at(micro, state) do
    {cell, slot} = Prefab.macro_slot(micro)

    case Map.fetch(state.refined, cell) do
      {:ok, slots} ->
        case Map.fetch(slots, slot) do
          {:ok, {material, {birth, _} = owner}} ->
            {%{
               micro: micro,
               granularity: 2,
               incarnation: birth,
               owner: owner,
               material: material
             }, state}

          :error ->
            {nil, state}
        end

      :error ->
        {:ok, {material, _}, state} = cell_value(state, 0, cell)

        target =
          if material != 0 and not (finite_material?(state,material) and Map.has_key?(state.liquid_units,cell) and
            rem(div(slot,@micro),@micro) >= div(state.liquid_units[cell]*@micro+liquid_capacity(state)-1,liquid_capacity(state))),
            do: %{
              micro: cell |> Tuple.to_list() |> Enum.map(&(&1 * @micro)) |> List.to_tuple(),
              granularity: 0,
              incarnation: Map.get(state.epochs, cell, 0),
              owner: Map.get(state.macro_owners,cell,{0,0}),
              material: material
            }

        {target, state}
    end
  end

  defp property_state(state, target, component_hp \\ nil) do
    m = Map.fetch!(state.properties.materials, target.material)

    row =
      case Map.fetch(state.damage, Damage.key(target)) do
        {:ok, t} ->
          Map.merge(t, target)
          |> Map.merge(%{seq: state.seq, request_id: 0, defense: m["defense"] * 1.0})

        :error ->
          hp =
            case target.granularity do
              2 ->
                if is_nil(component_hp), do: component_max_hp(state, target.owner), else: component_hp

              3 ->
                attachment_max_hp(state, target)

              4 ->
                m["max_hp_per_macro"] *
                  VoxelRegion.ThermalAttachments.volume(
                    Attachments.slot(target),
                    state.properties
                  )

              0 ->
                Damage.max_hp(m, 0) * finite_volume(state, target)

              g ->
                Damage.max_hp(m, g)
            end

          row =
            Map.merge(target, %{
              seq: state.seq,
              request_id: 0,
              hp: hp,
              max_hp: hp,
              defense: m["defense"] * 1.0,
              digest: state.properties.digest,
              flags: 0
            })

          if state.thermal && target.granularity in [0, 4] &&
               Map.has_key?(m, "heat_capacity_per_macro"),
             do: Map.put(row, :temperature_kelvin, ambient_at(state, Damage.macro(target))),
             else: row
      end

    # 整件 HP 记录上的环境值仅声明附件默认温度；命中槽的确认温度由 granularity 4 覆盖。
    if state.thermal && target.granularity == 3 && Map.has_key?(m, "heat_capacity_per_macro"),
      do: Map.put(row, :temperature_kelvin, ambient_at(state, Damage.macro(target))),
      else: row
  end

  # 固定 500 ms 墙钟节拍：下一次到期 = 上次到期 + 500 ms，回调耗时不再拉长周期
  # （原先在回调末尾再等 500 ms，模拟时间只有墙钟的 0.5/(0.5+回调秒数)）。落后时立即提交、不积压补跑。
  defp schedule_thermal(state) do
    now = System.monotonic_time(:millisecond)
    due = max((state.thermal_due || now) + 500, now)
    Process.send_after(self(), :thermal_commit, due - now)
    %{state | thermal_due: due}
  end

  # 占用编辑只让派生几何与视线失效；无热环境时工作集恒为空。
  defp drop_thermal_geometry(%{thermal: nil} = state, _cells), do: state

  defp drop_thermal_geometry(state, cells),
    do: %{state | thermal_work:
      ThermalWork.drop(state.thermal_work, cells, state.thermal.config["view_range_cells"])}

  # 全局系统功能：温度和 HP 仍由同一个 World 的稀疏状态记录持有。
  # 每 500 ms 提交一次；原生核按容量/接触选择不超过 50 ms 的稳定步长。
  # 派生工作集不写日志；缓存只含身份、材质与暴露面，数值批次读取当前权威记录。
  defp rebuild_thermal_work(%{thermal: nil} = state),
    do: %{state | thermal_work: ThermalWork.new()}

  # 也是气候变化的通知点（VoxelRegion.Climate 契约 2）：环境变了，偏离新环境的记录格即热种子，非空就置活动；
  # 冷启动时资产气候区与存档时不同（如新加寒区）走的正是这里。
  defp rebuild_thermal_work(state) do
    hot = ThermalWork.hot(state.damage, state.thermal.config)

    active = state.thermal.active or MapSet.size(hot) > 0 or
      Enum.any?(state.damage, fn {_, t} -> Combustion.exhausted?(t) end)
    %{state | thermal: %{state.thermal | active: active}, thermal_work: %{ThermalWork.new() | hot: hot}}
  end

  defp advance_thermal(state) do
    start = System.monotonic_time(:microsecond)
    before = state
    # 燃烧行在提交之间可被工具、放置等事务改写：每次提交首轮重新扫描。
    state = %{state | thermal_work: %{state.thermal_work | builds: 0, burning: nil}}
    {state, visited} = circuit_steps(state, 0.5, MapSet.new())
    stepped = System.monotonic_time(:microsecond)
    # 同一提交内只扩张热域，避免容差边缘反复删添接触；批末按当前真值收缩。
    hot = ThermalWork.hot(state.damage, state.thermal.config)
    state = %{state | thermal_work: %{state.thermal_work | hot: hot},
      thermal: %{state.thermal | active: map_size(state.thermal.sources) > 0 or MapSet.size(hot) > 0}}
    # 燃料耗尽表示材料被消耗，不保留可重新采掘的整块木材。
    # 微格／附件沿已有最低层整件完整度语义归零，其余未燃料量记入移除账。
    {state, visited} = Enum.reduce(state.damage, {state, visited}, fn {_, row}, {s, keys} ->
      if Combustion.exhausted?(row) do
        granularity = case row.granularity do
          1 -> 2
          4 -> 3
          g -> g
        end
        target = property_state(s, %{row | granularity: granularity}
          |> Map.take([:micro, :granularity, :incarnation, :owner, :material]))
        key = Damage.key(target)
        {%{s | damage: Map.put(s.damage, key, %{target | hp: 0.0})}, MapSet.put(keys, key)}
      else
        {s, keys}
      end
    end)
    work = state.thermal_work
    scanned = System.monotonic_time(:microsecond)

    Logger.info(
      "voxel_thermal_sim steps_us=#{stepped - start} scan_us=#{scanned - stepped} damage_rows=#{map_size(state.damage)} simulated_s=0.5 max_step_ms=50 elapsed_us=#{System.monotonic_time(:microsecond) - start} hot=#{MapSet.size(work.hot)} candidates=#{map_size(work.geometry)} geometry_builds=#{work.builds}"
    )

    rows =
      for key <- visited,
          t <- [Map.fetch!(state.damage, key)],
          Map.get(before.damage, key) != t,
          do: %{t | seq: state.seq + 1, request_id: 0}

    phase_changes = for {_,t}<-state.damage, phase_target?(state,t),
      q=Map.get(state.liquid_units,Damage.macro(t),liquid_capacity(state)),
      e=Phase.energy(t,q/liquid_capacity(state),state.properties.materials[t.material],ambient_at(state,Damage.macro(t))),
      Phase.material(t.material,e,q/liquid_capacity(state),state.properties.materials)!=t.material,
      into: %{}, do: {Damage.macro(t),q}
    dead = Enum.filter(rows, &(&1.hp == 0.0 and not phase_target?(state,&1)))

    if dead == [] and map_size(phase_changes)>0 do
      {:ok,state}=commit_liquid(state,phase_changes,Map.merge(%{property_states: rows}, semblance_txn(semblances(before), state)))
      state
    else
    if dead == [] do
      thermal_commit(state, rows, semblance_txn(semblances(before), state))
    else
      # 归零与占用删除在原宏格损伤事务中一起持久化，不能留下已提交的零血量实体。
      # 同一步其他节点的温度、热源余量也属于这笔事务；热损伤不发放采掘奖励。
      rows = Enum.map(rows, fn t -> if t.hp == 0.0, do: %{t | flags: 1}, else: t end)

      state = %{
        state
        | damage: Enum.reduce(rows, state.damage, fn t, all -> Map.put(all, Damage.key(t), t) end)
      }

      macros = for t <- dead, t.granularity == 0, do: {Damage.macro(t), 0}
      owners = MapSet.new(for t <- dead, t.granularity == 2, do: t.owner)
      attachments = MapSet.new(for t <- dead, t.granularity == 3, do: t.incarnation)

      {:ok, state} =
        commit_liquid(state, phase_changes, Map.merge(%{property_states: rows}, semblance_txn(semblances(before), state)),
          macros, owners, attachments)

      state
    end
    end
  end

  defp circuit_steps(state, remaining, visited) when remaining < 1.0e-12, do: {state, visited}

  defp circuit_steps(state, remaining, visited) do
    seeds = circuit_seeds(state)

    if seeds == [] do
      {state, visited} = thermal_steps(state, remaining, visited, %{})
      {damage, visited} = electric_rows(state.damage, visited, %{})
      {damage, visited} = source_rows(state, damage, visited, %{})
      {%{state | damage: damage}, visited}
    else
      # 受保护区域：导线端点按槽的持有者分开，端点只接同一持有者的实体导体。
      protection = state.protection
      domain = if not Protection.empty?(protection),
        do: fn slot -> cells_holder(protection, Attachments.macros([slot]), slot) end
      input = VoxelRegion.Circuit.prepare(state.attachments, state.damage, state.properties, remaining,
        state.thermal.config, domain)
      {hosts, state} = Enum.map_reduce(VoxelRegion.Circuit.points(input), state, fn point, s ->
        {targets, s} = Enum.map_reduce(VoxelRegion.Circuit.near_points(point), s, &circuit_target/2)
        conductors = VoxelRegion.Circuit.conductors(targets, s.properties, s.damage)
        conductors = if domain,
          do: Enum.filter(conductors, &({:holder, Protection.holder(protection, Damage.macro(&1))} == elem(point, 2))),
          else: conductors
        {{point, conductors}, s}
      end)
      # 导体图从线端点的宿主与电动势种子（有储能的蓄能石、带温度的热电石）两头按实接触扩张。
      solids = for target <- seeds ++ for({_point, targets} <- hosts, target <- targets, do: target), into: %{},
        do: {VoxelRegion.ThermalGeometry.key(target), target}
      {contacts, state} = circuit_contacts(Map.values(solids), MapSet.new(), [], state)
      plan = VoxelRegion.Circuit.plan(input, Map.new(hosts), contacts)
      {state, visited} = thermal_steps(state, plan.duration, visited, plan.powers)
      {damage, visited} = electric_rows(state.damage, visited, plan.electric)
      {damage, visited} = source_rows(state, damage, visited, plan.sources)

      thermal =
        state.thermal
        |> Map.update(:circuit_supplied_j, plan.supplied_j, &(&1 + plan.supplied_j))
        |> Map.update(:circuit_charged_j, plan.charged_j, &(&1 + plan.charged_j))
        |> Map.update(:circuit_thermoelectric_j, plan.thermoelectric_j, &(&1 + plan.thermoelectric_j))
        |> Map.update(:circuit_light_j, plan.light_j, &(&1 + plan.light_j))

      Logger.info(
        "voxel_circuit simulated_s=#{plan.duration} nodes=#{plan.nodes} edges=#{plan.edges} solve_us=#{plan.elapsed_us} supplied_j=#{plan.supplied_j} charged_j=#{plan.charged_j} thermoelectric_j=#{plan.thermoelectric_j} light_j=#{plan.light_j} luminous=#{map_size(plan.electric)} sources=#{map_size(plan.sources)}"
      )

      circuit_steps(
        %{state | damage: damage, thermal: thermal},
        remaining - plan.duration,
        visited
      )
    end
  end

  # 全局系统功能（R8-04 增量 3）：蓄能石的储能 `stored_j` 是格属性行上的真值；本段求解的电动势与带号电流
  # （蓄能石、热电石）是派生观察，写在同一行上随属性下发。新放置的蓄能石没有行，按需建默认行；离开所有已求解
  # 网络的行去掉两个观察字段，储能保留。值不变的记录不进提交。
  defp source_rows(state, damage, visited, sources) do
    lit =
      for {_key, view} <- sources, into: %{} do
        target = view.target
        key = Damage.key(target)
        row = Map.get_lazy(damage, key, fn -> property_state(%{state | damage: damage}, target) end)
        battery = VoxelRegion.Circuit.battery?(state.properties.materials[target.material])
        fields = %{source_emf_v: view.emf_v, source_current_a: view.current_a}
        fields = if battery, do: Map.put(fields, :stored_j, view.stored_j), else: fields
        {key, Map.merge(row, fields)}
      end

    stale = for {key, %{source_emf_v: _} = row} <- damage, not Map.has_key?(lit, key), into: %{},
      do: {key, Map.drop(row, [:source_emf_v, :source_current_a])}

    Enum.reduce(Map.merge(stale, lit), {damage, visited}, fn {key, row}, {d, v} ->
      if Map.get(d, key) == row, do: {d, v}, else: {Map.put(d, key, row), MapSet.put(v, key)}
    end)
  end

  # 全局系统功能：发光导体（目录 λ > 0）本段求解的电功率与穿过电流是派生观察，写在已有温度记录上随属性下发；
  # 不再通电的记录去掉这两个字段。值不变的记录不进提交（提交只发与提交前不同的记录）。
  defp electric_rows(damage, visited, electric) do
    lit =
      for {_key, {target, w, a}} <- electric, key <- [Damage.key(target)],
          %{temperature_kelvin: _} <- [Map.get(damage, key)], into: %{},
          do: {key, %{electric_w: w, current_a: a}}

    stale = for {key, %{electric_w: _}} <- damage, not Map.has_key?(lit, key), into: %{},
      do: {key, nil}

    Enum.reduce(Map.merge(stale, lit), {damage, visited}, fn
      {key, nil}, {d, v} -> {Map.update!(d, key, &Map.drop(&1, [:electric_w, :current_a])), MapSet.put(v, key)}
      {key, fields}, {d, v} -> {Map.update!(d, key, &Map.merge(&1, fields)), MapSet.put(v, key)}
    end)
  end

  # D6：散体格（带数量记录）不导电——不是种子、不是线端宿主、不参与实体接触。
  defp circuit_seeds(state),
    do: Enum.reject(VoxelRegion.Circuit.seeds(state.damage, state.properties), &loose_cell?(state, &1))

  defp circuit_target(point, state) do
    {target, state} = target_at(point, state)
    {if(target && loose_cell?(state, target), do: nil, else: target), state}
  end

  # 按实际连通导体扩张 canonical 读取；不预读全世界，也不把 owner 交给计算模块。
  defp circuit_contacts([], _seen, contacts, state), do: {contacts, state}
  defp circuit_contacts([target | queue], seen, contacts, state) do
    key = VoxelRegion.ThermalGeometry.key(target)
    if MapSet.member?(seen, key) do
      circuit_contacts(queue, seen, contacts, state)
    else
      seen = MapSet.put(seen, key)
      {targets, state} = Enum.flat_map_reduce(VoxelRegion.Circuit.solid_faces(target), state, &face_targets/2)
      {queue, contacts} = Enum.reduce(VoxelRegion.Circuit.solid_contacts(targets, state.properties, state.damage),
        {queue, contacts}, fn {other_key, {other, area}}, {queue, contacts} ->
          if MapSet.member?(seen, other_key) or
               not Protection.same_holder?(state.protection, Damage.macro(target), Damage.macro(other)),
            do: {queue, contacts},
            else: {[other | queue], [{target, other, area} | contacts]}
        end)
      circuit_contacts(queue, seen, contacts, state)
    end
  end

  # 一个面的全部采样点都在同一个相邻宏格里时：该格未细分、没有液位（液位让同一格按高度部分为空）就对每个点给出
  # 同一个目标，只读一次（原先宏格导体每面逐点 64 次）；否则逐点读取，每点一段。
  defp face_targets([point | _] = points, state) do
    {cell, _} = Prefab.macro_slot(point)
    if length(points) > 1 and not Map.has_key?(state.refined, cell) and not Map.has_key?(state.liquid_units, cell) do
      {target, state} = circuit_target(point, state)
      {[{target, length(points)}], state}
    else
      Enum.map_reduce(points, state, fn p, s -> {t, s} = circuit_target(p, s); {{t, 1}, s} end)
    end
  end

  defp thermal_steps(state, remaining, visited, _powers) when remaining < 1.0e-12,
    do: {state, visited}

  defp thermal_steps(state, remaining, visited, powers) do
    {state, changed, done} = thermal_step(state, remaining, powers)
    thermal_steps(state, remaining - done, MapSet.union(visited, changed), powers)
  end

  defp thermal_step(state, duration, powers) do
    started = System.monotonic_time(:microsecond)
    config = state.thermal.config

    # 魔法增量 2：已落地拟态的接触候选宏格（包围立方体覆盖或贴面）与热源同为热种子（plan 只读键）。
    contacts = for {_, s} <- semblances(state), Magic.Semblance.landed?(s), cell <- Magic.Semblance.span(s),
      into: %{}, do: {cell, nil}
    # 魔法增量 4：身体接触的世界格同为热种子。
    contacts = for {_, b} <- state.bodies, {kind, _key, cell, _g} <- b.contacts, kind in [:node, :wet], into: contacts,
      do: {cell, nil}
    plan = ThermalWork.plan(state.thermal_work, Map.merge(contacts, state.thermal.sources), powers, state.damage)
    neighborhood_done = System.monotonic_time(:microsecond)

    {geometry, state} = Enum.reduce(plan.missing, {plan.geometry, state}, &thermal_cell/2)

    {plan, geometry, state} =
      if VoxelRegion.ThermalRadiation.enabled?(config),
        do: sight_domain(state, plan, geometry),
        else: {plan, geometry, state}

    geometry_done = System.monotonic_time(:microsecond)

    {work, rebuild?} = ThermalWork.refresh(state.thermal_work, plan, geometry, state.attachments)
    refreshed = System.monotonic_time(:microsecond)

    {work, state} =
      if rebuild? do
        {samples, state} = thermal_samples(state,
          VoxelRegion.ThermalAttachments.points(work.thermal_slots, state.properties), %{})
        {nodes, attachment_graph} = VoxelRegion.ThermalAttachments.add(
          work.solid_nodes, work.thermal_slots, state.properties, samples, work.attachment_graph)

        work = ThermalWork.index(work, protected_contacts(state, nodes), attachment_graph)
        # 默认记录只由目录、环境和实占用派生；已有属性仍在每个数值批次读取。
        # 同一几何节点的派生字段按目录与环境标签缓存；相态宏格的默认 HP 随有限数量变化，每次重算。
        defaults = %{state | damage: %{}}
        tag = {state.properties.digest, config["ambient_kelvin"], config["climate_zones"]}
        cache = case work.augmented do
          {^tag, cache} -> cache
          _ -> %{}
        end
        # 增量扩域只添加节点，沿用缓存；整域重算时只保留仍在域内的节点。
        grown? = plan.grown != nil
        {ordered, cache} = Enum.map_reduce(work.ordered, if(grown?, do: cache, else: %{}), fn {key, n}, kept ->
          case cache do
            %{^key => {^n, node} = entry} -> {{key, node}, if(grown?, do: kept, else: Map.put(kept, key, entry))}
            _ ->
              node = Map.merge(n, %{damage_key: Damage.key(n.target), cell: Damage.macro(n.target),
                                    cells: ThermalWork.cells(n.target), default: property_state(defaults, n.target),
                                    ignition: if(Combustion.combustible?(n.material),
                                      do: n.material["ignition_kelvin"] * 1.0, else: nil)})
              {{key, node}, if(finite_target?(state, n.target), do: kept, else: Map.put(kept, key, {n, node}))}
          end
        end)
        {%{work | ordered: ordered, augmented: {tag, cache}}, state}
      else
        {work, state}
      end

    rebuilt = System.monotonic_time(:microsecond)
    ordered = work.ordered
    indexed_edges = work.indexed_edges

    radiation =
      if VoxelRegion.ThermalRadiation.enabled?(config),
        do: VoxelRegion.ThermalRadiation.terms(ordered, work.sights, config["emissivity"], work.indices),
        else: {[], []}

    nodes_done = System.monotonic_time(:microsecond)

    sources =
      Map.filter(state.thermal.sources, fn {cell, source} ->
        Enum.any?(Map.get(geometry, cell, []), fn {_, n} ->
          same_target?(source.target, n.target) and source.remaining_j > 0
        end)
      end)

    samples =
      Enum.map(ordered, fn {key, node} ->
        row = Map.get_lazy(state.damage, node.damage_key, fn -> %{node.default | seq: state.seq} end)
        volume = if phase_target?(state, row), do: finite_volume(state, row)
        {key, node, row, volume}
      end)
    sampled = System.monotonic_time(:microsecond)

    semblances = Enum.sort(semblances(state))
    duration = Magic.Semblance.cap(Enum.map(semblances, &elem(&1, 1)), duration)

    batch = VoxelRegion.ThermalBatch.prepare(
      samples, sources, powers, work.hot, config, duration)

    # 拟态是内核外部节点：接在世界节点之后，接触边与辐射项按同一索引追加；结果按世界节点数切分。
    count = length(batch.input)
    {extra, edges, radiation} = semblance_terms(state, semblances, work.indices, samples, count, radiation)
    bodies = Enum.sort(state.bodies)
    {body_nodes, body_edges} = body_terms(bodies, work.indices, semblances, count)
    input = batch.input ++ extra ++ body_nodes
    edges = edges ++ body_edges
    # 逐节点环境温度：世界节点按所在宏格，拟态按所在宏格，身体两节点（暴露面积 0、恒为种子）取全局值不影响数值。
    ambient = batch.ambient ++
      Enum.map(semblances, fn {_, s} -> ambient_at(state, Magic.Semblance.macro(Magic.Semblance.current(s))) * 1.0 end) ++
      Enum.flat_map(bodies, fn _ -> [config["ambient_kelvin"] * 1.0, config["ambient_kelvin"] * 1.0] end)

    prepared = System.monotonic_time(:microsecond)

    {done, result, supplied, environment} =
      VoxelRegion.ThermalNative.advance(
        input,
        indexed_edges ++ edges,
        ambient,
        config["environment_w_per_m2_k"] * 1.0,
        config["tolerance_kelvin"] * 1.0,
        batch.duration,
        radiation
      )

    calculated = System.monotonic_time(:microsecond)
    {result, external} = Enum.split(result, count)
    {semblance_result, body_result} = Enum.split(external, length(semblances))

    {changes, sources, hot, losses, combustion_used} =
      VoxelRegion.ThermalSettlement.apply(batch.targets, result, sources, config, done)
    settled = System.monotonic_time(:microsecond)

    changes =
      Enum.reduce(losses, changes, fn {{granularity, _}, {micro, loss}}, changes ->
        target =
          property_state(state, %{
            Map.take(micro, [:micro, :granularity, :incarnation, :owner, :material])
            | granularity: granularity
          })

        target = %{target | hp: max(0.0, target.hp - loss)}
        [{Damage.key(target), target} | changes]
      end)

    damage = Map.merge(state.damage, Map.new(changes))
    merged = System.monotonic_time(:microsecond)
    {damage, propagated} = ignite_heated_materials(state, damage, ordered)
    ignited = System.monotonic_time(:microsecond)
    changes = changes ++ propagated
    changed = MapSet.new(changes, &elem(&1, 0))
    hot = MapSet.union(work.hot, MapSet.new(hot))

    active =
      map_size(sources) > 0 or MapSet.size(hot) > 0 or
        Enum.any?(damage, fn {_, t} -> Map.get(t, :burning, false) end)

    initialized = Enum.reduce(propagated,0.0,fn {key,row},sum ->
      if Map.has_key?(Map.get(state.damage,key,%{}),:remaining_fuel_j),do: sum,else: sum+row.remaining_fuel_j
    end)
    thermal_base = Map.merge(%{combustion_j: 0.0, combustion_removed_j: 0.0}, state.thermal)
      |> Map.update(:fuel_initialized_j,initialized,&(&1+initialized))

    thermal = %{
      thermal_base
      | sources: sources,
        elapsed_s: thermal_base.elapsed_s + done,
        active: active,
        supplied_j: thermal_base.supplied_j + supplied,
        environment_j: thermal_base.environment_j + environment,
        combustion_j: thermal_base.combustion_j + combustion_used
    }

    work = if active, do: ThermalWork.burned(%{work | hot: hot}, changes), else: %{ThermalWork.new() | builds: work.builds}
    state = advance_semblances(%{state | damage: damage, thermal: thermal}, semblances, semblance_result, done)
    state = exchange_bodies(state, bodies, body_edges, body_result, result ++ semblance_result, work.indices, done)

    Logger.info(
      "voxel_thermal_kernel simulated_s=#{done} nodes=#{length(input)} edges=#{length(indexed_edges)} radiation_pairs=#{length(elem(radiation, 0))} sky_faces=#{length(elem(radiation, 1))} prepare_us=#{prepared - started} nif_us=#{calculated - prepared} accept_us=#{System.monotonic_time(:microsecond) - calculated}"
    )

    Logger.info(
      "voxel_thermal_prepare neighborhood_us=#{neighborhood_done - started} geometry_us=#{geometry_done - neighborhood_done} nodes_us=#{nodes_done - geometry_done} input_us=#{prepared - nodes_done} refresh_us=#{refreshed - geometry_done} rebuild_us=#{rebuilt - refreshed} terms_us=#{nodes_done - rebuilt} samples_us=#{sampled - nodes_done} batch_us=#{prepared - sampled} settle_us=#{settled - calculated} merge_us=#{merged - settled} ignite_us=#{ignited - merged} rebuild=#{rebuild?}"
    )

    {%{state | thermal_work: work}, changed, done}
  end

  # ---- 魔法增量 2：拟态作为热内核外部节点（Voxim Docs/Magic.md §3；纯规则在 Magic.Semblance）
  # 节点 {T,1,1,C,k_s,1e6,暴露面积,0,0,true}；已落地时按当前世界与本次域内每个贴面 / 重叠的实占用节点各连一条接触边
  # （面积与法向按真实几何，Magic.Semblance.contact/2；串联导热同 ThermalGeometry），与接触节点按角系数互换辐射、
  # 按接触面积比例分摊，其余对天空；受保护区域 / 气候区边界同 protected_contacts：拟态所在格与接触格持有者不同则不连。

  defp semblances(%{thermal: nil}), do: %{}
  defp semblances(state), do: Map.get(state.thermal, :semblances, %{})

  defp semblance_terms(_state, [], _indices, _samples, _count, radiation), do: {[], [], radiation}

  defp semblance_terms(state, semblances, indices, samples, count, {pairs, sky}) do
    config = state.thermal.config
    conductivity = state.magic.semblance.conductivity
    emissivity = if VoxelRegion.ThermalRadiation.enabled?(config), do: config["emissivity"] * 1.0, else: 0.0
    bounded = thermal_bounded?(state)
    # 候选宏格里的实占用节点（附件槽不与拟态接触）；有限液柱按实际液位定盒。
    wanted = for {_, s} <- semblances, Magic.Semblance.landed?(s), cell <- Magic.Semblance.span(s), into: MapSet.new(), do: cell
    by_cell = for {key, n, _row, volume} <- samples, n.target.granularity != 4, MapSet.member?(wanted, n.cell), reduce: %{} do
      acc -> Map.update(acc, n.cell, [{key, n, volume}], &[{key, n, volume} | &1])
    end

    {extra, edges, pairs, sky} =
      semblances
      |> Enum.with_index(count)
      |> Enum.reduce({[], [], pairs, sky}, fn {{_id, s}, i}, {extra, edges, pairs, sky} ->
        touching =
          if Magic.Semblance.landed?(s) do
            holder = bounded and thermal_holder(state, Magic.Semblance.macro(s.rest))
            for cell <- Magic.Semblance.span(s), not bounded or thermal_holder(state, cell) == holder,
                {key, n, volume} <- Map.get(by_cell, cell, []), {:ok, j} <- [Map.fetch(indices, key)],
                {lo, hi} = box <- [VoxelRegion.ThermalGeometry.bounds(n.target, volume || 1.0)],
                {area, axis} <- List.wrap(Magic.Semblance.contact(s, box)),
                do: {j, area, Magic.Semblance.conductance(s, conductivity, n.material["thermal_conductivity"],
                  (elem(hi, axis) - elem(lo, axis)) / 2, area)}
          else
            []
          end

        total = Enum.sum(Enum.map(touching, &elem(&1, 1))) * 1.0
        {mutual, open} = Magic.Semblance.radiation(s, emissivity, total)
        edges = Enum.reduce(touching, edges, fn {j, _area, g}, edges -> [{j, i, g} | edges] end)
        pairs = if mutual > 0, do: Enum.reduce(touching, pairs, fn {j, area, _g}, pairs -> [{i, j, mutual * area / total} | pairs] end), else: pairs
        sky = if open > 0, do: [{i, open} | sky], else: sky
        {[Magic.Semblance.node(s, conductivity, total) | extra], edges, pairs, sky}
      end)

    {Enum.reverse(extra), Enum.reverse(edges), {pairs, sky}}
  end

  # 一段演进后：写回温度、计光与流出账；到达落点转内能；寿命到期移除并把剩余能量作为有限热源释放到接触宏格。
  defp advance_semblances(state, [], _result, _done), do: state

  defp advance_semblances(state, semblances, result, done) do
    {kept, thermal} =
      Enum.zip(semblances, result)
      |> Enum.reduce({%{}, state.thermal}, fn {{id, s}, {temperature, _, _}}, {kept, thermal} ->
        {s, light, exchanged} = Magic.Semblance.step(s, temperature, done)
        thermal = thermal |> ledger(:semblance_light_j, light) |> ledger(:semblance_exchanged_j, exchanged)
        {Map.put(kept, id, s), thermal}
      end)

    state = %{state | thermal: Map.put(thermal, :semblances, kept)}

    kept
    |> Enum.filter(fn {_, s} -> Magic.Semblance.expired?(s) end)
    |> Enum.reduce(state, fn {id, s}, state -> release_semblance(state, id, s) end)
  end

  # 移除拟态（寿命到期或驱散）：剩余能量（显热 + 飞行动能 + 发光余量）记 semblance_released_j；已落地且接触宏格仍是
  # 同一未细分热节点时作为有限热源落入该格（0.5 s 放完），否则（飞行中、无接触、接触格已变）散入空气。
  defp release_semblance(state, id, s) do
    {cell, state} = release_cell(state, s)
    %{state | thermal: release(state.thermal, id, s, cell)}
  end

  defp release(thermal, id, s, cell) do
    energy = Magic.Semblance.stored_j(s, thermal.config["ambient_kelvin"])

    thermal =
      thermal
      |> Map.update!(:semblances, &Map.delete(&1, id))
      |> ledger(:semblance_released_j, energy)

    if cell, do: deposit_heat(%{thermal | active: true}, cell, energy), else: thermal
  end

  defp release_cell(state, %{contact: %{target: %{granularity: 0} = target}} = s) do
    if Magic.Semblance.landed?(s) do
      {current, state} = target_at(target.micro, state)
      {if(current && same_target?(current, target) && heat_node?(state, current), do: current), state}
    else
      {nil, state}
    end
  end

  defp release_cell(state, _s), do: {nil, state}

  # 拟态表的变化随同一事务下发（按 id：新值或 nil 删除）；持久化靠事务里的 thermal（含整张表）。
  defp semblance_txn(before, state) do
    after_map = semblances(state)

    delta =
      for id <- Enum.uniq(Map.keys(before) ++ Map.keys(after_map)),
          Map.get(before, id) != Map.get(after_map, id),
          into: %{},
          do: {id, Map.get(after_map, id)}

    if delta == %{}, do: %{}, else: %{semblances: delta}
  end

  # ---- 魔法增量 4：身体皮肤与局部接触组织块作为热内核外部节点（接触规则在 BodyContact；身体真值在 Scene）
  # 每个身体两节点接在拟态之后：皮肤 {T_skin, 1, 1, C_skin, 0, 1e6, 暴露 0, 0, 0, true} 与组织块 {T_tissue, …, C_tissue, …}，
  # 两者之间一条内部边（Scene 报的 G = 组织块面积 × 核心-皮肤导热）。鞋底与触碰拟态接组织块，浸没（大面积分布接触）接皮肤；
  # 接触边只连本次域内的世界节点与在册拟态。

  # 本次报告的接触：脚下偏离环境的实体格、脚所在列与身体竖向重叠的液体格（浸没比例一并回传）、碰到的已落地拟态。
  defp body_contacts(state, %{feet: {fx, fy, fz} = feet, height: height, radius: radius, area: area}) do
    config = state.thermal.config

    {sole, state} =
      case foot_target(state, %{feet: feet}) do
        {:ok, foot, state} ->
          m = state.properties.materials[foot.material]
          ambient = ambient_at(state, Damage.macro(foot))
          t = Map.get(property_state(state, foot), :temperature_kelvin, ambient)

          if Phase.liquid?(foot.material) or abs(t - ambient) <= config["tolerance_kelvin"],
            do: {[], state},
            else: {[{:node, VoxelRegion.ThermalGeometry.key(foot), Damage.macro(foot),
                     VoxelRegion.BodyContact.sole(m["thermal_conductivity"], 0.5)}], state}

        {:error, _, state} ->
          {[], state}
      end

    {x, z} = {floor(fx), floor(fz)}

    {wet, state} =
      Enum.flat_map_reduce(floor(fy)..floor(fy + height - 1.0e-9)//1, state, fn y, state ->
        case target_at({x * @micro + 4, y * @micro, z * @micro + 4}, state) do
          {%{granularity: 0} = t, state} ->
            overlap = VoxelRegion.BodyContact.overlap(fy, height, y, finite_volume(state, t))

            if Phase.liquid?(t.material) and overlap > 0,
              do: {[{overlap, {:wet, VoxelRegion.ThermalGeometry.key(t), Damage.macro(t),
                     VoxelRegion.BodyContact.immersion(area, overlap, height)}}], state},
              else: {[], state}

          {_, state} ->
            {[], state}
        end
      end)

    touched =
      for {id, s} <- semblances(state), Magic.Semblance.landed?(s),
          VoxelRegion.BodyContact.touching?(s.rest, s.radius_m, feet, height, radius),
          do: {:semblance, id, VoxelRegion.BodyContact.touch(s.radius_m, state.magic.semblance.conductivity)}

    immersed = min(1.0, Enum.sum(Enum.map(wet, &elem(&1, 0))) / height)
    sole_key = Enum.find_value(sole, fn {:node, key, _cell, _g} -> key end)
    {sole ++ Enum.map(wet, &elem(&1, 1)) ++ touched, immersed, sole_key, state}
  end

  defp body_terms([], _indices, _semblances, _count), do: {[], []}

  defp body_terms(bodies, indices, semblances, count) do
    first = count + length(semblances)
    semblance_index = semblances |> Enum.with_index(count) |> Map.new(fn {{id, _}, i} -> {id, i} end)

    edges =
      for {{_cid, b}, k} <- Enum.with_index(bodies), skin <- [first + 2 * k],
          edge <- [{skin, skin + 1, b.tissue_g} |
            for(contact <- b.contacts, j = body_peer(contact, indices, semblance_index), j != nil,
              do: {j, if(elem(contact, 0) == :wet, do: skin, else: skin + 1), elem(contact, tuple_size(contact) - 1)})],
          do: edge

    nodes = for {_cid, b} <- bodies, node <- [{b.skin_k, 1.0, 1.0, b.capacity, 0.0, 1.0e6, 0.0, 0.0, 0.0, true},
      {b.tissue_k, 1.0, 1.0, b.tissue_capacity, 0.0, 1.0e6, 0.0, 0.0, 0.0, true}], do: node
    {nodes, edges}
  end

  defp body_peer({kind, key, _cell, _g}, indices, _semblances) when kind in [:node, :wet], do: Map.get(indices, key)
  defp body_peer({:semblance, id, _g}, _indices, semblances), do: Map.get(semblances, id)

  # 一段演进后：身体吸热 q = C_skin·ΔT_skin + C_tissue·ΔT_tissue（内部边两端抵消，q 即经接触边进身体的热），记
  # body_exchange_j 并回传 Scene（同一值两端各记一笔）；其中存进组织块的 tissue_j = C_tissue·ΔT_tissue 一并回传，
  # 组织块段末温度留作下一段起点（Scene 下次报告覆盖）。接触温度诊断分两路：鞋底格温度 sole_k 与其余裸接触（浸没液体、
  # 触碰拟态）最高温度 max_contact_k，某路没有接触时为 nil（只进日志，剂量读组织块温度）。
  defp exchange_bodies(state, [], _edges, _result, _others, _indices, _done), do: state

  defp exchange_bodies(state, bodies, edges, result, others, indices, done) do
    others = List.to_tuple(others)

    bodies
    |> Enum.zip(Enum.chunk_every(result, 2))
    |> Enum.with_index()
    |> Enum.reduce(state, fn {{{cid, b}, [{skin, _, _}, {tissue, _, _}]}, k}, state ->
      node = tuple_size(others) + 2 * k
      sole = b.sole && Map.get(indices, b.sole)
      touched = for {j, i, _g} <- edges, i in [node, node + 1], j < tuple_size(others), do: {j == sole, elem(elem(others, j), 0)}
      tissue_j = b.tissue_capacity * (tissue - b.tissue_k)
      q = b.capacity * (skin - b.skin_k) + tissue_j
      bare = for {false, t} <- touched, do: t
      send(b.pid, {:body_heat, %{q_j: q, tissue_j: tissue_j, tissue_k: tissue, max_contact_k: if(bare != [], do: Enum.max(bare)),
        sole_k: Enum.find_value(touched, fn {on_sole, t} -> on_sole && t end), immersed: b.immersed, dt_s: done,
        seq: state.seq}})
      %{state | bodies: Map.put(state.bodies, cid, %{b | tissue_k: tissue}),
        thermal: ledger(state.thermal, :body_exchange_j, q)}
    end)
  end

  # 一个宏格的热节点几何：canonical 读取留在 owner 内，摘要由 ThermalGeometry 纯函数生成。
  defp thermal_cell(cell, {geometry, s}) do
    faces = VoxelRegion.ThermalGeometry.faces(cell, s.refined)
    {samples, s} = thermal_samples(s, Enum.map(faces, &elem(&1, 0)), %{})
    thermal_faces = Enum.filter(faces, fn {point, _} ->
      case Map.fetch!(samples, point) do
        nil -> false
        {target, volume} -> thermal_node?(s, target, volume)
      end
    end)
    {samples, s} = thermal_samples(s, VoxelRegion.ThermalGeometry.points(thermal_faces), samples)
    nodes = VoxelRegion.ThermalGeometry.cell(thermal_faces, s.properties.materials, samples)

    {Map.put(geometry, cell, nodes), s}
  end

  # 辐射候选域：补齐候选宏格的视线（按宏格缓存），热种子视线命中的伙伴宏格一并读取几何并入域。
  # 伙伴不是种子；只有真实升温越过容差才由既有前沿规则扩张它自己的邻域和视线。
  # 计划只列出尚缺视线的格与需要核对伙伴的种子（精确域内旧种子的伙伴已在域内）。
  defp sight_domain(state, plan, geometry) do
    {state, sights} = Enum.reduce(plan.sightless, {state, state.thermal_work.sights}, &cell_sights(&1, &2, geometry))
    extra = MapSet.difference(VoxelRegion.ThermalRadiation.partners(sights, plan.fresh), plan.cells)
    {geometry, state} = Enum.reduce(extra, {geometry, state}, &thermal_cell/2)
    {state, sights} = Enum.reduce(extra, {state, sights}, &cell_sights(&1, &2, geometry))

    {%{plan | cells: MapSet.union(plan.cells, extra), missing: MapSet.union(plan.missing, extra),
       grown: plan.grown && MapSet.union(plan.grown, extra)},
     geometry, put_in(state.thermal_work.sights, sights)}
  end

  defp cell_sights(cell, {state, sights}, geometry) do
    if Map.has_key?(sights, cell) do
      {state, sights}
    else
      range = state.thermal.config["view_range_cells"] * @micro
      # 视线只在起点宏格的热分区（持有者 × 气候区）内行进；无区域且无气候区时不检查。
      holder = if thermal_bounded?(state), do: {:holder, thermal_holder(state, cell)}
      {rows, state} = Enum.flat_map_reduce(Map.fetch!(geometry, cell), state, fn {key, node}, s ->
        {hits, s} = Enum.map_reduce(node.rays, s, fn {start, axis, sign, area}, s ->
          {hit, s} = sight(s, start, axis, sign, range, holder)
          {{hit, area}, s}
        end)
        {VoxelRegion.ThermalRadiation.sights(key, hits), s}
      end)
      {state, Map.put(sights, cell, rows)}
    end
  end

  # 沿法线读取 canonical 实占用至多 range 个微格长度：refined 或有限液柱宏格内逐微格，
  # 其余空宏格整格跳过。命中热节点返回其节点键与宏格；无热容量占用或视距内全空为天空。
  defp sight(state, _point, _axis, _sign, left, _holder) when left <= 0, do: {:sky, state}

  defp sight(state, point, axis, sign, left, holder) do
    if holder != nil and
         {:holder, thermal_holder(state, elem(Prefab.macro_slot(point), 0))} != holder,
       do: {:blocked, state},
       else: sight_step(state, point, axis, sign, left, holder)
  end

  defp sight_step(state, point, axis, sign, left, holder) do
    case target_at(point, state) do
      {nil, state} ->
        {cell, _} = Prefab.macro_slot(point)
        offset = Integer.mod(elem(point, axis), @micro)

        step =
          cond do
            Map.has_key?(state.refined, cell) or Map.has_key?(state.liquid_units, cell) -> 1
            sign > 0 -> @micro - offset
            true -> offset + 1
          end

        sight(state, put_elem(point, axis, elem(point, axis) + sign * step), axis, sign, left - step, holder)

      {target, state} ->
        target = if target.granularity == 2, do: %{target | granularity: 1}, else: target

        if thermal_node?(state, target, finite_volume(state, target)),
          do: {{VoxelRegion.ThermalGeometry.key(target), Damage.macro(target)}, state},
          else: {:sky, state}
    end
  end

  # A cell without a sparse thermal record is at rest by contract. Untouched
  # phase cells whose default enthalpy maps off ambient by more than the
  # equilibrium tolerance (generated snow/ice below its transition under a
  # warmer ambient) are not at rest in the kernel: joining as a neighbour would
  # pin them at the transition and make an unbounded sink. They stay static
  # canonical truth (an adiabatic boundary, like any cell outside the domain)
  # until an authoring, tool or transfer transaction records their enthalpy.
  defp thermal_node?(state, target, volume) do
    materials = state.properties.materials
    material = materials[target.material]
    config = state.thermal.config
    # 天然温度与静止判据都按格所在气候区：寒区里的天然冰/雪默认就在区温，静止并可作邻居入域。
    ambient = VoxelRegion.Climate.air_k(config, Damage.macro(target))

    Map.has_key?(material, "heat_capacity_per_macro") and
      (not phase_target?(state, target) or
         Map.has_key?(Map.get(state.damage, Damage.key(target), %{}), :phase_energy_j) or
         abs(
           Phase.temperature(
             target.material,
             Phase.energy(target, volume, material, ambient),
             volume,
             materials
           ) - ambient
         ) <= config["tolerance_kelvin"])
  end

  # canonical 读取留在 owner 内；计算模块仅接收当次不可变采样，不捕获 World state。
  defp thermal_samples(state, points, samples) do
    Enum.reduce(points, {samples, state}, fn point, {samples, s} ->
      if Map.has_key?(samples, point) do
        {samples, s}
      else
        {target, s} = target_at(point, s)
        target = if target && target.granularity == 2, do: %{target | granularity: 1}, else: target
        sample = if target, do: {target, finite_volume(s, target)}
        {Map.put(samples, point, sample), s}
      end
    end)
  end

  defp thermal_commit(state, rows, extra \\ %{}) do
    state = %{
      state
      | seq: state.seq + 1,
        damage: Map.merge(state.damage, Map.new(rows, &{Damage.key(&1), &1}))
    }

    txn = %{
      seq: state.seq,
      entries: [],
      coarse: [],
      property_states: rows,
      thermal: state.thermal
    } |> Map.merge(extra)

    start = System.monotonic_time(:microsecond)
    :ok = append_log(state, txn)
    persisted = System.monotonic_time(:microsecond)
    state = remember_entry(state, txn)
    fanout(state, txn)
    fanout_canonical(state, txn, [], [], state)
    broadcast = System.monotonic_time(:microsecond)

    Logger.info(
      "voxel_thermal_commit seq=#{state.seq} sim_s=#{state.thermal.elapsed_s} states=#{length(rows)} persist_us=#{persisted - start} broadcast_us=#{broadcast - persisted} active=#{state.thermal.active} supplied_j=#{state.thermal.supplied_j} environment_j=#{state.thermal.environment_j}"
    )

    state
  end

  # R8 单向转化：热提交落盘后，达到转化温度且面接触足量还原剂的节点在一笔几何事务里换成产物。
  # 占用、归属与完整度比例保留；相对环境的显热减去反应热后按产物热容折算；还原剂按化学燃料比例扣减。
  defp transform_heated_materials(state) do
    materials = state.properties.materials

    due = Enum.sort(for {key, t} <- state.damage, Transform.due?(t, materials[t.material]), do: {key, t})

    {next, products, carried} =
      Enum.reduce(due, {state, %{}, %{}}, fn {_, ore}, {s, products, carried} ->
        material = materials[ore.material]
        reductant_id = material["transform_reductant_material_id"]
        reductant = materials[reductant_id]
        volume = Damage.volume(ore.granularity) * finite_volume(s, ore)
        {rows, s} = touching_reductants(s, ore, reductant_id)
        used = Transform.reductant_j(material, volume, reductant)

        case Transform.draw(Enum.map(rows, &elem(&1, 1)), used) do
          :insufficient ->
            {s, products, carried}

          {:ok, taken} ->
            # 从未点燃的还原剂首次建立燃料余量，与点火同一初始化账。
            drawn = MapSet.new(taken, &Damage.key/1)
            initialized =
              for {true, row} <- rows, MapSet.member?(drawn, Damage.key(row)), reduce: 0.0,
                do: (sum -> sum + row.remaining_fuel_j)

            thermal =
              s.thermal
              |> Map.update(:fuel_initialized_j, initialized, &(&1 + initialized))
              |> Map.update(:transform_reductant_fuel_j, used, &(&1 + used))
              |> Map.update(:transform_j, volume * material["transform_heat_per_macro_j"],
                &(&1 + volume * material["transform_heat_per_macro_j"]))
              |> Map.update(:transform_units, round(volume * liquid_capacity(s)),
                &(&1 + round(volume * liquid_capacity(s))))

            product_id = material["transform_material_id"]
            {cell, slot} = Prefab.macro_slot(ore.micro)

            s =
              if ore.granularity == 0,
                do: put_overlay(s, 0, cell, {product_id, MmoContracts.Voxel.Skins.uniform(product_id)}),
                else: %{s | refined: Map.update!(s.refined, cell,
                  &Map.update!(&1, slot, fn {_, owner} -> {product_id, owner} end))}

            temperature = Transform.product_temperature(ore.temperature_kelvin, material, materials[product_id],
              ambient_at(s, cell))
            damage = Map.merge(s.damage, Map.new(taken, &{Damage.key(&1), &1}))

            {%{s | damage: damage, thermal: thermal},
             Map.put(products, ore.micro, %{temperature_kelvin: temperature, integrity: ore.hp / ore.max_hp}),
             Map.merge(carried, Map.new(taken, &{Damage.key(&1), %{&1 | seq: state.seq + 1, request_id: 0}}))}
        end
      end)

    if map_size(products) == 0 do
      next
    else
      cells = products |> Map.keys() |> Enum.map(&elem(Prefab.macro_slot(&1), 0)) |> Enum.uniq()
      preserved = MapSet.new(for {_, ore} <- due, Map.has_key?(products, ore.micro), do: Damage.key(ore))
      settlement = %{transform_products: products, property_states: Map.values(carried),
        prefab_phase_preserved: preserved}

      case prefab_reply(state, next, cells, settlement) do
        {:reply, {:ok, _}, committed} ->
          Logger.info("voxel_transform seq=#{committed.seq} nodes=#{map_size(products)} transform_j=#{committed.thermal.transform_j}")
          committed

        {:reply, {:error, reason}, _} ->
          Logger.error("voxel_transform failed=#{inspect(reason)}")
          state
      end
    end
  end

  # 面接触的还原剂节点（宏格或精确微格），按键排序；{是否首次初始化燃料, 带 remaining_fuel_j 的行}。
  # 接触按 1/8 m 实占用（R8-07）：有限宏格按数量向上取整到微格层（与射线、碰撞同一截断）。下方邻格取紧贴本格
  # 底面的那一层微格（不满 7/8 的散体煤与上方矿之间有空隙）；上方邻格要求本格顶层有料。
  defp touching_reductants(state, ore, reductant) do
    {_, neighbors} =
      Enum.find(VoxelRegion.ThermalGeometry.faces(Damage.macro(ore), state.refined), &(elem(&1, 0) == ore.micro))

    y = elem(ore.micro, 1)
    rows = if ore.granularity == 0, do: filled_rows(state, Damage.macro(ore)), else: @micro
    # 侧面只在本格有料的层接触，上面只在本格满到顶层时接触（微格矿的面采样本身就是紧邻）。
    neighbors = Enum.filter(neighbors, fn {point, axis, _} ->
      if axis == 1, do: elem(point, 1) < y or rows == @micro, else: elem(point, 1) - y < rows
    end)

    {targets, state} =
      Enum.reduce(neighbors, {%{}, state}, fn {point, axis, _}, {found, s} ->
        point = if axis == 1 and elem(point, 1) < elem(ore.micro, 1),
          do: put_elem(point, 1, elem(ore.micro, 1) - 1), else: point
        {target, s} = target_at(point, s)
        target = if target && target.granularity == 2, do: %{target | granularity: 1}, else: target
        if target && target.material == reductant &&
             Protection.same_holder?(s.protection, Damage.macro(ore), Damage.macro(target)),
          do: {Map.put(found, Damage.key(target), target), s},
          else: {found, s}
      end)

    rows =
      for {key, target} <- Enum.sort(targets),
          row = Map.get_lazy(state.damage, key, fn -> property_state(state, target) end),
          row.hp > 0 and not Combustion.exhausted?(row) do
        capacity = Combustion.capacity_j(state.properties.materials[reductant], combustion_volume(state, target))
        {not Map.has_key?(row, :remaining_fuel_j), Map.put_new(row, :remaining_fuel_j, capacity)}
      end

    {rows, state}
  end

  # 有限宏格按数量向上取整的实占用微格层数；无数量记录为满格。
  defp filled_rows(state, cell) do
    case Map.fetch(state.liquid_units, cell) do
      {:ok, q} -> div(q * @micro + liquid_capacity(state) - 1, liquid_capacity(state))
      :error -> @micro
    end
  end

  # 产物行在几何事务的新身份（宏格新纪元、微格原出生与归属）下建立；宏格按源完整度比例折算 HP。
  defp put_transform_products(state, products) do
    Enum.reduce(products, {state, []}, fn {micro, product}, {s, rows} ->
      {target, s} = target_at(micro, s)
      target = if target.granularity == 2, do: %{target | granularity: 1}, else: target
      row = property_state(s, target) |> Map.put(:temperature_kelvin, product.temperature_kelvin)
      row = if row.granularity == 0, do: %{row | hp: row.max_hp * product.integrity}, else: row
      s = %{s | damage: Map.put(s.damage, Damage.key(row), row)}
      {s, [row | rows]}
    end)
  end

  # 点燃只消费实际温度；热源、电热和燃烧热共用接触导热，不另设火种邻接真值。
  defp ignite_heated_materials(state, damage, ordered) do
    # 不可燃材质不需要读取或构造默认损伤记录。
    for {_, node} <- ordered, node.ignition != nil, reduce: {damage, []} do
      {rows, changed} ->
        material = node.material
        target = Map.get_lazy(rows, node.damage_key, fn -> %{node.default | seq: state.seq} end)
        if target.hp > 0 and
             not Map.get(target, :burning, false) and not Combustion.exhausted?(target) and
             Map.get(target, :temperature_kelvin, ambient_at(state, node.cell)) >= material["ignition_kelvin"] do
          row = Combustion.ignite(target, material, combustion_volume(state, target))
          {Map.put(rows, Damage.key(row), row), [{Damage.key(row), row} | changed]}
        else
          {rows, changed}
        end
    end
  end

  defp component_max_hp(state, owner) do
    for cell <- micro_owner_cells(state, MapSet.new([owner])),
        {_, {material, id}} <- Map.fetch!(state.refined, cell),
        id == owner,
        reduce: 0.0 do
      hp -> hp + Damage.max_hp(Map.fetch!(state.properties.materials, material), 1)
    end
  end

  # Saved micro damage becomes one leaf pool without restoring missing geometry or HP.
  defp migrate_component_damage(state) do
    legacy =
      state.damage
      |> Map.values()
      |> Enum.filter(&(&1.granularity == 1 and not Map.has_key?(&1, :temperature_kelvin)))
      |> Enum.group_by(& &1.owner)

    Enum.reduce(legacy, state, fn {owner, rows}, s ->
      hp = component_max_hp(s, owner)
      lost = Enum.reduce(rows, 0.0, fn t, sum -> sum + t.max_hp - t.hp end)
      target = %{hd(rows) | granularity: 2, max_hp: hp, hp: hp - lost, seq: s.seq, request_id: 0}

      damage =
        Map.drop(s.damage, Enum.map(rows, &Damage.key/1)) |> Map.put(Damage.key(target), target)

      %{s | damage: damage}
    end)
  end

  # ??????????????? B1 ????????
  defp tool_target(state, actor, %{granularity: 3, owner: {id, address}} = r, tool)
       when address in 0..5 do
    slot = {div(address, 3), rem(address, 3), r.micro}

    case Map.get(state.attachments, slot) do
      {^id, material} when material == r.material and id == r.incarnation ->
        reach = %{action: 1, size: 1, kind: elem(slot, 0), axis: elem(slot, 1), anchor: r.micro}

        case attachment_reach(state, actor, reach, tool) do
          :ok -> {:ok, attachment_identity(slot, {id, material}), state}
          {:error, reason} -> {:error, reason, state}
        end

      _ ->
        {:error, :stale_target, state}
    end
  end

  defp tool_target(state, _actor, %{granularity: 3}, _tool),
    do: {:error, :invalid_attachment, state}

  defp tool_target(state, actor, r, tool) do
    at=fn micro,s ->
      {target,s}=target_at(micro,s)
      cond do
        target==nil -> {nil,s}
        Phase.liquid?(target.material) and r.material != target.material and tool["action"] not in ["phase.cool","phase.heat"] -> {nil,s}
        finite_target?(s,target) and Map.has_key?(s.liquid_units,Damage.macro(target)) and
            not finite_phase_ray?(actor.eye,r.direction,tool["range_macro"],Damage.macro(target),
              s.liquid_units[Damage.macro(target)]/liquid_capacity(s)) -> {nil,s}
        true -> {target,s}
      end
    end
    Damage.raycast(actor.eye,r.direction,tool["range_macro"],state,at)
  end

  # Real B7 thin water must not occlude the stone below, and a phase/ice aim
  # above the actual surface must not hit the collision slab's rounded top.
  defp finite_phase_ray?(eye,direction,range,cell,height) do
    Enum.reduce_while(0..2,{0.0,range},fn axis,{enter,leave}->
      low=elem(cell,axis)*1.0
      high=low+if(axis==1,do: height,else: 1.0)
      origin=elem(eye,axis); d=elem(direction,axis)
      if d==0 do
        if origin>=low and origin<=high,do: {:cont,{enter,leave}},else: {:halt,false}
      else
        a=(low-origin)/d; b=(high-origin)/d
        enter=max(enter,min(a,b)); leave=min(leave,max(a,b))
        if enter<=leave,do: {:cont,{enter,leave}},else: {:halt,false}
      end
    end)!=false
  end

  defp attachment_identity(slot, value), do: Attachments.identity(slot, value)
  defp attachment_slots(state, id), do: for({slot, {^id, _}} <- state.attachments, do: slot)

  defp attachment_max_hp(state, target),
    do:
      state.properties.materials[target.material]["max_hp_per_macro"] *
        Attachments.units(attachment_slots(state, target.incarnation), state.properties) /
        (@micro * @micro * @micro * state.material_units_per_micro)

  defp attachment_observations(%{properties: nil}, _box), do: []

  defp attachment_observations(state, box) do
    state.attachments
    |> Enum.group_by(fn {_, {id, _}} -> id end)
    |> Enum.flat_map(fn {_, entries} ->
      cells = Attachments.macros(Enum.map(entries, &elem(&1, 0)))

      if box == nil or Enum.any?(cells, &VoxelRegion.PropertyObservation.contains?(&1, box)) do
        {slot, value} = Enum.min(entries)

        [
          property_state(state, attachment_identity(slot, value))
          |> Map.put(:observation_cells, cells)
        ]
      else
        []
      end
    end)
  end

  # 附件槽改变时，同笔更新整件 HP、逐槽显热和设备剩余能源。
  defp attachment_damage(before, state) do
    live = MapSet.new(state.attachments, fn {_, {id, _}} -> id end)
    state = %{state | attachment_owners: Map.take(state.attachment_owners, MapSet.to_list(live))}

    Enum.reduce(before.damage, {state, []}, fn
      {key, %{granularity: 4} = t}, {s, rows} ->
        if Map.get(s.attachments, Attachments.slot(t)) == {t.incarnation, t.material} do
          {s, rows}
        else
          energy =
            VoxelRegion.ThermalAttachments.volume(Attachments.slot(t), s.properties) *
              s.properties.materials[t.material]["heat_capacity_per_macro"] *
              (t.temperature_kelvin - ambient_at(s, Damage.macro(t)))

          thermal = s.thermal |> Map.update(:removed_j, energy, &(&1 + energy))
            |> Map.update(:discarded_fuel_j,Map.get(t,:remaining_fuel_j,0.0),&(&1+Map.get(t,:remaining_fuel_j,0.0)))

          {%{s | damage: Map.delete(s.damage, key), thermal: thermal},
           [%{t | hp: 0.0, flags: 1, seq: s.seq, request_id: 0} | rows]}
        end

      {key, %{granularity: 3} = t}, {s, rows} ->
        maximum = attachment_max_hp(s, t)

        cond do
          maximum == t.max_hp ->
            {s, rows}

          maximum == 0 ->
            {%{s | damage: Map.delete(s.damage, key)},
             [%{t | hp: 0.0, flags: 1, seq: s.seq, request_id: 0} | rows]}

          true ->
            row = %{t | max_hp: maximum, hp: t.hp * maximum / t.max_hp, seq: s.seq, request_id: 0}
            {%{s | damage: Map.put(s.damage, key, row)}, [row | rows]}
        end

      _, acc ->
        acc
    end)
  end

  # 权威射线决定实际微格和材料；实例操作不能穿透遮挡或跨代。
  defp same_tool_target?(%{granularity: g} = hit, %{granularity: g} = request) when g in [1, 2],
    do: hit.owner == request.owner and hit.incarnation == request.incarnation
  defp same_tool_target?(hit, request), do: same_target?(hit, request)

  defp same_target?(a, b),
    do:
      Enum.all?(
        [:micro, :incarnation, :owner, :material],
        &(Map.fetch!(a, &1) == Map.fetch!(b, &1))
      )

  defp attack_target(before, state, actor, request, target, tool) do
    # 同一会话只比较 Gate 入口时钟；World/Player 的处理抖动不改变输入相位。
    now = actor.received_us
    previous = Map.get(state.tool_sessions, actor.player)
    interval = ceil(tool["interval_seconds"] * 1_000_000)

    case Damage.admit_attack(previous, request.client_intent_seq, now, interval, actor.tick_us) do
      {:error, reason} ->
        Logger.info(
          "voxel_tool_rate request_id=#{request.request_id} client_seq=#{request.client_intent_seq} result=#{reason} clock_node=#{actor.clock_node} received_us=#{now} tat_us=#{previous.next_us} tick_us=#{actor.tick_us}"
        )

        {:reply, {:error, reason}, state}

      {:ok, session} ->
        unless previous != nil, do: Process.monitor(actor.player)

        Logger.info(
          "voxel_tool_rate request_id=#{request.request_id} client_seq=#{request.client_intent_seq} result=admitted clock_node=#{actor.clock_node} received_us=#{now} next_us=#{session.next_us} borrowed_us=#{max(0, session.next_us - interval - now)} tick_us=#{actor.tick_us}"
        )

        state = %{state | tool_sessions: Map.put(state.tool_sessions, actor.player, session)}

        cond do
          tool["action"] == "protection.claim" ->
            claim_region(before, state, actor, request, target, tool)

          tool["action"] == "circuit.toggle" ->
            toggle_switch(before, state, actor, request, target)

          # R8-04 增量 3：电源安装、补能与加热器投料退役（目录 retired_tools）。迁移前的旧目录仍可加载，其工具只被拒绝。
          tool["action"] in ["circuit.install", "circuit.feed", "heat"] ->
            {:reply, {:error, :retired_tool}, state}

          String.starts_with?(tool["action"], "combustion.") ->
            operate_combustion(before, state, actor, request, target, tool)

          tool["action"] in ["phase.cool", "phase.heat"] ->
            operate_phase(before, state, actor, request, target, tool)

          phase_target?(state,target) and not Phase.liquid?(target.material) ->
            damage_phase_solid(before, state, actor, request, target, tool)

          true ->
            material = Map.fetch!(state.properties.materials, target.material)

            amount =
              if target.granularity == 3,
                do:
                  Damage.amount(material, tool, 0) * target.max_hp / material["max_hp_per_macro"],
                else: Damage.amount(material, tool, target.granularity)

            target = %{target | hp: max(0.0, target.hp - amount), seq: state.seq + 1}

            cond do
              target.granularity == 2 and not leaf_component?(state, target.owner) ->
                {:reply, {:error, :not_a_leaf_component}, before}

              amount == 0.0 ->
                {:reply, {:error, :ineffective_tool}, state}

              target.granularity == 3 and (request.action == 2 or target.hp == 0.0) ->
                destroy_attachment(before, state, actor, target)

              request.action == 2 ->
                dismantle_target(before, state, actor, target)

              target.hp == 0.0 and target.granularity == 2 ->
                dismantle_target(before, state, actor, target)

              target.hp == 0.0 ->
                {state, settlement} =
                  if target.material in state.production_materials and drop_table(state, target.material) == nil do
                    settle_material(
                      state,
                      actor.cid,
                      target.material,
                      recover_units(state,target,@micro * @micro * @micro * state.material_units_per_micro)
                    )
                  else
                    {state, %{}}
                  end

                destroy_target(
                  before,
                  %{state | damage: Map.put(state.damage, Damage.key(target), target)},
                  target,
                  Map.put(settlement, :recovery_cid, actor.cid)
                )

              true ->
                state = %{
                  state
                  | seq: state.seq + 1,
                    damage: Map.put(state.damage, Damage.key(target), target)
                }

                txn = %{
                  seq: state.seq,
                  entries: [],
                  coarse: [],
                  property_states: [target],
                  epochs: %{}
                }

                case append_log(state, txn) do
                  :ok ->
                    state = remember_entry(state, txn)
                    fanout(state, txn)
                    fanout_canonical(state, txn, [], [], state)

                    Logger.info(
                      "voxel_damage seq=#{state.seq} target=#{inspect(target.micro)} material=#{target.material} hp=#{target.hp} max_hp=#{target.max_hp} geometry=false"
                    )

                    {:reply, {:ok, state.seq}, state}

                  {:error, reason} ->
                    {:reply, {:error, reason}, before}
                end
            end
        end
    end
  end

  # 全局系统功能（R8-04 增量 2）：开关是材料（目录 circuit_switch），不是设备。G 翻转命中格（微格按 granularity 1
  # 热身份）或附件整件属性行上的 closed，缺省断开；与其他属性一样随日志持久化并复制，电路在下一次求解时读取。
  defp toggle_switch(before, state, actor, request, target) do
    if request.action == 1 and Map.get(state.properties.materials[target.material], "circuit_switch", false) do
      identity = Map.take(target, [:micro, :granularity, :incarnation, :owner, :material])
      identity = if identity.granularity == 2, do: %{identity | granularity: 1}, else: identity
      row = property_state(state, identity)
      # 复制记录不带请求号（属性批次要求 0，客户端据此拒收整帧；switch-02 实跑）。
      row = Map.merge(row, %{closed: not Map.get(row, :closed, false), seq: state.seq + 1, request_id: 0})
      next = %{state | seq: state.seq + 1, damage: Map.put(state.damage, Damage.key(row), row)}
      txn = %{seq: next.seq, entries: [], coarse: [], property_states: [row], epochs: %{}}

      case append_log(next, txn) do
        :ok ->
          next = remember_entry(next, txn)
          fanout(next, txn)
          fanout_canonical(next, txn, [], [], before)

          Logger.info(
            "voxel_switch seq=#{next.seq} cid=#{actor.cid} granularity=#{row.granularity} micro=#{inspect(row.micro)} incarnation=#{row.incarnation} closed=#{row.closed}"
          )

          {:reply, {:ok, next.seq}, next}

        {:error, reason} ->
          {:reply, {:error, reason}, before}
      end
    else
      {:reply, {:error, :not_a_switch}, state}
    end
  end

  # ---- 魔法增量 1：施放（Voxim Docs/Magic.md §4、§10）
  # 施法者能量与蓄能石 stored_j 在同一笔事务里原子改变；施法的热只经 thermal.sources 有限热源进世界，
  # 由热内核按守恒结算。校验失败（间隔、射线、施法域、目标、脚下、权限、目标已有热源）不扣能量、不改世界。

  # quote_windup_s（Hello 28）：只有报价回复带本次报价的前摇 Σ(T_adj + T_inj)（与施放计时同一 `Cost.quote` 结果），
  # 登录推送与施放结算后的状态为 0。
  defp caster_view(state, cid, quote, spent, windup_s) do
    %{seq: state.seq, energy_j: Map.get(state.caster_energy, cid, 0.0), capacity_j: state.magic.capacity_j,
      coherence: state.magic.coherence, quote_j: quote.total_j, quote_s: quote.structure, spent_j: spent,
      quote_windup_s: windup_s}
  end

  # 拟态只能比环境热（吸热 / 制冷待世界书提案）；低于环境温度的程序与其他非法程序同为 invalid_program。
  defp warm_semblance(%{steps: [%{sym: "form.semblance", args: %{"temperature_k" => t}} | _]}, ambient) when t < ambient,
    do: {:error, :invalid_program}

  defp warm_semblance(_program, _ambient), do: :ok

  # 施放前摇（§13.6）：立即校验（间隔、目标、施法域、脚下、权限）失败即刻拒绝；通过后不结算，记一条待施放并广播
  # 施放记录，前摇到期（`{:settle_cast, …}`）再以开始时捕获的施法者与意图重做同一校验并结算。前摇中再施放 = cast_too_soon。
  defp cast_spell(state, from, actor, request, program, quote) do
    with false <- Map.has_key?(state.pending_casts, actor.cid),
         {:ok, _checked, _state} <- check_cast(state, actor, request, program) do
      begin_cast(state, from, actor, request, program, quote)
    else
      true -> {:reply, {:error, :cast_too_soon}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp check_cast(state, actor, request, program) do
    previous = Map.get(state.spell_sessions, actor.player)

    with {:ok, session} <- admit_cast(previous, request, actor, state.magic),
         {:ok, effect, state} <- spell_effect(state, actor, request, program),
         {:ok, foot, state} <- foot_target(state, actor),
         :ok <- spell_subject(state, effect),
         true <- Protection.permitted?(state.protection, {:character, actor.cid}, effect.cells ++ [Damage.macro(foot)]) do
      {:ok, %{session: session, previous: previous, effect: effect, foot: foot}, state}
    else
      false -> {:error, :protected_region}
      {:error, reason} -> {:error, reason}
      {:error, reason, _} -> {:error, reason}
    end
  end

  # 施放记录：t0 = World 墙钟（与拟态 t0_us 同源），出发点 = 手边（与投掷拟态同一来源），程序字节原样。
  defp begin_cast(state, from, actor, request, program, quote) do
    {dx, dy, dz} = request.direction
    {ex, ey, ez} = actor.eye

    record = %{live: 1, t0_us: System.system_time(:microsecond), steps: quote.steps, program: request.program,
      origin: {ex + dx * @hand_reach, ey + dy * @hand_reach, ez + dz * @hand_reach}}

    case commit_casts(state, %{actor.cid => record}) do
      {:ok, next} ->
        Process.send_after(self(), {:settle_cast, actor.cid, record.t0_us}, ceil(quote.windup_s * 1000))

        Logger.info(
          "voxel_cast_begin seq=#{next.seq} cid=#{actor.cid} request_id=#{request.request_id} t0_us=#{record.t0_us} " <>
            "windup_s=#{quote.windup_s} physical_j=#{quote.physical_j} loss_j=#{quote.loss_j} steps=#{inspect(quote.steps)}"
        )

        pending = %{record: record, from: from, actor: actor, request: request, program: program, quote: quote}
        {:noreply, %{next | pending_casts: Map.put(next.pending_casts, actor.cid, pending)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # 结算：成功与走火由 settle_spell 提交（事务带 live=0 记录）；此时校验失败（如目标已失效）照常拒绝、不扣能，
  # 另提交一笔只带 live=0 / outcome 2 的事务。
  defp settle_cast(state, pending) do
    case check_cast(state, pending.actor, pending.request, pending.program) do
      {:ok, checked, next} ->
        settle_spell(next, pending.actor, pending.request, checked, pending.quote)

      {:error, reason} ->
        case commit_casts(state, %{pending.actor.cid => %{live: 0, outcome: 2}}) do
          {:ok, next} ->
            Logger.info("voxel_cast_rejected seq=#{next.seq} cid=#{pending.actor.cid} request_id=#{pending.request.request_id} reason=#{reason}")
            {{:error, reason}, next}

          {:error, error} ->
            {{:error, error}, state}
        end
    end
  end

  # 只带待施放记录的事务（同只带落体帧的事务）：日志里是空事务，保持 seq 连续；记录只随本次广播。
  defp commit_casts(state, casts) do
    next = %{state | seq: state.seq + 1}
    txn = %{seq: next.seq, entries: [], coarse: [], casts: casts}

    with :ok <- append_log(next, txn) do
      next = remember_entry(next, txn)
      fanout(next, txn)
      fanout_canonical(next, txn, [], [], state)
      {:ok, next}
    end
  end

  # 施法的作用对象与需要地块权限的宏格。加热 / 取能：眼睛射线目标。拟态：自手边成形（可抛出），落点格与接触格。
  # 驱散：线上给出的拟态 id，须存在且当前位置在本地施法域内。
  defp spell_effect(state, actor, request, %{steps: [%{sym: sym, args: args}]}) when sym in ["act.heat", "energy.draw"] do
    with {:ok, target, state} <- spell_target(state, actor, request, state.magic),
         do: {:ok, %{sym: sym, args: args, target: target, cells: [Damage.macro(target)]}, state}
  end

  defp spell_effect(state, actor, request, %{steps: [%{sym: "act.dispel"}]}) do
    id = Map.get(request, :semblance)

    case semblances(state) do
      %{^id => s} ->
        {px, py, pz} = position = Magic.Semblance.current(s)
        {ex, ey, ez} = actor.eye

        if (px - ex) ** 2 + (py - ey) ** 2 + (pz - ez) ** 2 > state.magic.local_domain_m ** 2 do
          {:error, :out_of_domain, state}
        else
          {cell, state} = release_cell(state, s)
          {:ok, %{sym: "act.dispel", id: id, semblance: s, release: cell, cells: [Magic.Semblance.macro(position)]}, state}
        end

      _ ->
        {:error, :stale_target, state}
    end
  end

  defp spell_effect(state, actor, request, %{steps: [%{sym: "form.semblance", args: form} | throw]}) do
    owned = Enum.count(semblances(state), fn {_, s} -> s.caster == actor.cid end)
    {dx, dy, dz} = request.direction
    {ex, ey, ez} = actor.eye
    hand = {ex + dx * @hand_reach, ey + dy * @hand_reach, ez + dz * @hand_reach}

    velocity =
      case throw do
        [%{args: %{"speed_mps" => v}}] -> {dx * v, dy * v, dz * v}
        [] -> {0.0, 0.0, 0.0}
      end

    if owned >= state.magic.max_semblances do
      {:error, :semblance_limit, state}
    else
      case Magic.Semblance.trace(actor.eye, hand, velocity, form["radius_m"], state.magic.range_m, state, &semblance_cast/4) do
        {:miss, state} ->
          {:error, :out_of_domain, state}

        {{:free, point}, state} ->
          launch = %{origin: point, velocity: velocity, flight_s: 0.0, rest: point, contact: nil}
          {:ok, %{sym: "form.semblance", args: form, launch: launch, cells: [Magic.Semblance.macro(point)]}, state}

        {{:hit, t, rest, target}, state} ->
          node = if target.granularity == 2, do: %{target | granularity: 1}, else: target
          contact = %{target: target, key: VoxelRegion.ThermalGeometry.key(node), cell: Damage.macro(target)}
          launch = %{origin: hand, velocity: velocity, flight_s: t, rest: rest, contact: contact}
          {:ok, %{sym: "form.semblance", args: form, launch: launch,
                  cells: Enum.uniq([Magic.Semblance.macro(rest), contact.cell])}, state}
      end
    end
  end

  # 拟态弹道的 canonical 求交：同一 Amanatides-Woo 射线，命中返回目标与进入的微格。
  defp semblance_cast(origin, direction, length, state) do
    at = fn micro, s ->
      {target, s} = target_at(micro, s)
      {target && {target, micro}, s}
    end

    case Damage.raycast(origin, direction, length, state, at) do
      {:ok, hit, state} -> {hit, state}
      {:error, :no_target, state} -> {nil, state}
    end
  end

  # 施法间隔与工具同一 GCRA（Gate 入口时钟、一个权威 tick 的相位借用）；过快即 cast_too_soon。
  defp admit_cast(previous, request, actor, magic) do
    case Damage.admit_attack(previous, request.client_intent_seq, actor.received_us, magic.cast_interval_us, actor.tick_us) do
      {:error, :tool_cooldown} -> {:error, :cast_too_soon}
      result -> result
    end
  end

  # 施法者眼睛射线（与工具同一权威射线，射程 range_m）：首个命中必须是请求的目标，且其宏格中心在本地施法域内。
  defp spell_target(state, actor, request, magic) do
    case tool_target(state, actor, request, %{"range_macro" => magic.range_m, "action" => "magic"}) do
      {:error, :no_target, state} ->
        {:error, :out_of_domain, state}

      {:ok, target, state} ->
        {x, y, z} = Damage.macro(target)
        {ex, ey, ez} = actor.eye

        cond do
          not same_tool_target?(target, request) ->
            {:error, :stale_target, state}

          (x + 0.5 - ex) ** 2 + (y + 0.5 - ey) ** 2 + (z + 0.5 - ez) ** 2 > magic.local_domain_m ** 2 ->
            {:error, :out_of_domain, state}

          true ->
            {:ok, target, state}
        end
    end
  end

  # 脚下宏格：position 是胶囊中心，feet = 中心下移半高；+0.5 容忍贴地 skin（同 NPC Body 的脚格约定）。
  # 施法留热与走火只能作为未细分宏格的有限热源落地；脚下不是这样的格（腾空、细分构件、空气）时拒绝施放。
  defp foot_target(state, actor) do
    {fx, fy, fz} = actor.feet
    {x, y, z} = {floor(fx), floor(fy + 0.5) - 1, floor(fz)}

    case target_at({x * @micro + 4, y * @micro, z * @micro + 4}, state) do
      {%{granularity: 0} = foot, state} ->
        if heat_node?(state, foot), do: {:ok, foot, state}, else: {:error, :no_footing, state}

      {_, state} ->
        {:error, :no_footing, state}
    end
  end

  defp heat_node?(state, target),
    do: is_number(state.properties.materials[target.material]["heat_capacity_per_macro"])

  # 动词的作用对象：加热 = 带热容的未细分宏格且尚无热源；取能 = 未细分的蓄能石宏格；拟态与驱散在 spell_effect 已定。
  defp spell_subject(state, %{sym: "act.heat", target: target}) do
    cond do
      target.granularity != 0 or not heat_node?(state, target) -> {:error, :invalid_target}
      Map.has_key?(state.thermal.sources, Damage.macro(target)) -> {:error, :heat_source_busy}
      true -> :ok
    end
  end

  defp spell_subject(state, %{sym: "energy.draw", target: target}) do
    if target.granularity == 0 and VoxelRegion.Circuit.battery?(state.properties.materials[target.material]),
      do: :ok,
      else: {:error, :invalid_target}
  end

  defp spell_subject(_state, _effect), do: :ok

  # 取能的构型损耗从取得的能量里付（可支付 = 余额 + η·ΔE），否则空施法者永远取不了能。
  # 走火：扣 min(总支出, 余额) 全部落脚下，不产生其他效果。账：石减少 = caster_drawn_j + draw_loss_j；
  # 施法支出 spent = spell_heat_j + semblance_created_j + cast_waste_j。
  # 拟态：新记录 id = {本事务 seq, 0}，物理能量记 semblance_created_j；驱散：剩余能量记 semblance_released_j
  # 并作为有限热源落入接触宏格（或散入空气），已发生的燃烧与热不撤销。
  defp settle_spell(before, actor, request, %{session: session, previous: previous, effect: effect, foot: foot}, quote) do
    magic = before.magic
    cid = actor.cid
    seq = before.seq + 1
    balance = Map.get(before.caster_energy, cid, 0.0)
    stone = if effect.sym == "energy.draw", do: property_state(before, effect.target)
    draw = stone && Magic.Cost.draw(effect.args["energy_j"], Map.get(stone, :stored_j, 0.0), balance, magic)
    available = if draw, do: balance + draw.gained_j, else: balance
    outcome = Magic.Cost.misfire(quote, available, magic)
    thermal = %{before.thermal | active: true}

    {spent, left, rows, thermal} =
      case {outcome, effect} do
        {nil, %{sym: "act.heat", target: target, args: args}} ->
          source = %{target: target, power_w: args["power_w"], remaining_j: args["energy_j"]}
          thermal = %{thermal | sources: Map.put(thermal.sources, Damage.macro(target), source)}

          {quote.total_j, balance - quote.total_j, [],
           thermal |> ledger(:spell_heat_j, args["energy_j"]) |> cast_waste(foot, quote.loss_j)}

        {nil, %{sym: "energy.draw", target: target}} ->
          row = Map.put(stone, :stored_j, Map.get(stone, :stored_j, 0.0) - draw.taken_j)

          thermal =
            thermal
            |> deposit_heat(target, draw.loss_j)
            |> ledger(:caster_drawn_j, draw.gained_j)
            |> ledger(:draw_loss_j, draw.loss_j)
            |> cast_waste(foot, quote.loss_j)

          {quote.loss_j, available - quote.total_j, [row], thermal}

        {nil, %{sym: "form.semblance", args: form, launch: launch}} ->
          s = Magic.Semblance.new(cid, form, magic, Map.put(launch, :t0_us, System.system_time(:microsecond)))

          thermal =
            thermal
            |> Map.update(:semblances, %{{seq, 0} => s}, &Map.put(&1, {seq, 0}, s))
            |> ledger(:semblance_created_j, quote.physical_j)
            |> cast_waste(foot, quote.loss_j)

          {quote.total_j, balance - quote.total_j, [], thermal}

        {nil, %{sym: "act.dispel", id: id, semblance: s, release: cell}} ->
          thermal =
            thermal
            |> release(id, s, cell)
            |> cast_waste(foot, quote.loss_j)

          {quote.total_j, balance - quote.total_j, [], thermal}

        _misfire ->
          spent = min(quote.total_j, balance)
          {spent, balance - spent, [], cast_waste(thermal, foot, spent)}
      end

    rows = Enum.map(rows, &%{&1 | seq: seq, request_id: 0})

    next = %{
      before
      | seq: seq,
        thermal: thermal,
        caster_energy: Map.put(before.caster_energy, cid, left),
        spell_sessions: Map.put(before.spell_sessions, actor.player, session),
        damage: Enum.reduce(rows, before.damage, &Map.put(&2, Damage.key(&1), &1))
    }

    txn =
      %{seq: seq, entries: [], coarse: [], property_states: rows, thermal: thermal, caster_energy: %{cid => left},
        casts: %{cid => %{live: 0, outcome: if(outcome, do: 1, else: 0)}}}
      |> Map.merge(semblance_txn(semblances(before), next))

    case append_log(next, txn) do
      :ok ->
        unless previous, do: Process.monitor(actor.player)
        next = remember_entry(next, txn)
        fanout(next, txn)
        fanout_canonical(next, txn, [], [], before)

        Logger.info(
          "voxel_spell seq=#{seq} cid=#{cid} request_id=#{request.request_id} sym=#{effect.sym} outcome=#{outcome || :cast} " <>
            "structure=#{quote.structure} quote_j=#{quote.total_j} loss_j=#{quote.loss_j} windup_s=#{quote.windup_s} " <>
            "spent_j=#{spent} energy_j=#{left} " <>
            "cells=#{inspect(effect.cells)} foot=#{inspect(Damage.macro(foot))}"
        )

        {{:ok, %{seq: seq, outcome: outcome, caster: caster_view(next, cid, quote, spent, 0.0)}}, next}

      {:error, reason} ->
        {{:error, reason}, before}
    end
  end

  defp ledger(thermal, key, value), do: Map.update(thermal, key, value, &(&1 + value))

  defp cast_waste(thermal, foot, energy),
    do: thermal |> deposit_heat(foot, energy) |> ledger(:cast_waste_j, energy)

  # 同格已有热源（同一施法的脚下与目标、连续施法）时并入：余量与功率相加，仍在一个热提交内放完。
  defp deposit_heat(thermal, _target, energy) when energy <= 0, do: thermal

  defp deposit_heat(thermal, target, energy) do
    cell = Damage.macro(target)
    source = Map.get(thermal.sources, cell, %{target: target, power_w: 0.0, remaining_j: 0.0})
    source = %{source | power_w: source.power_w + energy / @deposit_seconds, remaining_j: source.remaining_j + energy}
    %{thermal | sources: Map.put(thermal.sources, cell, source)}
  end

  # Global system: a tool operates on the exact hit thermal node; HP continues
  # to belong to the existing macro / leaf / attachment damage authority.
  defp operate_combustion(before, state, actor, request, target, tool) do
    material = Map.fetch!(state.properties.materials, target.material)

    cond do
      request.action != 1 or state.thermal == nil ->
        {:reply, {:error, :thermal_unavailable}, before}

      not Combustion.combustible?(material) or not is_number(material["heat_capacity_per_macro"]) ->
        {:reply, {:error, :not_combustible}, before}

      true ->
        granularity =
          case target.granularity do
            2 -> 1
            3 -> 4
            other -> other
          end

        row =
          property_state(
            state,
            %{target | granularity: granularity}
            |> Map.take([:micro, :granularity, :incarnation, :owner, :material])
          )

        row = Map.put(row, :request_id, request.request_id)
        combustion_operation(before, state, actor, row, tool, material)
    end
  end

  defp combustion_volume(state, %{granularity: 4} = target),
    do: VoxelRegion.ThermalAttachments.volume(Attachments.slot(target), state.properties)

  defp combustion_volume(state, target), do: Damage.volume(target.granularity) * finite_volume(state, target)

  defp combustion_operation(before, state, actor, target, tool, material) do
    volume = combustion_volume(state, target)
    capacity = material["heat_capacity_per_macro"] * volume
    ambient = ambient_at(state, Damage.macro(target))
    temperature = Map.get(target, :temperature_kelvin, ambient)
    units = ceil(tool["fuel_units"] * state.material_units_per_micro * volume)
    action = tool["action"]

    cond do
      action == "combustion.ignite" and Map.get(target, :burning, false) ->
        {:reply, {:error, :already_burning}, before}

      action == "combustion.ignite" and Map.get(target, :remaining_fuel_j, 1.0) <= 0 ->
        {:reply, {:error, :fuel_exhausted}, before}

      action == "combustion.extinguish" and not Map.get(target, :burning, false) ->
        {:reply, {:error, :not_burning}, before}

      Map.get(state.material_balances, {actor.cid, tool["fuel_material_id"]}, 0) < units ->
        {:reply, {:error, :insufficient_material}, before}

      true ->
        {state, settlement} = settle_material(state, actor.cid, tool["fuel_material_id"], -units)

        {row, thermal} =
          if action == "combustion.ignite" do
            energy = tool["heat_energy_j"] * volume
            row = Map.put(target, :temperature_kelvin, temperature + energy / capacity)

            row =
              if row.temperature_kelvin >= material["ignition_kelvin"],
                do: Combustion.ignite(row, material, volume),
                else: row

            thermal =
              state.thermal
              |> Map.update!(:supplied_j, &(&1 + energy))
              |> Map.update(:ignition_j, energy, &(&1 + energy))

            {row, thermal}
          else
            removed =
              min(max(0.0, capacity * (temperature - ambient)), tool["cooling_energy_j"] * volume)

            row =
              target
              |> Combustion.extinguish()
              |> Map.put(:temperature_kelvin, temperature - removed / capacity)

            thermal =
              state.thermal
              |> Map.update(:removed_j, removed, &(&1 + removed))
              |> Map.update(:combustion_removed_j, removed, &(&1 + removed))

            {row, thermal}
          end

        commit_combustion(before, %{state | thermal: thermal}, row, settlement)
    end
  end

  defp commit_combustion(before, state, row, settlement) do
    row = %{row | seq: state.seq + 1, request_id: 0}
    thermal = %{state.thermal | active: true}

    next =
      %{
        state
        | seq: state.seq + 1,
          damage: Map.put(state.damage, Damage.key(row), row),
          thermal: thermal
      }
      |> rebuild_thermal_work()

    initialized = if Map.has_key?(row,:remaining_fuel_j) and not Map.has_key?(Map.get(before.damage,Damage.key(row),%{}),:remaining_fuel_j),do: row.remaining_fuel_j,else: 0.0
    next = %{next | thermal: Map.update(next.thermal,:fuel_initialized_j,initialized,&(&1+initialized))}
    txn =
      Map.merge(
        %{seq: next.seq, entries: [], coarse: [], property_states: [row], thermal: next.thermal},
        settlement
      )

    case append_log(next, txn) do
      :ok ->
        next = remember_entry(next, txn)
        fanout(next, txn)
        fanout_canonical(next, txn, [], [], before)

        Logger.info(
          "voxel_combustion_input seq=#{next.seq} target=#{inspect(row.micro)} granularity=#{row.granularity} burning=#{Map.get(row, :burning, false)} remaining_fuel_j=#{Map.get(row, :remaining_fuel_j, 0.0)} power_w=#{Map.get(row, :power_w, 0.0)}"
        )

        {:reply, {:ok, next.seq}, next}

      {:error, reason} ->
        {:reply, {:error, reason}, before}
    end
  end

  defp leaf_component?(state, owner),
    do: not Enum.any?(state.instances, fn {_, i} -> Map.get(i, :parent_id, {0, 0}) == owner end)

  defp dismantle_target(before, _state, _actor, %{granularity: 0, owner: {0,0}}) do
    {:reply, {:error, :not_a_component}, before}
  end

  defp dismantle_target(before, state, actor, %{granularity: 0} = target) do
    units = recover_units(state,target,@micro*@micro*@micro*state.material_units_per_micro)
    {state,settlement} = settle_material(state,actor.cid,target.material,units)
    destroy_target(before,state,target,Map.put(settlement,:recovery_cid,actor.cid))
  end

  defp dismantle_target(before, state, actor, target) do
    # 拆卸只认权威射线命中的叶子 occurrence，不采用客户端选中的父级。
    if not leaf_component?(state, target.owner) do
      {:reply, {:error, :not_a_leaf_component}, before}
    else
      ids = MapSet.new([target.owner])
      cells = micro_owner_cells(state, ids)

      amounts = for cell <- cells, {slot,{material,owner}} <- Map.fetch!(state.refined,cell),
        owner==target.owner and material in state.production_materials, reduce: %{} do
          counts ->
            row=%{micro: Prefab.micro_coord(cell,slot),granularity: 1,incarnation: elem(owner,0),owner: owner,material: material}
            units=recover_units(state,row,state.material_units_per_micro)
            Map.update(counts,material,units,&(&1+units))
        end
      {state,balances}=Enum.reduce(amounts,{state,%{}},fn {material,units},{s,balances}->
        {s,settlement}=settle_material(s,actor.cid,material,units)
        {s,Map.merge(balances,settlement.material_balances)}
      end)

      settlement = %{material_balances: balances, recovery_cid: actor.cid}
      # Include a tombstone even when a small leaf dies on its first hit.
      damaged = %{before | damage: Map.put(before.damage, Damage.key(target), target)}

      case prefab_reply(damaged, clear_subtree(state, ids, cells), cells, settlement) do
        {:reply, {:error, reason}, _} -> {:reply, {:error, reason}, before}
        result -> result
      end
    end
  end

  # 只读取实际剩余燃料；回收比例和取整规则由燃烧模块统一定义。
  defp recover_units(state, target, units) do
    row = Map.get(state.damage, Damage.key(target), target)
    volume = if Map.has_key?(row, :remaining_fuel_j), do: combustion_volume(state, target)
    Combustion.recover_units(row, state.properties.materials[target.material], volume, units)
  end

  defp attachment_recovery(state, slots) do
    Enum.reduce(slots,0,fn slot,total ->
      row=Attachments.identity(slot,Map.fetch!(state.attachments,slot)) |> Map.put(:granularity,4)
      total+recover_units(state,row,Attachments.units([slot],state.properties))
    end)
  end

  defp destroy_target(before, state, %{granularity: 0} = target, settlement) do
    case apply_batch(state, [{Damage.macro(target), 0}], false, settlement) do
      {:ok, next} -> {:reply, {:ok, next.seq}, next}
      {:error, reason} -> {:reply, {:error, reason}, before}
    end
  end

  # Macro epochs track replacement even back to the same material. Refined identity
  # is its exact micro + occurrence birth; neighbouring damage survives local edits.
  defp damage_geometry(before, state, cells, macro_cells, preserved_phase) do
    cells = MapSet.new(cells)
    epochs = Map.new(macro_cells, &{&1, state.seq})

    removed =
      before.damage
      |> Map.values()
      |> Enum.filter(fn t ->
        if t.granularity not in [3, 4] and MapSet.member?(cells, Damage.macro(t)) do
          {current, _} = target_at(t.micro, %{state | epochs: Map.merge(state.epochs, epochs)})

          current == nil or
            if t.granularity == 1,
              do: not same_target?(current, t),
              else: Damage.key(current) != Damage.key(t)
        else
          false
        end
      end)

    damage = Map.drop(state.damage, Enum.map(removed, &Damage.key/1))
    states = Enum.map(removed, &%{&1 | hp: 0.0, flags: 1, seq: state.seq, request_id: 0})

    thermal =
      if state.thermal do
        removed_j =
          Enum.reduce(removed, 0.0, fn t, sum ->
            if Map.has_key?(t, :temperature_kelvin) and not phase_target?(before,t) and
                 not MapSet.member?(preserved_phase,Damage.key(t)),
              do:
                sum +
                  state.properties.materials[t.material]["heat_capacity_per_macro"] *
                    Damage.volume(t.granularity) * finite_volume(before, t) *
                    (t.temperature_kelvin - ambient_at(state, Damage.macro(t))),
              else: sum
          end)

        sources =
          Map.reject(state.thermal.sources, fn {cell, source} ->
            if MapSet.member?(cells, cell) do
              {current, _} = target_at(source.target.micro, state)
              current == nil or not same_target?(current, source.target)
            else
              false
            end
          end)

        discarded =
          Enum.reduce(state.thermal.sources, 0.0, fn {cell, s}, sum ->
            sum + if(Map.has_key?(sources, cell), do: 0.0, else: s.remaining_j)
          end)

        # 蓄能石随格移除时储能不进库存（材料单位不带电），记入移除账。
        stored_j = Enum.reduce(removed, 0.0, fn t, sum -> sum + Map.get(t, :stored_j, 0.0) end)

        %{state.thermal | active: true, sources: sources}
        |> Map.update(:removed_j, removed_j, &(&1 + removed_j))
        |> Map.update(:circuit_removed_j, stored_j, &(&1 + stored_j))
        |> Map.update(:discarded_source_j, discarded, &(&1 + discarded))
        |> Map.update(:discarded_fuel_j,discarded_fuel(removed,preserved_phase),&(&1+discarded_fuel(removed,preserved_phase)))
      end

    {state, attachment_states} =
      attachment_damage(before, %{state | damage: damage, thermal: thermal})

    thermal = state.thermal
    metadata = %{property_states: states ++ attachment_states, epochs: epochs}
    metadata = if thermal, do: Map.put(metadata, :thermal, thermal), else: metadata
    affected = cells |> Enum.flat_map(&[&1 | VoxelRegion.Thermal.neighbors(&1)])

    state =
      drop_thermal_geometry(%{state | epochs: Map.merge(state.epochs, epochs), thermal: thermal}, affected)

    state =
      if before.attachments == state.attachments, do: state, else: rebuild_thermal_work(state)

    {state, metadata}
  end

  defp discarded_fuel(removed, preserved),
    do: Enum.reduce(removed, 0.0, fn t, sum ->
      if MapSet.member?(preserved, Damage.key(t)), do: sum, else: sum + Map.get(t, :remaining_fuel_j, 0.0)
    end)

  defp replay_damage(state, txn) do
    damage =
      Enum.reduce(Map.get(txn, :property_states, []), state.damage, fn t, acc ->
        if t.flags == 1, do: Map.delete(acc, Damage.key(t)), else: Map.put(acc, Damage.key(t), t)
      end)

    %{
      state
      | damage: damage,
        epochs: Map.merge(state.epochs, Map.get(txn, :epochs, %{})),
        attachment_serial:
          Map.get(txn, :attachment_serial, max(state.attachment_serial, txn.seq)),
        attachment_owners: Map.get(txn, :attachment_owners, state.attachment_owners),
        material_units_per_micro:
          Map.get(txn, :material_units_per_micro, state.material_units_per_micro),
        liquid_active: MapSet.new(Map.get(txn, :liquid_active, Liquid.neighborhood(Map.keys(state.liquid_units)))),
        thermal: Map.get(txn, :thermal, state.thermal),
        phase_inventory: Map.merge(state.phase_inventory, Map.get(txn, :phase_inventory, %{})),
        material_supplies: Map.merge(state.material_supplies, Map.get(txn, :material_supplies, %{})),
        craft_ledger: Map.get(txn, :craft_ledger, state.craft_ledger),
        food_ledger: Map.get(txn, :food_ledger, state.food_ledger),
        placed_by: merge_placed(state.placed_by, Map.get(txn, :placed_by, %{})),
        protection: Protection.apply(state.protection, Map.get(txn, :protection, %{})),
        macro_owners: merge_placed(state.macro_owners, Map.get(txn, :macro_owners, %{})),
        instances: Map.get(txn,:prefab_instances,state.instances),
        material_balances:
          Map.merge(state.material_balances, Map.get(txn, :material_balances, %{})),
        caster_energy: Map.merge(state.caster_energy, Map.get(txn, :caster_energy, %{}))
    }
  end

  # nil = 这一格的放置记录被清掉。
  defp merge_placed(placed_by, delta) do
    {cleared, set} = Enum.split_with(delta, fn {_, cid} -> cid == nil end)
    placed_by |> Map.drop(Enum.map(cleared, &elem(&1, 0))) |> Map.merge(Map.new(set))
  end

  # Canonical ownership deltas share the transaction with the actual geometry edit.
  # No-op edits retain identity; nil removes a row on both replay backends.
  defp ownership_metadata(txn,before,state,cells) do
    Enum.reduce([:placed_by,:macro_owners],txn,fn key,txn ->
      old = Map.fetch!(before,key)
      new = Map.fetch!(state,key)
      delta = for cell <- cells, Map.get(old,cell) != Map.get(new,cell), into: %{}, do: {cell,Map.get(new,cell)}
      if map_size(delta) == 0, do: txn, else: Map.put(txn,key,delta)
    end)
  end

  defp balance_state(state, cid, material) do
    %{
      seq: state.seq,
      material: material,
      balance: Map.get(state.material_balances, {cid, material}, 0),
      cost: build_cost(state, material)
    }
  end

  defp drop_table(state, material), do: get_in(state, [Access.key(:properties), Access.key(:materials, %{}), material, "drops"])

  # [0, 1) 的确定性骰子；seq + 1 是这一笔事务将要取得的序号。
  defp drop_roll(state, {x, y, z}, index) do
    <<n::32, _::binary>> =
      :crypto.hash(:sha256, <<state.cv::64, state.seq + 1::64, x::64-signed, y::64-signed, z::64-signed, index::16>>)

    n / 4_294_967_296
  end

  defp build_cost(state, material),
    do: get_in(state, [Access.key(:properties), Access.key(:materials, %{}), material, "place_units"]) ||
          @micro * @micro * @micro * state.material_units_per_micro

  defp settle_material(state, cid, material, delta) do
    key = {cid, material}
    balance = Map.get(state.material_balances, key, 0) + delta

    {%{state | material_balances: Map.put(state.material_balances, key, balance)},
     %{material_balances: %{key => balance}}}
  end

  defp supply_materials(before, {cid, _} = key, quantities) do
    {next, balances, inventory, energy, phase_units} =
      Enum.reduce(quantities, {before, %{}, %{}, 0.0, 0}, fn {material, units}, {s, balances, inventory, energy, phase_units} ->
        balance = Map.get(s.material_balances, {cid, material}, 0)
        {s, paid} = settle_material(s, cid, material, units)
        if phase_material?(s, material) do
          m = s.properties.materials[material]
          # 供给指定相态与完整度：环境温度限定在该相态的转变点一侧，
          # 例如液态岩浆和固态冰，新增焓随供给事务记账。
          temperature = if Phase.liquid?(material),
            do: max(phase_ambient(s), m["phase_transition_kelvin"]),
            else: min(phase_ambient(s), m["phase_transition_kelvin"])
          added = Phase.energy(%{material: material}, units / liquid_capacity(s), m, temperature)
          {e, i} = inventory_phase(before, cid, material, balance)
          {s, Map.merge(balances, paid.material_balances), Map.put(inventory, {cid, material}, {e + added, i + units}), energy + added, phase_units + units}
        else
          {s, Map.merge(balances, paid.material_balances), inventory, energy, phase_units}
        end
      end)
    thermal = if next.thermal, do: next.thermal
      |> Map.update(:phase_authored_energy_j, energy, &(&1 + energy))
      |> Map.update(:phase_authored_units, phase_units, &(&1 + phase_units)), else: nil
    receipt = %{seq: before.seq + 1, quantities: quantities, phase_energy_j: energy}
    next = %{next | seq: receipt.seq, thermal: thermal,
      material_supplies: Map.put(next.material_supplies, key, receipt),
      phase_inventory: Map.merge(next.phase_inventory, inventory)}
    txn = %{seq: next.seq, entries: [], coarse: [], material_balances: balances,
      material_supplies: %{key => receipt}, phase_inventory: inventory, thermal: thermal}
    case append_log(next, txn) do
      :ok ->
        next = remember_entry(next, txn)
        fanout(next, txn)
        fanout_canonical(next, txn, [], [], before)
        {:reply, {:ok, next.seq}, next}
      {:error, reason} -> {:reply, {:error, reason}, before}
    end
  end

  defp build_target(before, actor, request) do
    # Scene 移交会换 Player 与 epoch，同一已鉴权连接的请求序号仍继续递增。
    previous = Map.get(before.build_sessions, actor.gate)

    cond do
      previous != nil and previous.request == request ->
        {:reply, previous.result, before}

      previous != nil and request.client_intent_seq <= previous.request.client_intent_seq ->
        {:reply, {:error, :replayed_build}, before}

      true ->
        result = cond do
          request.action == 4 -> craft(before, actor, request)
          request.action == 5 -> consume(before, actor, request)
          not Protection.permitted?(before.protection, {:character, actor.cid}, [request.coord]) ->
            {:error, :protected_region}
          request.action in [2,3] -> transfer_liquid(before, actor, request)
          true -> build_material(before, actor, request)
        end

        {reply, state} =
          case result do
            {:ok, state} -> {{:ok, state.seq}, state}
            {:error, _} = error -> {error, before}
          end

        unless previous != nil, do: Process.monitor(actor.gate)

        state = %{
          state
          | build_sessions:
              Map.put(state.build_sessions, actor.gate, %{request: request, result: reply})
        }

        {:reply, reply, state}
    end
  end

  # 全局系统功能（身体闭环 H1）：进食 = 生产意图 action 5，material = 可食材料（目录“可食”轴 food），一次吃一株 = place_units。
  # 余额足额才扣一株；食物账 food_ledger 记各材料累计吃掉的单位。提交后把该株的蛋白 g 与能量 J 送给该角色的 Player
  # （`{:body_food, cid, protein_g, energy_j}`，与 `{:body_heat}` 同一收件人），身体真值在 Scene。不写世界格，不受地块保护约束。
  defp consume(before, actor, request) do
    food = get_in(before, [Access.key(:properties), Access.key(:materials, %{}), request.material, "food"])
    units = build_cost(before, request.material)

    cond do
      food == nil or request.material not in before.production_materials ->
        {:error, :not_edible}

      balance_state(before, actor.cid, request.material).balance < units ->
        {:error, :insufficient_material}

      true ->
        {state, paid} = settle_material(before, actor.cid, request.material, -units)
        ledger = Map.update(state.food_ledger, request.material, units, &(&1 + units))
        next = %{state | seq: before.seq + 1, food_ledger: ledger}
        txn = %{seq: next.seq, entries: [], coarse: [], material_balances: paid.material_balances, food_ledger: ledger}

        case append_log(next, txn) do
          :ok ->
            next = remember_entry(next, txn)
            fanout(next, txn)
            fanout_canonical(next, txn, [], [], before)
            send(actor.player, {:body_food, actor.cid, food["protein_g"], food["energy_j"]})
            Logger.info("voxel_consume seq=#{next.seq} cid=#{actor.cid} material=#{request.material} units=#{units} protein_g=#{food["protein_g"]} energy_j=#{food["energy_j"]}")
            {:ok, next}

          error ->
            error
        end
    end
  end

  # 全局系统功能（R8-04 增量 2）：黑盒构件只能按目录配方从库存合成（生产意图 action 4，material = 产物，一次一份）。
  # 输入全部足额才整笔扣减、产物入库；合成账 craft_ledger 记各材料累计净变化。拆掉产物只返还产物本身（不可拆回原料）。
  defp craft(before, actor, request) do
    product = Map.get(before.properties.materials, request.material, %{})

    cond do
      not Map.has_key?(product, "recipe_inputs") or request.material not in before.production_materials ->
        {:error, :unknown_recipe}

      Enum.any?(product["recipe_inputs"], &(balance_state(before, actor.cid, &1["material_id"]).balance < &1["units"])) ->
        {:error, :insufficient_material}

      true ->
        delta = Map.put(Map.new(product["recipe_inputs"], &{&1["material_id"], -&1["units"]}), request.material, product["recipe_units"])

        {state, balances} =
          Enum.reduce(delta, {before, %{}}, fn {material, units}, {s, balances} ->
            {s, paid} = settle_material(s, actor.cid, material, units)
            {s, Map.merge(balances, paid.material_balances)}
          end)

        ledger = Enum.reduce(delta, state.craft_ledger, fn {material, units}, l -> Map.update(l, material, units, &(&1 + units)) end)
        next = %{state | seq: before.seq + 1, craft_ledger: ledger}
        txn = %{seq: next.seq, entries: [], coarse: [], material_balances: balances, craft_ledger: ledger}

        case append_log(next, txn) do
          :ok ->
            next = remember_entry(next, txn)
            fanout(next, txn)
            fanout_canonical(next, txn, [], [], before)
            Logger.info("voxel_craft seq=#{next.seq} cid=#{actor.cid} product=#{request.material} delta=#{inspect(delta)}")
            {:ok, next}

          error ->
            error
        end
    end
  end

  # Global system: phase energy/HP live in existing property rows. Inventory
  # carries only their extensive sums; material_balances remains quantity SSOT.
  defp phase_enabled?(s), do: s.properties != nil and Enum.any?(s.properties.materials,fn {_,m}->Phase.enabled?(m) end)
  defp phase_material?(s,m), do: s.properties != nil and Phase.enabled?(s.properties.materials[m])
  defp phase_target?(s,t), do: t.granularity == 0 and phase_material?(s,t.material)
  # 无位置的库存（供给、背包里的相态材料）按全局环境；落在格上的一律按该格气候区（ambient_at）。
  defp phase_ambient(s), do: s.thermal.config["ambient_kelvin"]
  # 格所在气候区的环境温度：未记录格的默认温度、相变天然温度、静止判据与显热参考（VoxelRegion.Climate.air_k/2）。
  defp ambient_at(s, cell), do: VoxelRegion.Climate.air_k(s.thermal.config, cell)

  # R8-07 散体：目录 loose_threshold_units 即可倾倒；格有数量记录（liquid_units 条目）才是散体，天然地形与建造格静止。
  defp loose_material?(s,m), do: s.properties != nil and Map.has_key?(Map.get(s.properties.materials,m,%{}),"loose_threshold_units")
  defp loose_cell?(s,t), do: t.granularity == 0 and loose_material?(s,t.material) and Map.has_key?(s.liquid_units,Damage.macro(t))
  # 随数量流动的材料：液体与可倾倒散体（一格一种材料，互不混合）。
  defp flowing_material?(s,m), do: Phase.liquid?(m) or loose_material?(s,m)
  # 数量记录决定实占用高度（射线、热几何按填充高度截断）的材料。
  defp finite_material?(s,m), do: phase_material?(s,m) or loose_material?(s,m)
  # 有限宏格：相态宏格与有数量记录的散体；其能量、完整度、燃料随数量搬运。
  defp finite_target?(s,t), do: phase_target?(s,t) or loose_cell?(s,t)
  defp finite_enabled?(s), do: phase_enabled?(s) or (s.properties != nil and
    Enum.any?(s.properties.materials,fn {_,m}->Map.has_key?(m,"loose_threshold_units") end))

  # 唯一的有限体积：宏格有数量记录时为 q / 单格容量，其余（无记录的满宏格、微格、附件）为 1；
  # 用于最大 HP、热采样、燃烧燃料与功率、转化体积和回收。数量按宏格存储（与液体相同），refined 宏格不带数量。
  defp finite_volume(s,%{granularity: 0}=t),
    do: Map.get(s.liquid_units,Damage.macro(t),liquid_capacity(s))/liquid_capacity(s)
  defp finite_volume(_s,_t), do: 1.0

  # 格值 {能量, 完整度, 已烧燃料 J, 火}（见 Phase）；非有限格为零值。
  defp phase_values(state,cells) do
    if finite_enabled?(state) do
      Enum.reduce(Enum.uniq(cells),{%{},state},fn cell,{values,s}->
        micro=cell |> Tuple.to_list() |> Enum.map(&(&1*@micro)) |> List.to_tuple()
        {target,s}=target_at(micro,s)
        value=if target && finite_target?(s,target) do
          row=property_state(s,target)
          m=s.properties.materials[row.material]
          volume=finite_volume(s,target)
          q=Map.get(s.liquid_units,cell,liquid_capacity(s))
          fuel=Map.get(row,:remaining_fuel_j)
          {Phase.finite_energy(row,volume,m,s.thermal && ambient_at(s,cell)),q*row.hp/row.max_hp,
            if(fuel,do: Combustion.capacity_j(m,volume)-fuel,else: 0.0),
            if(fuel,do: Map.get(row,:burning,false),else: nil)}
        else
          {0.0,0.0,0.0,nil}
        end
        {Map.put(values,cell,value),s}
      end)
    else
      {%{},state}
    end
  end

  defp inventory_phase(state,cid,material,balance) do
    Map.get_lazy(state.phase_inventory,{cid,material},fn ->
      m=state.properties.materials[material]
      {Phase.energy(%{material: material},balance/liquid_capacity(state),m,phase_ambient(state)),balance*1.0}
    end)
  end

  # 舀取／倾倒的格值与库存结算，返回 {state, 格值, 相态库存, 入库单位}。
  # 相态材料：焓与完整度在格与库存之间守恒搬运（既有 B7）。散体：库存不带热与完整度——
  # 倾倒按环境温度、完整材料并入格；舀取带走的显热记入移除账，已点燃的燃料按剩余比例折算入库单位
  # floor(moved × 剩余燃料 / 满燃料)，被带走的剩余燃料由 commit_liquid 按燃料差记入弃置账。
  defp transfer_phase_inventory(state,cid,cell,material,action,moved,balance) do
    cond do
      phase_material?(state,material) ->
        {values,state}=phase_values(state,[cell])
        carried=inventory_phase(state,cid,material,balance)
        q=if action==2,do: Map.fetch!(state.liquid_units,cell),else: balance
        {e,i,b,f}=Map.fetch!(values,cell)
        {{e,i},carried}=Phase.transfer({e,i},carried,q,moved,if(action==2,do: :scoop,else: :pour))
        values=Map.put(values,cell,{e,i,b,f})
        inventory=%{{cid,material}=>carried}
        state=%{state | phase_inventory: Map.merge(state.phase_inventory,inventory)}
        {state,values,inventory,if(action==2,do: moved,else: -moved)}

      not loose_material?(state,material) ->
        {state,%{},%{},if(action==2,do: moved,else: -moved)}

      action==2 ->
        {values,state}=phase_values(state,[cell])
        value=Map.fetch!(values,cell)
        q=Map.fetch!(state.liquid_units,cell)
        m=state.properties.materials[material]
        explicit=Phase.explicit_fuel(value,m,q/liquid_capacity(state))
        units=if elem(value,3)==nil,do: moved,
          else: floor(moved*explicit/Combustion.capacity_j(m,q/liquid_capacity(state)))
        removed=elem(value,0)*moved/q
        state=if state.thermal != nil and removed != 0.0,
          do: %{state | thermal: Map.update(state.thermal,:removed_j,removed,&(&1+removed))},else: state
        {state,%{cell=>Phase.scale(value,1-moved/q)},%{},units}

      true ->
        {values,state}=phase_values(state,[cell])
        {state,%{cell=>Phase.merge(Map.fetch!(values,cell),{0.0,moved*1.0,0.0,nil})},%{},-moved}
    end
  end

  defp put_phase_values(state,values) do
    Enum.reduce(values,{state,[]},fn {cell,value},{s,rows}->
      case Map.get(s.liquid_units,cell) do
        nil -> {s,rows}
        q ->
          micro=cell |> Tuple.to_list() |> Enum.map(&(&1*@micro)) |> List.to_tuple()
          {target,s}=target_at(micro,s)
          existing=Map.has_key?(s.damage,Damage.key(target))
          row=property_state(s,target)
          row=Phase.restore(row,value,q,liquid_capacity(s),s.properties.materials,s.thermal && ambient_at(s,cell))
            |> Map.merge(%{seq: s.seq,request_id: 0})
          # 散体在环境温度、完整、燃料未动时就是默认记录，不为每个流动格写属性行。
          resting=not phase_target?(s,target) and at_rest?(value,q)
          if resting and not existing do
            {s,rows}
          else
            s=%{s | damage: Map.put(s.damage,Damage.key(row),row)}
            # 搬运后的热节点成为普通热种子，净数量不变也需要重新推进。
            s=if s.thermal != nil and not resting,do: %{s | thermal: %{s.thermal | active: true},
              thermal_work: %{s.thermal_work | hot: MapSet.put(s.thermal_work.hot,cell)}},else: s
            {s,[row|rows]}
          end
      end
    end)
  end

  defp at_rest?({energy,integrity},q), do: at_rest?({energy,integrity,0.0,nil},q)
  defp at_rest?({energy,integrity,burnt,fire},q),
    do: energy == 0.0 and abs(integrity-q) <= 1.0e-9*q and burnt == 0.0 and fire == nil

  defp operate_phase(before,state,actor,request,target,tool) do
    with true <- request.action==1 and phase_target?(state,target) and state.thermal != nil,
         true <- (tool["action"]=="phase.cool" and Phase.liquid?(target.material)) or
           (tool["action"]=="phase.heat" and not Phase.liquid?(target.material)),
         fuel=tool["fuel_material_id"], units=tool["fuel_units"],
         true <- Map.get(state.material_balances,{actor.cid,fuel},0)>=units do
      cell=Damage.macro(target)
      q=Map.get(state.liquid_units,cell,liquid_capacity(state))
      {values,state}=phase_values(state,[cell])
      {energy,integrity,_,_}=Map.fetch!(values,cell)
      result=Phase.tool_energy(energy,q/liquid_capacity(state),state.properties.materials[target.material],tool)
      thermal=state.thermal |> Map.update(:phase_supplied_j,result.supplied_j,&(&1+result.supplied_j))
        |> Map.update(:phase_paid_j,result.paid_j,&(&1+result.paid_j))
        |> Map.update(:phase_unused_j,result.unused_j,&(&1+result.unused_j))
      {state,settlement}=settle_material(%{state | thermal: thermal},actor.cid,fuel,-units)
      settlement=Map.merge(settlement,%{phase_values: %{cell=>{result.energy,integrity}}})
      case commit_liquid(state,%{cell=>q},settlement) do
        {:ok,next}->
          Logger.info("voxel_phase seq=#{next.seq} action=#{tool["action"]} cell=#{inspect(cell)} units=#{q} used_j=#{abs(result.supplied_j)} unused_j=#{result.unused_j}")
          {:reply,{:ok,next.seq},next}
        {:error,reason}->{:reply,{:error,reason},before}
      end
    else
      false -> {:reply,{:error,:invalid_phase_operation},before}
    end
  end

  # Pick 进度不消耗材料完整度；真实损伤仍扣减首次采掘时的基准，不能通过采回修复。
  # 固体采回携带操作前焓；Pick 用持续维护的基准，recover 用当前 HP 比例。
  defp damage_phase_solid(before,state,actor,request,target,tool) do
    material=state.properties.materials[target.material]
    cell=Damage.macro(target)
    q=Map.get(state.liquid_units,cell,liquid_capacity(state))
    {values,state}=phase_values(state,[cell])
    pick=request.action==1 and tool["action"]=="damage.impact.pick"
    target=if pick,do: Map.put_new(target,:pick_baseline_hp,target.hp),else: target
    carried=if pick and target.hp>0.0,
      do: {elem(values[cell],0),q*target.pick_baseline_hp/target.max_hp},else: Phase.pair(values[cell])
    amount=Damage.amount(material,tool,0)*q/liquid_capacity(state)
    hp=max(0.0,target.hp-amount)
    target=if pick or request.action==2,do: target,else: Damage.pick_baseline(target,hp)
    target=%{target | hp: hp,seq: state.seq+1,request_id: 0}
    state=%{state | damage: Map.put(state.damage,Damage.key(target),target)}
    values=Map.put(values,cell,{elem(values[cell],0),q*target.hp/target.max_hp})
    settlement=if request.action==2 or target.hp==0.0 do
      carried=if pick or request.action==2,do: carried,else: Phase.pair(values[cell])
      balance=Map.get(state.material_balances,{actor.cid,target.material},0)
      inventory=Phase.add(%{{actor.cid,target.material}=>inventory_phase(state,actor.cid,target.material,balance)},
        {actor.cid,target.material},carried)
      state=%{state | phase_inventory: Map.merge(state.phase_inventory,inventory)}
      {state,paid}=settle_material(state,actor.cid,target.material,q)
      {state,%{cell=>0},Map.merge(paid,%{phase_inventory: inventory,phase_values: %{cell=>{0.0,0.0}}})}
    else
      {state,%{cell=>q},%{phase_values: values}}
    end
    {state,changes,settlement}=settlement
    case commit_liquid(state,changes,settlement) do
      {:ok,next}->{:reply,{:ok,next.seq},next}
      {:error,reason}->{:reply,{:error,reason},before}
    end
  end

  # Global system: material21 and its finite units share the existing World commit.
  defp liquid_enabled?(state), do: state.liquid_bounds != nil and state.properties != nil and Map.get(state.properties, :liquid) != nil
  defp liquid_capacity(state), do: state.material_units_per_micro * @micro * @micro * @micro
  defp schedule_liquid(state) do
    if liquid_enabled?(state) and state.liquid_timer == nil and MapSet.size(state.liquid_active) > 0 do
      %{state | liquid_timer: Process.send_after(self(), :liquid_commit,
        max(1, round(state.properties.liquid["step_seconds"] * 1000)))}
    else
      state
    end
  end

  defp wake_liquid(state, cells) do
    if liquid_enabled?(state) do
      active = cells |> Liquid.neighborhood() |> Enum.filter(&liquid_inside?(&1, state.liquid_bounds)) |> MapSet.new()
      %{state | liquid_active: MapSet.union(state.liquid_active, active)}
    else
      state
    end
  end
  defp liquid_inside?({x,y,z}, {{lx,ly,lz},{hx,hy,hz}}), do: x>=lx and x<hx and y>=ly and y<hy and z>=lz and z<hz

  defp enable_liquid(before, state) do
    if not liquid_enabled?(before) and liquid_enabled?(state) do
      schedule_liquid(state)
    else
      state
    end
  end

  defp adopt_liquid_sources(state, region) do
    # 全局系统：只接纳本次加载区域（含 ring）的有限液体；地图边界不是启动扫描任务。
    # 从当前 canonical 载荷筛选，再按 owner core 读取，已耗尽源的空气覆盖不会补水。
    {{lx,ly,lz},{hx,hy,hz}}=state.liquid_bounds
    {ox,oy,oz}=Payload.origin(region)
    extent=Payload.extent()
    lo={max(lx,ox),max(ly,oy),max(lz,oz)}
    hi={min(hx,ox+extent),min(hy,oy+extent),min(hz,oz+extent)}
    {ax,ay,az}=lo
    {bx,by,bz}=hi
    if ax<bx and ay<by and az<bz do
      with {:ok,bytes,_,state} <- payload_bytes(state,0,region),
           {:ok,payload} <- Payload.decode(bytes) do
        cells=if :binary.match(payload.cells,[<<21,0>>,<<22,0>>]) == :nomatch do
          []
        else
          for x<-ax..(bx-1),y<-ay..(by-1),z<-az..(bz-1),
            not Map.has_key?(state.liquid_units,{x,y,z}),
            Phase.liquid?(Payload.material(payload,Payload.local(region,{x,y,z}))),do: {x,y,z}
        end
        Enum.reduce([21,22],state,fn material,s ->
          {_open,water,s}=liquid_cells(s,cells,material)
          if map_size(water)==0 do
            s
          else
            {:ok,s}=commit_liquid(s,water,%{liquid_wake: false,liquid_material: material})
            s
          end
        end)
      else
        # 保留实际请求入口的 missing/canonical_incomplete 错误，不把缺失源当空气。
        {:error,_,state} -> state
        {:error,_} -> state
      end
    else
      state
    end
  end

  defp raw_liquid_edit(state, edits) do
    Enum.reduce_while(edits, :ok, fn {cell, material}, :ok ->
      case cell_value(state, 0, cell) do
        {:ok, {old,_}, _} ->
          if Phase.liquid?(old) or Phase.liquid?(material) or phase_material?(state,old) or phase_material?(state,material),
            do: {:halt, {:error,:use_liquid_tool}}, else: {:cont,:ok}
        _ -> {:cont, :ok}
      end
    end)
  end

  defp liquid_cells(state, cells, liquid_material) do
    Enum.reduce(Enum.uniq(cells), {%{},%{},state}, fn cell,{open,water,s} ->
      region=region_of(cell)
      if needs_source?(s,{0,region}), do: :ok=s.source.ensure(s.source_state,0,region)
      {:ok,{material,_},s}=cell_value(s,0,cell)
      # Legacy Water21 without a suffix is a full macro, not an empty cell.
      # 散体只有带数量记录的同种格参与流动；天然与建造的同种满格静止，与其他材料一样是墙（D1）。
      same=material==liquid_material and (Phase.liquid?(material) or Map.has_key?(s.liquid_units,cell))
      # 地面花草可被替换：流入时视同空气，写入即覆盖它。refined 宏格不带数量（D8）。
      available=(material==0 or same or MmoContracts.VoxelMaterialCatalog.flora?(material)) and not Map.has_key?(s.refined,cell)
      water=if same, do: Map.put(water,cell,Map.get(s.liquid_units,cell,liquid_capacity(s))), else: water
      {Map.put(open,cell,available),water,s}
    end)
  end

  # 工具 11/12（liquid.scoop / liquid.pour）同时服务液体与散体；倾倒即建造（受保护区域许可在 build_target 先裁决）。
  defp transfer_liquid(before, actor, request) do
    expected=if request.action==2,do: "liquid.scoop",else: "liquid.pour"
    with true <- liquid_enabled?(before),
         true <- flowing_material?(before,request.material) and request.material in before.production_materials,
         true <- liquid_inside?(request.coord,before.liquid_bounds),
         {:ok,tool} <- Map.fetch(before.properties.tools,request.tool_id),
         true <- tool["action"] == expected,
         :ok <- build_reach(actor.eye,request.coord,tool["range_macro"]),
         :ok <- liquid_sight(before,actor.eye,request.coord),
         # D8：数量按宏格存储，细分宏格（micro 开口）不带数量；客户端据此提示“开口需至少 1 m”。
         :ok <- if(Map.has_key?(before.refined,request.coord),do: {:error,:needs_macro_opening},else: :ok),
         {:ok,session} <- Damage.admit_attack(Map.get(before.tool_sessions,actor.player),
           request.client_intent_seq,actor.received_us,ceil(tool["interval_seconds"]*1_000_000),actor.tick_us) do
      {open,water,state}=liquid_cells(before,[request.coord],request.material)
      balance=balance_state(state,actor.cid,request.material).balance
      transfer=case request.action do
        2 -> Liquid.scoop(water,request.coord,balance,tool["liquid_transfer_units"])
        3 -> Liquid.pour(water,request.coord,balance,tool["liquid_transfer_units"],liquid_capacity(state),state.liquid_bounds,&Map.fetch!(open,&1))
      end
      if transfer.transferred_units == 0 or not Map.fetch!(open,request.coord) do
        {:error,:no_liquid_transfer}
      else
        unless Map.has_key?(state.tool_sessions,actor.player), do: Process.monitor(actor.player)
        state=%{state | tool_sessions: Map.put(state.tool_sessions,actor.player,session)}
        {state,carried,inventory,units}=transfer_phase_inventory(state,actor.cid,request.coord,request.material,
          request.action,transfer.transferred_units,balance)
        {state,settlement}=settle_material(state,actor.cid,request.material,units)
        settlement=Map.merge(settlement,%{phase_values: carried,phase_inventory: inventory,liquid_material: request.material})
        commit_liquid(state,transfer.changes,settlement)
      end
    else
      false -> {:error,:invalid_liquid_operation}
      :error -> {:error,:invalid_tool}
      {:error,_}=error -> error
    end
  end

  defp liquid_sight(state,eye,coord) do
    delta=Enum.zip_with(Tuple.to_list(coord),Tuple.to_list(eye),&(&1+0.5-&2))
    distance=:math.sqrt(Enum.sum(Enum.map(delta,&(&1*&1))))
    if distance==0 do
      :ok
    else
      direction=delta |> Enum.map(&(&1/distance)) |> List.to_tuple()
      # Water itself is transparent; canonical solid macro/refined cells occlude.
      # 目标格本身不算遮挡：往部分装填的散体格上继续倾倒时，射线终点（格心）可能低于料面（R8-07）。
      at=fn micro,s ->
        case if(elem(Prefab.macro_slot(micro),0)==coord,do: {nil,s},else: target_at(micro,s)) do
          {%{material: material},s} when material in [21,22]->{nil,s}
          {%{granularity: 0}=target,s}->
            if finite_target?(s,target) do
              cell=Damage.macro(target)
              height=Map.get(s.liquid_units,cell,liquid_capacity(s))/liquid_capacity(s)
              {if(finite_phase_ray?(eye,direction,distance,cell,height),do: target,else: nil),s}
            else
              {target,s}
            end
          other->other
        end
      end
      case Damage.raycast(eye,direction,distance,state,at) do
        {:error,:no_target,_}->:ok
        {:ok,_,_}->{:error,:occluded_liquid}
      end
    end
  end

  defp commit_liquid(state, changes, settlement, extra_edits \\ [], owners \\ MapSet.new(), attachments \\ MapSet.new()) do
    liquid_material=Map.get(settlement,:liquid_material,21)
    for {level,region}=key <- Enum.uniq(edit_keys(Map.keys(changes))), needs_source?(state,key),
      do: :ok=state.source.ensure(state.source_state,level,region)
    {values,state}=phase_values(state,Map.keys(changes))
    supplied_values=Map.get(settlement,:phase_values,%{})
    {edits,next_values}=if finite_enabled?(state) do
      current=Map.new(changes,fn {cell,_q}->
        {:ok,{old,_},_}=cell_value(state,0,cell)
        {cell,{old,Map.fetch!(values,cell)}}
      end)
      Phase.settle(changes,current,supplied_values,%{materials: state.properties.materials,
        capacity: liquid_capacity(state),ambient: state.thermal && phase_ambient(state),material: liquid_material})
    else
      {Enum.map(changes,fn {cell,q}->{cell,if(q==0,do: 0,else: liquid_material)} end),
        Map.merge(values,supplied_values)}
    end
    state=fuel_ledger(state,liquid_material,values,next_values,changes)
    settlement=Map.merge(settlement,%{liquid_changes: changes,phase_values: next_values})
    apply_batch(state,edits++extra_edits,false,settlement,owners,attachments)
  end

  # 燃料账：已初始化剩余燃料随数量搬运时总量不变；隐含满燃料的格与带燃料的量相遇即初始化（记入初始化账），
  # 舀出已初始化燃料离开世界（记入弃置账）。前后之差只在可燃散体上非零。
  defp fuel_ledger(%{thermal: nil}=state,_material,_before,_after,_changes), do: state
  defp fuel_ledger(state,material,before,next,changes) do
    m=state.properties.materials[material]
    capacity=liquid_capacity(state)
    delta=Enum.reduce(next,0.0,fn {cell,value},sum ->
      old=Map.get(before,cell,{0.0,0.0,0.0,nil})
      sum+Phase.explicit_fuel(value,m,Map.get(changes,cell,0)/capacity)-
        Phase.explicit_fuel(old,m,Map.get(state.liquid_units,cell,capacity)/capacity)
    end)
    cond do
      delta > 0.0 -> %{state | thermal: Map.update(state.thermal,:fuel_initialized_j,delta,&(&1+delta))}
      delta < 0.0 -> %{state | thermal: Map.update(state.thermal,:discarded_fuel_j,-delta,&(&1-delta))}
      true -> state
    end
  end

  # 多材料调度：活跃集合周边出现的每种流动材料（液体、带数量记录的散体）各跑一次同一个数量内核，
  # 侧向阈值按材料取（液体用液体参数，散体用目录 loose_threshold_units，决定静止休止角 atan(t / 容量)）。
  defp advance_liquid(state, active) do
    # Two stages need the downward cell and the horizontal neighbors of both levels.
    cells=for {x,y,z} <- active, dy <- [0,-1],
      {dx,dz} <- [{0,0},{-1,0},{1,0},{0,-1},{0,1}],
      cell={x+dx,y+dy,z+dz}, liquid_inside?(cell,state.liquid_bounds), do: cell
    cells=Enum.uniq(cells)
    falling=for {m,[_|_]} <- state.liquid_falls, into: MapSet.new(), do: m
    {kinds,state}=Enum.reduce(cells,{falling,state},fn cell,{kinds,s} ->
      if needs_source?(s,{0,region_of(cell)}), do: :ok=s.source.ensure(s.source_state,0,region_of(cell))
      {:ok,{m,_},s}=cell_value(s,0,cell)
      {if(Phase.liquid?(m) or (loose_material?(s,m) and Map.has_key?(s.liquid_units,cell)),
        do: MapSet.put(kinds,m),else: kinds),s}
    end)
    Enum.reduce(Enum.sort(kinds),state,&advance_liquid(&2,&1,active,cells))
  end

  defp advance_liquid(state,material,active,cells) do
    {open,water,state}=liquid_cells(state,cells,material)
    config=state.properties.liquid
    threshold=if Phase.liquid?(material),do: Map.get(config,"side_threshold_units",0),
      else: state.properties.materials[material]["loose_threshold_units"]
    # 下落留在同一列（同一持有者）；侧流不跨受保护区域边界。
    connected = if not Protection.empty?(state.protection),
      do: fn a, b -> Protection.same_holder?(state.protection, a, b) end
    {changes,stages}=Liquid.step_transfers(water,state.liquid_bounds,liquid_capacity(state),
      config["gravity_units_per_step"],config["side_units_per_step"],&Map.get(open,&1,false),
      threshold,active,connected)
    {values,state}=phase_values(state,Map.keys(water))
    {changes,values}=if finite_enabled?(state),do: Phase.transport_stages(values,water,changes,stages),else: {changes,%{}}
    state = %{state | liquid_active: MapSet.union(state.liquid_active, Liquid.next_active(stages))}
    settlement = %{phase_values: values, liquid_material: material}
    # 下落帧只描述液体（codec 契约）；散体下落不发帧。
    falls = if Phase.liquid?(material), do: Liquid.fall_transfers(stages), else: []
    previous = Map.get(state.liquid_falls, material, [])
    settlement = if falls != [] or previous != [],
      do: Map.put(settlement, :liquid_falls, %{material: material, transfers: falls}), else: settlement
    case commit_liquid(state,changes,settlement) do
      {:ok,next}->%{next | liquid_falls: Map.put(next.liquid_falls, material, falls)}
      {:error,reason}->Logger.error("voxel_liquid_commit failed=#{inspect(reason)}"); state
    end
  end

  defp build_material(before, actor, request) do
          with :ok <-
                 if(request.action == 1 and not Phase.liquid?(request.material) and request.material in before.production_materials,
                   do: :ok,
                   else: {:error, :unknown_resource}
                 ),
               {:ok, tool} <- Map.fetch(before.properties.tools, request.tool_id),
               :ok <- build_reach(actor.eye, request.coord, tool["range_macro"]),
               :ok <-
                 if(
                   balance_state(before, actor.cid, request.material).balance >= build_cost(before, request.material),
                   do: :ok,
                   else: {:error, :insufficient_material}
                 ),
               :ok <- if(phase_material?(before,request.material) and
                   elem(inventory_phase(before,actor.cid,request.material,balance_state(before,actor.cid,request.material).balance),1)<=0,
                 do: {:error,:broken_material},else: :ok),
               false <- Map.has_key?(before.refined, request.coord),
               {:ok, {old, _}, state} <- cell_value(before, 0, request.coord),
               {:ok, state} <- plant_support(state, request),
               {:ok, state, displaced, displacement} <- displace_for_build(state, request.coord, old) do
            {state, settlement} =
              settle_material(
                state,
                actor.cid,
                request.material,
                -build_cost(state, request.material)
              )

            # 溯源：这一格是 actor 花自己的材料放下的。
            settlement = Map.put(settlement, :placed, %{request.coord => actor.cid})

            if phase_material?(state,request.material) do
              cost=liquid_capacity(state)
              balance=balance_state(before,actor.cid,request.material).balance
              carried=inventory_phase(before,actor.cid,request.material,balance)
              {portion,remaining}=Phase.transfer({0.0,0.0},carried,balance,cost,:pour)
              inventory=%{{actor.cid,request.material}=>remaining}
              state=%{state | phase_inventory: Map.merge(state.phase_inventory,inventory)}
              # Inventory Ice stays solid; any later thermal phase completion is ordinary simulation.
              apply_batch(state,displaced++[{request.coord,request.material}],false,Map.merge(settlement,%{
                liquid_changes: Map.put(displacement.liquid_changes,request.coord,cost),
                phase_values: Map.put(displacement.phase_values,request.coord,portion),phase_inventory: inventory}))
            else
              apply_batch(state, displaced++[{request.coord, request.material}], false, Map.merge(settlement,displacement))
            end
          else
            :error -> {:error, :invalid_tool}
            true -> {:error, :occupied}
            {:ok, _, _} -> {:error, :occupied}
            {:error, reason} -> {:error, reason}
          end
  end

  # 地面花草只能种在草、苔或土上；其余材料不看下方。
  defp plant_support(state, %{material: material, coord: {x, y, z}}) when material in 32..39 do
    case cell_value(state, 0, {x, y - 1, z}) do
      {:ok, {below, _}, state} when below in [1, 3, 7] -> if(is_map_key(state.refined, {x, y - 1, z}), do: {:error, :unsupported}, else: {:ok, state})
      {:ok, _, _} -> {:error, :unsupported}
      {:error, reason, _} -> {:error, reason}
    end
  end

  defp plant_support(state, _request), do: {:ok, state}

  # 先形成完整不可变计划，再与扣料及实体放置共同提交；拒绝时不留下部分排液。
  defp displace_for_build(state, _cell, 0),
    do: {:ok,state,[],%{liquid_changes: %{},phase_values: %{}}}
  # 地面花草可被替换：建造直接覆盖，不产生排液。
  defp displace_for_build(state, _cell, material) when material in 32..39,
    do: {:ok,state,[],%{liquid_changes: %{},phase_values: %{}}}
  defp displace_for_build(state, cell, material) do
    if Phase.liquid?(material) and liquid_enabled?(state) and liquid_inside?(cell,state.liquid_bounds) do
      cells = cell |> then(&Liquid.neighborhood([&1])) |> Enum.filter(&liquid_inside?(&1,state.liquid_bounds))
      {open,water,state} = liquid_cells(state,cells,material)
      # 建造排液不排进持有者不同的格。
      with {:ok,changes,flows} <- Liquid.displace(water,cell,liquid_capacity(state),state.liquid_bounds,
             &(Map.fetch!(open,&1) and Protection.same_holder?(state.protection,cell,&1))) do
        {values,state} = phase_values(state,Map.keys(changes))
        values = if finite_enabled?(state),do: Phase.transport(values,water,flows),else: %{}
        edits = for {to,_} <- changes,to != cell,do: {to,material}
        {:ok,state,edits,%{liquid_changes: changes,phase_values: values}}
      end
    else
      {:error,:occupied}
    end
  end

  defp build_reach(eye, coord, range) do
    squared =
      Enum.zip(Tuple.to_list(eye), Tuple.to_list(coord))
      |> Enum.reduce(0.0, fn {a, b}, sum -> sum + (a - b - 0.5) * (a - b - 0.5) end)

    if squared <= range * range, do: :ok, else: {:error, :out_of_reach}
  end

  # 参数只改变下一次计算；实例温度、HP、源预算与相变焓不改写；
  # 已点燃行的余燃料与功率由调用方按新目录保比例重标后传入。
  # 复用既有同步落盘后广播边界；失败时目录与所有实例状态一起保持旧值。
  # migration：退役设备迁移后的附件槽、改了材料的槽（其区域 afterimage 同笔写出）与旧槽热行的删除记录。
  defp publish_property_catalog(state, catalog, thermal, damage, migration) do
    if state.properties.digest == catalog.digest do
      {:reply, :ok, enable_liquid(state, rebuild_thermal_work(%{state | properties: catalog}))}
    else
      rows = for {_, t} <- damage,
        do: %{t | digest: catalog.digest, seq: state.seq + 1, request_id: 0}
      tombstones = for t <- migration.tombstones,
        do: %{t | digest: catalog.digest, seq: state.seq + 1, request_id: 0, flags: 1}
      next = %{state | properties: catalog, thermal: thermal, seq: state.seq + 1, attachments: migration.attachments,
        damage: Map.new(rows, &{Damage.key(&1), &1})} |> rebuild_thermal_work()
      # 步进参数或散体休止阈值改变：全部有限格重新接受新参数的平衡（只改下一步，不改已提交数量）。
      next = if state.properties.liquid != catalog.liquid or loose_thresholds(state.properties) != loose_thresholds(catalog),
        do: wake_liquid(next, Map.keys(next.liquid_units)), else: next
      {txn, keys, next} = if migration.slots == [],
        do: {%{seq: next.seq, entries: [], coarse: []}, [], next},
        else: attachment_geometry(state, next, migration.slots)
      txn = Map.merge(txn, %{property_states: tombstones ++ rows, thermal: thermal})
      case append_log(next, txn) do
        :ok ->
          next = remember_entry(next, txn)
          fanout(next, txn)
          fanout_canonical(next, txn, [], keys, state)
          Logger.info("voxel_parameter_publication seq=#{next.seq} retired_slots=#{length(migration.slots)} old=#{Base.encode16(state.properties.digest, case: :lower)} new=#{Base.encode16(catalog.digest, case: :lower)} rebase_j=#{if thermal, do: Map.get(thermal, :parameter_rebase_j, 0.0), else: 0.0} fuel_rebase_j=#{if thermal, do: Map.get(thermal, :fuel_rebase_j, 0.0), else: 0.0}")
          {:reply, :ok, schedule_liquid(enable_liquid(state, next))}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end
  end

  defp loose_thresholds(catalog),
    do: for({id, m} <- catalog.materials, Map.has_key?(m, "loose_threshold_units"), into: %{}, do: {id, m["loose_threshold_units"]})

  defp validate_damage_catalog(state) do
    if map_size(state.damage) > 0 do
      true =
        state.properties != nil and
          Enum.all?(state.damage, fn {_, t} -> t.digest == state.properties.digest end)
    end
  end

  # 世界串行接纳；先 .vxpd 后 .pub（<<序号::32, cid::64, 名称::binary>>）：两步之间崩溃只让定义暂不列出，重发即补记；
  # 重发保留首个发布者、名称与序号。
  defp persist_prefab(state, cid, name, id, bytes) do
    stem = Path.join(state.prefab_dir, Base.encode16(id, case: :lower))
    listed = Enum.any?(state.published, &(&1.id == id))
    ordinal = length(state.published) + 1

    with :ok <- write_new(stem <> ".vxpd", bytes),
         :ok <-
           if(listed, do: :ok, else: write_new(stem <> ".pub", <<ordinal::32, cid::64, name::binary>>)) do
      if listed,
        do: {:ok, state.published},
        else: {:ok, state.published ++ [%{id: id, publisher: cid, name: name, bytes: bytes}]}
    end
  end

  # 完整文件原子改名成功后才暴露，临时文件不参与恢复。
  defp write_new(target, bytes) do
    if File.exists?(target) do
      :ok
    else
      temporary = target <> ".tmp"

      with :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- File.write(temporary, bytes, [:binary, :sync]),
           :ok <- File.rename(temporary, target) do
        :ok
      else
        {:error, reason} ->
          File.rm(temporary)
          {:error, {:prefab_persist, reason}}
      end
    end
  end

  defp current_actor(actor) do
    try do
      with {:ok, current} <- actor.refresh.(actor.player, actor.identity) do
        {:ok, Map.merge(current, Map.take(actor, [:received_us, :clock_node]))}
      end
    catch
      :exit, _ -> {:error, :invalid_session}
    end
  end

  # 全局系统功能：复用 B2 请求会话、余额和同步日志提交；只生成既有完整区域事务。
  defp attachment_target(before, actor, request) do
    previous = Map.get(before.build_sessions, actor.gate)

    cond do
      previous != nil and previous.request == request ->
        {:reply, previous.result, before}

      previous != nil and request.client_intent_seq <= previous.request.client_intent_seq ->
        {:reply, {:error, :replayed_build}, before}

      true ->
        result =
          with {:ok, tool} <- Map.fetch(before.properties.tools, request.tool_id),
               :ok <- attachment_protection(before, actor, request),
               :ok <- attachment_reach(before, actor, request, tool),
               {:ok, state, slots, settlement} <- attachment_change(before, actor, request) do
            commit_attachment(before, state, slots, settlement)
          else
            :error -> {:error, :invalid_tool}
            error -> error
          end

        {reply, state} =
          case result do
            {:ok, state} -> {{:ok, state.seq}, state}
            {:error, _} = error -> {error, before}
          end

        unless previous != nil, do: Process.monitor(actor.gate)

        state = %{
          state
          | build_sessions:
              Map.put(state.build_sessions, actor.gate, %{request: request, result: reply})
        }

        {:reply, reply, state}
    end
  end

  defp destroy_attachment(before, state, actor, target) do
    slots = attachment_slots(state, target.incarnation)

    {state, settlement} =
      settle_material(
        state,
        actor.cid,
        target.material,
        attachment_recovery(state, slots)
      )

    state = %{state | attachments: Map.drop(state.attachments, slots)}
    tombstone = %{target | hp: 0.0, flags: 1, seq: before.seq + 1, request_id: 0}
    state = %{state | damage: Map.delete(state.damage, Damage.key(target))}

    case commit_attachment(
           before,
           state,
           slots,
           Map.put(settlement, :property_states, [tombstone])
         ) do
      {:ok, next} -> {:reply, {:ok, next.seq}, next}
      {:error, reason} -> {:reply, {:error, reason}, before}
    end
  end

  defp commit_attachment(before, state, slots, settlement) do
    state = %{state | seq: before.seq + 1}
    {state, rows} = attachment_damage(before, state)
    settlement = Map.update(settlement, :property_states, rows, &(&1 ++ rows))

    state =
      if state.thermal,
        do: rebuild_thermal_work(%{state | thermal: %{state.thermal | active: true}}),
        else: state

    settlement =
      if state.thermal, do: Map.put(settlement, :thermal, state.thermal), else: settlement

    {txn, keys, state} = attachment_geometry(before, state, slots)
    txn = Map.merge(txn, settlement)

    case append_log(state, txn) do
      :ok ->
        state = remember_entry(state, txn)
        fanout(state, txn)
        fanout_canonical(state, txn, [], keys, before)

        Logger.info(
          "voxel_attachment seq=#{state.seq} changed_slots=#{length(slots)} total=#{map_size(state.attachments)}"
        )

        {:ok, state}

      error ->
        error
    end
  end

  # 附件槽变化的派生几何（粗层表皮投票、core 区域与结构 afterimage），与槽事实同一事务写出。
  defp attachment_geometry(before, state, slots) do
    dirty = Enum.map(Attachments.macros(slots), &{0, &1})
    {:ok, coarse, state, _} = reduce_batch(state, dirty, 1, [], 0)
    {coarse_txn, state} = select_transaction(state, coarse)
    keys = region_keys(dirty)

    {state, structure_keys, structure_cells} =
      refresh_structure(state, Enum.map(dirty, &elem(&1, 1)))

    {entries, state} = region_afterimages(state, keys, before.payloads)
    entries = entries ++ structure_entries(state, structure_cells)
    {%{coarse_txn | entries: entries ++ coarse_txn.entries}, Enum.uniq(keys ++ structure_keys), state}
  end

  defp attachment_reach(state, actor, r, tool) do
    # 检查到附件几何中心之前的遮挡；斜视共享棱时，向宿主内部偏移会误中邻格。
    size = if r.action == 0, do: r.size, else: 1

    center =
      for i <- 0..2 do
        offset =
          if (r.kind == 0 and i != r.axis) or (r.kind == 1 and i == r.axis),
            do: div(size - 1, 2) + 0.5,
            else: 0.0

        (elem(r.anchor, i) + offset) / @micro
      end

    delta = Enum.zip_with(center, Tuple.to_list(actor.eye), &(&1 - &2))
    distance = :math.sqrt(Enum.sum(Enum.map(delta, &(&1 * &1))))

    if distance > tool["range_macro"] or distance == 0 do
      {:error, :out_of_reach}
    else
      direction = delta |> Enum.map(&(&1 / distance)) |> List.to_tuple()

      case Damage.raycast(actor.eye, direction, max(0.0, distance - 1.0e-7), state, &target_at/2) do
        {:error, :no_target, _} -> :ok
        {:ok, _, _} -> {:error, :occluded_attachment}
      end
    end
  end

  defp attachment_change(state, actor, %{action: 0} = r) do
    slots = Attachments.footprint(r.kind, r.axis, r.anchor, r.size)
    {samples, state} = attachment_samples(state, slots)
    cost = Attachments.units(slots, state.properties)

    cond do
      r.id != 0 ->
        {:error, :invalid_attachment}

      not MmoContracts.Voxel.Attachments.material?(r.material) or
          r.material not in state.production_materials ->
        {:error, :unknown_resource}

      r.size == @micro and Enum.any?(Tuple.to_list(r.anchor), &(rem(&1, @micro) != 0)) ->
        {:error, :invalid_attachment}

      Enum.any?(slots, &Map.has_key?(state.attachments, &1)) ->
        {:error, :occupied}

      not Enum.all?(slots, &Attachments.supported?(&1, samples)) ->
        {:error, :unsupported_attachment}

      balance_state(state, actor.cid, r.material).balance < cost ->
        {:error, :insufficient_material}

      true ->
        {state, settlement} = settle_material(state, actor.cid, r.material, -cost)
        id = max(state.attachment_serial, state.seq) + 1
        slots_map = Map.new(slots, &{&1, {id, r.material}})

        {:ok,
         %{state | attachment_serial: id, attachments: Map.merge(state.attachments, slots_map)},
         slots, settlement}
    end
  end

  defp attachment_change(state, actor, %{action: 1} = r) do
    case Map.get(state.attachments, {r.kind, r.axis, r.anchor}) do
      {id, material} when id == r.id and material == r.material ->
        slots = for {s, {^id, _}} <- state.attachments, do: s

        {state, settlement} =
          settle_material(state, actor.cid, material, attachment_recovery(state,slots))

        {:ok, %{state | attachments: Map.drop(state.attachments, slots)}, slots, settlement}

      _ ->
        {:error, :stale_target}
    end
  end

  defp attachment_samples(state, slots) do
    Enum.map_reduce(slots |> Enum.flat_map(&Attachments.neighbors/1) |> Enum.uniq(), state, fn p,
                                                                                               s ->
      {t, s} = target_at(p, s)
      {{p, if(t, do: t.material, else: 0)}, s}
    end)
    |> then(fn {rows, s} -> {Map.new(rows), s} end)
  end

  defp prune_attachments(before, state, cells, settlement) do
    slots = affected_attachments(state, cells)
    {samples, state} = attachment_samples(state, slots)

    removed =
      (Map.keys(before.attachments) -- Map.keys(state.attachments)) ++
        Enum.reject(slots, &Attachments.supported?(&1, samples))

    cid = Map.get(settlement, :recovery_cid)

    {state, balances} =
      Enum.reduce(removed, {state, Map.get(settlement, :material_balances, %{})}, fn slot,
                                                                                     {s, b} ->
        {_, material} = Map.get(s.attachments, slot) || Map.fetch!(before.attachments, slot)

        if cid && material in s.production_materials do
          {s, paid} = settle_material(s, cid, material, attachment_recovery(before,[slot]))
          {s, Map.merge(b, paid.material_balances)}
        else
          {s, b}
        end
      end)

    settlement = Map.delete(settlement, :recovery_cid)

    settlement =
      if map_size(balances) > 0,
        do: Map.put(settlement, :material_balances, balances),
        else: settlement

    {%{state | attachments: Map.drop(state.attachments, removed)},
     region_keys(Enum.map(Attachments.macros(removed), &{0, &1})), settlement}
  end

  # ---- 受保护区域：意图许可的受影响格、玩家认领适配、提交

  # 工具意图作用的全部宏格：宏格本身、叶子构件的全部占用格、附件整件的足迹。
  defp target_cells(state, %{granularity: 3} = t),
    do: Attachments.macros(attachment_slots(state, t.incarnation))
  defp target_cells(state, %{granularity: 2} = t), do: micro_owner_cells(state, MapSet.new([t.owner]))
  defp target_cells(_state, t), do: [Damage.macro(t)]

  # 附件放置的足迹必须落在同一持有者内（不跨区域边界）；拆除只看现有整件足迹。
  defp attachment_protection(state, actor, r) do
    holder = {:character, actor.cid}
    cells =
      if r.action == 0,
        do: Attachments.macros(Attachments.footprint(r.kind, r.axis, r.anchor, r.size)),
        else: Attachments.macros(attachment_slots(state, r.id))
    single = r.action != 0 or Protection.empty?(state.protection) or
      length(Enum.uniq_by(cells, &Protection.holder(state.protection, &1))) <= 1

    if single and Protection.permitted?(state.protection, holder, cells),
      do: :ok,
      else: {:error, :protected_region}
  end

  # Prefab 放置看足迹，拆除/替换看整棵子树现有格（替换再加新足迹）。
  defp prefab_intent_cells(state, :voxel_prefab_place_v1, r) do
    case definition_cells(state, r.definition_id, r.anchor, r.orientation) do
      {:ok, _, macros} -> macros
      _ -> []
    end
  end

  defp prefab_intent_cells(state, kind, r) do
    replacement =
      with :voxel_prefab_replace_v1 <- kind,
           {:ok, instance} <- fetch_instance(state, r.instance_id),
           {:ok, _, macros} <- definition_cells(state, r.definition_id, instance.anchor, instance.orientation),
           do: macros,
           else: (_ -> [])

    owner_cells(state, r.instance_id) ++ replacement
  end

  # 玩家适配（认领工具）：第一次点地面记第一角；第二次点记对角并建区域（再点第一角同一格 = 取消）；
  # 无待定角时点自己区域内的格 = 释放该区域。每次点击都经工具射线的射程与遮挡裁决。
  # 上限（数量、面积）来自工具目录行；拒绝：:region_too_large / :region_limit / :region_overlap / :region_occupied。
  defp claim_region(_before, state, actor, request, target, tool) do
    holder = {:character, actor.cid}
    cell = Damage.macro(target)
    pending = Map.get(state.claim_corners, actor.player)
    p = state.protection
    corners = Map.delete(state.claim_corners, actor.player)

    cond do
      request.action != 1 ->
        {:reply, {:error, :invalid_protection_operation}, state}

      pending == cell ->
        {:reply, {:ok, state.seq}, %{state | claim_corners: corners}}

      pending != nil ->
        {x0, _, z0} = pending
        {x1, _, z1} = cell
        min = {min(x0, x1), min(z0, z1)}
        max = {max(x0, x1), max(z0, z1)}
        region = %{holder: holder, min: min, max: max, created_seq: state.seq + 1, created_by: actor.cid}
        state = %{state | claim_corners: corners}

        cond do
          Protection.area(region) > tool["region_max_area_m2"] -> {:reply, {:error, :region_too_large}, state}
          length(Protection.held(p, holder)) >= tool["region_max_count"] -> {:reply, {:error, :region_limit}, state}
          Protection.overlaps?(p, min, max) -> {:reply, {:error, :region_overlap}, state}
          region_occupied?(state, region, actor.cid) -> {:reply, {:error, :region_occupied}, state}
          true -> commit_protection(state, state, %{{state.seq + 1, 1} => region})
        end

      match?({_, %{holder: ^holder}}, Protection.region_at(p, cell)) ->
        {id, _} = Protection.region_at(p, cell)
        commit_protection(state, %{state | claim_corners: corners}, %{id => nil})

      Protection.holder(p, cell) != nil ->
        {:reply, {:error, :region_overlap}, state}

      true ->
        {:reply, {:ok, state.seq}, %{state | claim_corners: Map.put(state.claim_corners, actor.player, cell)}}
    end
  end

  # 矩形内有别的角色花材料放下的格或他人建造的 Prefab 实例时不能认领；作者格与天然地形不算占用。
  defp region_occupied?(state, region, cid) do
    inside = &Protection.contains?(region, &1)
    foreign = &(&1 != nil and &1 != cid)
    placer = fn id -> state.instances |> Map.get(id, %{}) |> Map.get(:placed_by) end

    Enum.any?(state.placed_by, fn {cell, by} -> foreign.(by) and inside.(cell) end) or
      Enum.any?(state.macro_owners, fn {cell, id} -> inside.(cell) and foreign.(placer.(id)) end) or
      Enum.any?(state.refined, fn {cell, slots} ->
        inside.(cell) and Enum.any?(slots, fn {_, {_, id}} -> foreign.(placer.(id)) end)
      end)
  end

  # 区域增量独立成一笔事务；边界改变后热工作集（接触图、视线缓存）整体重建，边界两侧液体重新唤醒。
  defp commit_protection(before, state, delta) do
    next = %{state | seq: state.seq + 1, protection: Protection.apply(state.protection, delta)}
    rects = for {id, r} <- delta, r = r || before.protection.regions[id], do: r
    wet = for {cell, _} <- next.liquid_units, Enum.any?(rects, &Protection.contains?(&1, cell, 1)), do: cell
    next = next |> rebuild_thermal_work() |> wake_liquid(wet)
    txn = %{seq: next.seq, entries: [], coarse: [], protection: delta}

    case append_log(next, txn) do
      :ok ->
        next = remember_entry(next, txn)
        fanout(next, txn)
        fanout_canonical(next, txn, [], [], before)
        Logger.info("voxel_protection seq=#{next.seq} changes=#{inspect(delta)} regions=#{map_size(next.protection.regions)}")
        {:reply, {:ok, next.seq}, schedule_liquid(next)}

      {:error, reason} ->
        {:reply, {:error, reason}, before}
    end
  end

  # ---- 受保护区域：物理边界（理想绝热镜面）；无区域时全部原样返回。

  # 节点所在持有者；附件足迹跨持有者时自成一域，与两侧都不接触。
  defp cells_holder(p, cells, key) do
    case cells |> Enum.map(&Protection.holder(p, &1)) |> Enum.uniq() do
      [holder] -> {:holder, holder}
      _ -> {:mixed, key}
    end
  end

  # 热分区 = 受保护区域持有者 × 气候区：分区不同即理想绝热镜面（导热、辐射视线、拟态接触都不跨）。
  # 气候区是大气边界，两侧未记录格各在自己的环境温度静止；若允许跨区导热，边界两侧会在两个无限热库之间
  # 持续传热、不断偏离各自环境而被拉入活动集合（与“埋雪吞并”同类）。无区域且无气候区时原样返回。
  defp thermal_bounded?(state),
    do: not Protection.empty?(state.protection) or VoxelRegion.Climate.zoned?(state.thermal.config)

  defp thermal_holder(state, cell),
    do: {Protection.holder(state.protection, cell), VoxelRegion.Climate.region(state.thermal.config, cell)}

  defp node_holder(state, key, target) do
    case target |> ThermalWork.cells() |> Enum.map(&thermal_holder(state, &1)) |> Enum.uniq() do
      [holder] -> {:holder, holder}
      _ -> {:mixed, key}
    end
  end

  defp protected_contacts(state, nodes) do
    if not thermal_bounded?(state) do
      nodes
    else
      holders = Map.new(nodes, fn {key, n} -> {key, node_holder(state, key, n.target)} end)

      Map.new(nodes, fn {key, n} ->
        {key, %{n | contacts: Enum.filter(n.contacts, fn {other, _} -> Map.get(holders, other) == holders[key] end)}}
      end)
    end
  end

  defp tool_regions(%{eye: {x, y, z}}, range) do
    for rx <- floor((x - range) / 64)..floor((x + range) / 64),
        ry <- floor((y - range) / 64)..floor((y + range) / 64),
        rz <- floor((z - range) / 64)..floor((z + range) / 64),
        do: {0, {rx, ry, rz}}
  end

  defp affected_attachments(state, cells) do
    touched = MapSet.new(cells)

    Enum.filter(Map.keys(state.attachments), fn slot ->
      Enum.any?(Attachments.macros([slot]), &MapSet.member?(touched, &1))
    end)
  end

  # 邻格遮挡／支撑改变可能跨父格；仍存活的附件也必须重算两侧表皮。
  defp attachment_dirty(state, cells),
    do:
      (cells ++ Attachments.macros(affected_attachments(state, cells)))
      |> Enum.uniq()
      |> Enum.map(&{0, &1})
end
