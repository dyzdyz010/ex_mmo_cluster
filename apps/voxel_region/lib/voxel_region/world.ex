defmodule VoxelRegion.World do
  alias VoxelRegion.RefinedSlots
  @moduledoc """
  Voxim R6 的 region 真值：truth = 显式 baseline source ⊕ overlay 日志。

  - **日志**：全局单调 `seq`，每条 `cell` 条目 = canonical 格的新材质 + 服务端算好的各级 reduce 结果（材质 + 表皮，
    从 L1 向上、某级材质与表皮都没变即停）。批次共享一个 seq，父格逐级去重，只规约一次。
    事务同步追加到日志后才确认。在线定时维护与显式 compact 共用一个异步前缀计算任务，
    在热提交边界冻结；World 落盘时只替换已冻结前缀，保留期间提交的后缀。启动迁移仍同步完成。
  - **真值物化**：`region_bases` 保留已提交完整区域的地形；当前 refined、instances、structure 由世界各自唯一持有。
    `overlay` 的 `{level, cell} → {material, skins}` 只保留后续逐格编辑。
    core 依次读取 overlay、区域基底、baseline；ring 从相邻 core 投影，不展开为常驻逐格增量。
  - **载荷**：`serve/1` 从当前基底和 overlay 物化区域，按当前 seq 编码；未受编辑或相邻基底影响的区域原样读 source。
    两者都进 `World.Cache` 的 `{:payload, {level, region}}` 条目（元信息 `Cache.PayloadMetadata`），与原始 prefab 字节共用
    同一个可丢弃有界 LRU（字节上限 `:payload_cache_bytes`，各级一律按最近使用淘汰）；外部运输仍为 `{bytes, header}`，条目碰到的 region 立即失效。
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
  alias VoxelRegion.{Access, Phase, Protection}
  alias MmoContracts.Voxel.{Codec, Payload}
  alias VoxelRegion.World.{Admission, Cache, Clock, Residency, Thermal}
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

  def content_version(server \\ @name), do: VoxelRegion.World.PageLoad.call(server, :content_version)
  def seq(server \\ @name), do: VoxelRegion.World.PageLoad.call(server, :seq)
  @doc "读取最近 512 个已提交操作；nil 建立当前起点，过旧游标返回显式缺口。"
  def interactions_since(server, cursor), do: VoxelRegion.World.PageLoad.call(server, {:interactions_since, cursor})
  def liquid_activity(server), do: VoxelRegion.World.PageLoad.call(server, :liquid_activity)

  @doc "窗口来源与完整XYZ盒的只读CLI报告；仅观察元数据，不决定世界物理是否演化。"
  def simulation_windows(server \\ @name), do: VoxelRegion.World.PageLoad.call(server, :simulation_windows)

  @doc "只读ready输入与本轮固定切点；冷页准备和物理时间真值仍由各自owner持有。"
  def admission_status(server \\ @name), do: VoxelRegion.World.PageLoad.call(server, :admission_status)

  @doc "依赖被明确修复后启动一次模拟IO恢复；loading只表示attempt已发出，不代表恢复完成。"
  def retry_simulation_io(server \\ @name), do: VoxelRegion.World.PageLoad.call(server, :retry_simulation_io)

  @doc "只读驻留需求、持久阻塞和generation统计，不装页或扫描逐槽。"
  def residency_status(server \\ @name), do: VoxelRegion.World.PageLoad.call(server, :residency_status)

  @doc "在World合法回合执行同一驻留维护，供release CLI直接触发与观察。"
  def maintain_residency(server \\ @name), do: VoxelRegion.World.PageLoad.call(server, :maintain_residency)

  @doc "接纳调用进程的完整窗口集合；显式空集合释放来源，不改变世界事务号。"
  def set_simulation_windows(server, boxes), do: VoxelRegion.World.PageLoad.call(server, {:simulation_windows, boxes})

  @doc "流异步发布窗口集合；World 接纳后以 request 回执，流无需同步等待 World。"
  def request_simulation_windows(server, boxes, request) do
    send(server, {:simulation_windows, self(), boxes, request})
    :ok
  end

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
    prepare(server, Enum.map(CollisionSource.regions(box), &{0, &1}), fn ->
      VoxelRegion.World.PageLoad.call(server, {:replica_snapshot, box, pid}, 300_000)
    end)
  end

  @doc "载荷缓存与生成统计，以及区域基底、稀疏增量、refined 宏格和 instance 数量；entries 指缓存条目数。"
  def stats(server \\ @name), do: VoxelRegion.World.PageLoad.call(server, :stats)

  @doc "`POST /voxel/regions` 的整个请求 → 应答 iodata。"
  def serve(server \\ @name, request) when is_binary(request) do
    case Codec.decode_request(request) do
      {:ok, client_version, items} ->
        if Enum.all?(items, &valid_request_item?/1) do
          prepare(server, Enum.map(items, &{&1.level, &1.region}), fn ->

          # 一个 region（含 ring）在 owner 内原子物化；批次之间不独占 owner，交互可在区域之间提交。
          # cv 在 World 生命周期内不变，每个 payload 自带其物化时的 seq/hash。
          cv = VoxelRegion.World.PageLoad.call(server, :content_version, 60_000)

          case Enum.reduce_while(items, {:ok, []}, fn item, {:ok, replies} ->
                 case VoxelRegion.World.PageLoad.call(server, {:serve_item, client_version, item}, 60_000) do
                   {:ok, reply} -> {:cont, {:ok, [reply | replies]}}
                   {:error, _} = error -> {:halt, error}
                 end
               end) do
            {:ok, replies} -> {:ok, Codec.encode_reply(cv, Enum.reverse(replies))}
            error -> error
          end
          end)
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
  defp prepare(server, keys, operation) do
    # 多人加入的快照共用此 mailbox；前置查询沿用后续快照的等待时限，
    # 避免 20 人实验中正常排队被默认 5 秒超时截断。
    with {token, source, source_state, missing} <- VoxelRegion.World.PageLoad.call(server, {:prepare, Enum.uniq(keys)}, 300_000) do
    try do

    Logger.info(
      "voxel_source_return caller=#{inspect(self())} at_us=#{System.system_time(:microsecond)} missing=#{length(missing)}"
    )

    ensure_source(source, source_state, missing)

    if missing != [],
      do: VoxelRegion.World.PageLoad.call(server, {:adopt_liquid, Enum.uniq(for {0, region} <- keys, do: region)}, 300_000),
      else: :ok
    if is_function(operation, 1), do: operation.(token), else: operation.()
    after
      GenServer.cast(server, {:release_preparation, token, self()})
    end
    end
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
    case VoxelRegion.World.PageLoad.call(server, {:prepare_intent, message}, 300_000) do
      {:prepare, token, source, source_state, keys, missing, undecoded} ->
        try do
          ensure_source(source, source_state, missing)
          VoxelRegion.World.PageLoad.call(server, {:prepared_intent, keys, message, decode_sources(source, source_state, undecoded)}, 300_000)
        after
          GenServer.cast(server, {:release_preparation, token, self()})
        end
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

  @doc "运维的单格原始编辑（主体 `:operator`，不受保护区约束）：`{:ok, seq}`（no-op 时是当前 seq）/ `{:error, reason}`。"
  def apply_edit(server \\ @name, coord, material), do: apply_edit(server, :operator, coord, material)

  @doc """
  以指定主体做单格原始编辑；谁能做、能改哪些格由 `VoxelRegion.Access` 判定（玩家角色一律拒绝）。
  无权的主体在装页准备之前就拒绝：注定被拒的请求不读页、不触发来源生成。
  """
  def apply_edit(server, principal, {_, _, _} = coord, material)
      when is_integer(material) and material >= 0 and material <= 255 do
    cond do
      not valid_edit_coord?(coord) -> {:error, :invalid_coordinate}
      (denied = Access.authorize(principal, :raw_edit)) != :ok -> denied
      true -> prepare(server, edit_keys([coord]), fn -> VoxelRegion.World.PageLoad.call(server, {:apply_edit, principal, coord, material}, 60_000) end)
    end
  end

  # 读整张属性表的维护入口：有前缀时先装全部有行的页（M2b），等装页而不用 5 s 默认超时。
  def publish_properties(server, path),
    do: VoxelRegion.World.PageLoad.call(server, {:publish_properties, Damage.load(path)}, 300_000)

  @doc "全局系统作者入口：从明确的旧目录升级可玩参数，保留实例存量并记录热参考重标。"
  def publish_parameters(server, path, expected_digest),
    do: VoxelRegion.World.PageLoad.call(server, {:publish_parameters, Damage.load(path), expected_digest}, 300_000)

  @doc "只测试作者入口：从资产导出的实验参数启动有限供能热源；不开放给 Gate 玩家意图。"
  def thermal_experiment(server, path),
    do: VoxelRegion.World.PageLoad.call(server, {:thermal_experiment, Jason.decode!(File.read!(path))}, 300_000)

  @doc "Test-only: install an MCP-authored finite basin once, before player actions; never a refill source."
  def liquid_experiment(server, path) do
    data = Jason.decode!(File.read!(path))
    edits = Enum.map(data["deposits"], fn row -> {List.to_tuple(row["macro"]), row["material"]} end)
    prepare(server, edit_keys(Enum.map(edits, &elem(&1,0))), fn ->
      VoxelRegion.World.PageLoad.call(server, {:liquid_experiment, edits}, 300_000)
    end)
  end

  @doc """
  全局系统作者入口：一笔事务写入受保护区域 `[%{holder, min: {x, z}, max: {x, z}}]`（闭区间宏格，y 不限），
  holder 为 `:reserved` 或 `{:character, cid}`；与既有区域或彼此重叠时整体拒绝。不经 Gate 暴露。
  """
  def author_regions(server, regions), do: VoxelRegion.World.PageLoad.call(server, {:author_regions, regions}, 300_000)

  @doc "角色确认余额；单位为一个 canonical 微格体积。"
  def material_balances(server, cid),
    do: VoxelRegion.World.PageLoad.call(server, {:material_balances, cid}, 300_000)

  @doc "全局系统功能：服务端授权供给材料，同角色/来源只记账一次；不经 Gate 暴露。"
  def material_supply(server, cid, supply_id, quantities),
    do: VoxelRegion.World.PageLoad.call(server, {:material_supply, cid, supply_id, quantities}, 300_000)

  @doc """
  只测试作者注水入口（与 `material_supply/4` 同类，不经 Gate、不进分发）：从 seed 宏格六邻洪泛液体可进入的开放格
  （空气、同种液体、地面花草；y ≤ level_y、液体计算域内、不跨受保护区域持有者，且角色可在其中建造），全部灌满到单格容量。
  按实际注入量从角色库存扣 material（库存相态焓随量搬入），不足整笔拒绝 `:insufficient_material`；洪泛超过
  `opts[:max_cells]`（默认 4096）拒绝 `:liquid_fill_too_large`。一笔正常液体提交（数量、相态、余额、日志）；
  同角色同 key 只执行一次，重试返回原回执 `{:ok, %{seq, material, units, cells}}`。
  `opts[:timeout]` 控制本次裁决等待（默认 300 秒）；超时仅取消未接纳的装页等待，已提交结果仍按 key 查询。
  """
  def liquid_fill(server, cid, key, material, seed, level_y, opts \\ []) do
    prepare(server, edit_keys([seed]), fn ->
      VoxelRegion.World.PageLoad.call(server, {:liquid_fill, cid, key, material, seed, level_y, Keyword.get(opts, :max_cells, 4096)}, Keyword.get(opts, :timeout, 300_000))
    end)
  end

  @doc """
  只测试 GM 施工工具（`VoxelRegion.World.Gm`，不进分发，部署显式开启才可用）：op 为 `:clear`（%{box, precision, instances}）、
  `:fill`（%{box, material, precision}）、`:liquid_fill`（%{seed, level_y, material}）、`:drain`（%{box, material 可省}）、`:move_instance`
  （%{instance, anchor, orientation}）、`:recolor`（%{from, to, box 或 cells}，未细化无归属无附件的实体宏格原位换料）。
  每次一笔正常 World 提交；同 key 只执行一次，返回 `{:ok, 回执}`。
  """
  def gm(server \\ @name, key, op, args)
  def gm(server, key, :move_instance, args) do
    case VoxelRegion.World.PageLoad.call(server, {:gm_prepare, key, args}, 300_000) do
      {:done, result} -> result
      {:ready, id} ->
        with {:ok, geometry} <- prefab_geometry(server, id),
          do: VoxelRegion.World.PageLoad.call(server, {:gm, key, :move_instance, args, geometry}, 300_000)
    end
  end
  def gm(server, key, op, args) do
    keys = case op do
      op when op in [:clear, :fill] -> edit_keys(VoxelRegion.World.Gm.macros(args))
      :recolor ->
        case VoxelRegion.World.Gm.recolor_cells(args) do
          {:ok, cells} -> edit_keys(cells)
          {:error, _} -> []
        end
      :liquid_fill -> edit_keys([args.seed])
      _ -> []
    end
    prepare(server, keys, fn -> VoxelRegion.World.PageLoad.call(server, {:gm, key, op, args}, 300_000) end)
  end

  @doc """
  全局系统维护：导出半开宏格盒 `{lo, hi}` 的完整 L0 地块（`VoxelRegion.World.Parcel`）。
  只经 release rpc 调用；返回 `{:ok, parcel}` 或拒绝原因。
  """
  def parcel_export(server \\ @name, box) do
    with {:ok, parcel, ids} <- VoxelRegion.World.PageLoad.call(server, {:parcel_export, box}, :infinity),
         {:ok, definitions} <- VoxelRegion.World.PageLoad.call(server, {:prefab_request, {:definitions, ids}}, 300_000),
      do: {:ok, %{parcel | definitions: definitions}}
  end

  @doc """
  全局系统维护：把地块整体平移整米 delta 后装入本世界，一笔正常提交；同 key 只装一次，返回 `{:ok, 回执}`。
  维护窗口内经 release rpc 调用，不接 Gate。
  """
  def parcel_install(server \\ @name, key, parcel, delta) do
    case VoxelRegion.World.PageLoad.call(server, {:parcel_prepare, key}) do
      {:done, result} -> result
      :ready ->
        with {:ok, definitions} <- VoxelRegion.World.PageLoad.call(server, {:prefab_request, {:import, parcel.definitions}}, 300_000),
          do: VoxelRegion.World.PageLoad.call(server, {:parcel_install, key, parcel, delta, definitions}, :infinity)
    end
  end

  @doc """
  全局系统维护：安装一座传送信标的记录（`VoxelRegion.World.Beacons`）。record = `%{id, name, core, landing}`：
  core 为核心内一个微格坐标、须已是锚心石；landing 为落点探针（米）。同 key 只装一次，返回 `{:ok, 回执}`。
  信标几何经 prefab／地块入口先放好；本入口只写记录。维护窗口内经 release rpc 调用，不接 Gate。
  """
  def beacon_install(server \\ @name, key, record),
    do: VoxelRegion.World.PageLoad.call(server, {:beacon_install, key, record}, 300_000)

  @doc "全局系统功能：角色的信标目录（全部信标，各带是否已调谐），供 Gate 下发 0x87。"
  def beacon_directory(server \\ @name, cid), do: VoxelRegion.World.PageLoad.call(server, {:beacon_directory, cid}, 300_000)

  @doc "全局系统功能：同一事务位置下的指定角色余额与格占用投影；detail=:micro 增加细化格精确坐标，不读取热/液体模拟状态。"
  def material_snapshot(server, characters, cells, detail \\ :summary) when detail in [:summary, :micro] do
    prepare(server, Enum.uniq(Enum.map(cells, &{0, region_of(&1)})), fn ->
    message = if detail == :summary, do: {:material_snapshot, characters, cells},
      else: {:material_snapshot, characters, cells, detail}
    VoxelRegion.World.PageLoad.call(server, message, 300_000)
    end)
  end

  @doc """
  全局系统功能：同一提交点的角色材料/相态库存、指定范围属性和有限液体数量。
  box 沿既有 canonical 的 region 半开范围；不生成区域、不初始化模拟、不返回配置或缓存。
  thermal_accounting 是整个世界累计结算账；做守恒比较的调用方必须独占该世界。
  `timeout` 是本次调用的等待时限；超时只取消未接纳的装页等待，保持结果未知语义。
  """
  def simulation_snapshot(server, characters, box, timeout \\ 300_000),
    do: VoxelRegion.World.PageLoad.call(server, {:simulation_snapshot, characters, box}, timeout)

  @doc "读取一批已由感知入口限距的 canonical 射线；共享 World seq，不修改世界事务。独立附件未采样。"
  def sight_snapshot(server, origin, rays),
    do: VoxelRegion.World.PageLoad.call(server, {:sight_snapshot, origin, rays}, 300_000)

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
      case VoxelRegion.World.PageLoad.call(server, {:tool_range, request.tool_id}, 300_000) do
        {:error, _} = error ->
          error

        range ->
          prepare(server, tool_regions(actor, range) ++ edit_keys(cells), fn ->
            VoxelRegion.World.PageLoad.call(server, {:attachment_intent, actor, request}, 300_000)
          end)
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
  def tool_definition(server, id), do: VoxelRegion.World.PageLoad.call(server, {:tool_definition, id})

  @doc "异步停止旧 Player 的身体接触；同一 World 发出的既有 body_heat 先于 body_detached 到达。"
  def body_detach(server, cid, pid, ref), do: send(server, {:body_detach, cid, pid, ref})

  @doc "人物工具作用的世界授权：当前 canonical 遮挡和既有工具频率；身体提交由目标 owner 完成。"
  def body_tool(server, actor, request, distance) do
    prepare(server, tool_regions(actor, distance), fn ->
      VoxelRegion.World.PageLoad.call(server, {:body_tool, actor, request, distance}, 300_000)
    end)
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
    keys = with 1 <- request.action, range when is_number(range) <- VoxelRegion.World.PageLoad.call(server, :magic_range, 300_000) do
      tool_regions(actor, range)
    else
      _ -> []
    end
    prepare(server, keys, fn -> VoxelRegion.World.PageLoad.call(server, {:spell_intent, actor, request}, 300_000) end)
  end

  @doc "全局系统功能（魔法增量 1）：施法者状态（登录时下发一次）；世界未配置魔法目录时 `{:error, :magic_unavailable}`。"
  def caster_state(server, cid), do: VoxelRegion.World.PageLoad.call(server, {:caster_state, cid}, 300_000)

  @doc """
  全局系统功能：已加载魔法目录的 digest（目录文件字节的 sha256，0x82 请求的 catalog_digest 与它比对）；未配置魔法目录时
  nil。只读。玩家客户端从同一发布文件自算这个值；NPC Body 的执行进程在施放投递前用它填请求（能力库设计稿 §7.8）。
  """
  def magic_digest(server), do: VoxelRegion.World.PageLoad.call(server, :magic_digest, 300_000)

  @doc "全局系统功能：由 World 有序出口发送登录施法者状态，和报价、结算及身体变化共用同一发送者。"
  def send_caster_state(server, cid, request_id, recipient),
    do: VoxelRegion.World.PageLoad.call(server, {:send_caster_state, cid, request_id, recipient}, 300_000)

  @doc "B6 玩家燃烧意图，复用 DamageInput 的目标、会话、射程与速率校验。"
  def combustion_intent(server, actor, request), do: tool_intent(server, actor, request)

  def place_prefab(server \\ @name, definition_id, anchor, orientation) do
    with {:ok, geometry} <- prefab_geometry(server, definition_id),
         {:ok, cells, _} <- VoxelRegion.World.Prefabs.definition_cells(geometry, anchor, orientation) do
      prepare(server, prefab_keys(cells), fn ->
        VoxelRegion.World.PageLoad.call(server, {:place_prefab, definition_id, anchor, orientation, geometry}, 300_000)
      end)
    end
  end

  @doc "玩家Prefab操作只准备所需id几何，最终身份/权限/余额仍由World裁决。"
  def prefab_intent(server, actor, kind, request) do
    with {:ok, geometry} <- if(kind == :voxel_prefab_remove_v1, do: {:ok, nil}, else: prefab_geometry(server, request.definition_id)) do
      cells = case kind do
        :voxel_prefab_place_v1 ->
          with {:ok, _, macros} <- VoxelRegion.World.Prefabs.definition_cells(geometry, request.anchor, request.orientation), do: {:ok, macros}
        :voxel_prefab_remove_v1 -> instance_cells(server, request.instance_id)
        :voxel_prefab_replace_v1 -> VoxelRegion.World.PageLoad.call(server, {:replacement_cells, request.instance_id, geometry}, 300_000)
      end
      commit = fn -> VoxelRegion.World.PageLoad.call(server, {:prefab_intent, actor, kind, request, geometry}, 300_000) end
      case cells do
        {:ok, cells} -> prepare(server, region_keys(Enum.map(cells, &{0, &1})), commit)
        # 预查格只决定要准备哪些页，不是裁决：实例已不存在时（如已成功拆除的同一请求重发）
        # 仍交 World 按 build_sessions 幂等重放或给出它自己的权威错误，不在 wrapper 先行拒绝。
        {:error, _} -> commit.()
      end
    end
  end

  def remove_prefab(server \\ @name, instance_id),
    do: VoxelRegion.World.PageLoad.call(server, {:remove_prefab, instance_id}, 300_000)

  def publish_prefabs(server \\ @name, path) do
    {:ok, catalog} = VoxelRegion.Prefab.Catalog.open(path, nil)
    VoxelRegion.World.PageLoad.call(server, {:publish_prefabs, catalog}, 300_000)
  end

  # 全局系统功能：运行时内容发布与工作台只读目录；不产生体素事务。name 为玩家输入的名称，NPC 发布为空名。
  def publish_prefab(server, actor, bytes, name \\ "") do
    with :ok <- Prefab.check_name(name),
         {:ok, id, geometry} <- compile_prefab(server, bytes),
      do: VoxelRegion.World.PageLoad.call(server, {:publish_prefab, actor, {id, bytes, geometry}, name}, 300_000)
  end

  def prefab_catalog(server \\ @name), do: VoxelRegion.World.PageLoad.call(server, :prefab_catalog)

  @doc "按id读取原VXPD字节，保留旧版本与内容身份。"
  def prefab_definition(server, id), do: VoxelRegion.World.PageLoad.call(server, {:prefab_request, {:definition, id}}, 300_000)
  @doc "按id准备本请求完整几何；目录不长期保存该结果。"
  def prefab_geometry(server, id), do: VoxelRegion.World.PageLoad.call(server, {:prefab_request, {:geometry, id}}, 300_000)
  @doc "只装草稿实际子闭包并沿原发布预算编译。"
  def compile_prefab(server, bytes), do: VoxelRegion.World.PageLoad.call(server, {:prefab_request, {:compile, bytes}}, 300_000)
  @doc "只装草稿实际子闭包并保留原预览诊断。"
  def preview_prefab(server, bytes), do: VoxelRegion.World.PageLoad.call(server, {:prefab_request, {:preview, bytes}}, 300_000)

  @doc "全局系统功能（D3-2）：运行时发布的 {首个发布者 cid, 首次名称, 定义字节}，按发布序；不含作者目录。"
  def published_prefabs(server \\ @name) do
    published_prefab_metadata(server)
    |> Enum.reduce_while([], fn row, rows ->
      case prefab_definition(server, row.id) do
        {:ok, bytes} -> {:cont, [{row.publisher, row.name, bytes} | rows]}
        error -> {:halt, error}
      end
    end)
    |> case do
      rows when is_list(rows) -> Enum.reverse(rows)
      error -> error
    end
  end
  @doc "发布元信息的薄投影，保留原顺序；不读取任何定义正文。"
  def published_prefab_metadata(server \\ @name), do: VoxelRegion.World.PageLoad.call(server, :published_prefab_metadata)
  def material_catalog(server \\ @name), do: VoxelRegion.World.PageLoad.call(server, :material_catalog)

  def replace_prefab(server \\ @name, instance_id, definition_id) do
    with {:ok, geometry} <- prefab_geometry(server, definition_id),
         {:ok, cells} <- VoxelRegion.World.PageLoad.call(server, {:replacement_cells, instance_id, geometry}, 300_000) do
      prepare(server, region_keys(Enum.map(cells, &{0, &1})), fn ->
        VoxelRegion.World.PageLoad.call(server, {:replace_prefab, instance_id, geometry}, 300_000)
      end)
    end
  end

  def replacement_cells(server, instance_id, definition_id) do
    with {:ok, geometry} <- prefab_geometry(server, definition_id),
      do: VoxelRegion.World.PageLoad.call(server, {:replacement_cells, instance_id, geometry}, 300_000)
  end

  def prefab_cells(server, id, anchor, orientation) do
    with {:ok, geometry} <- prefab_geometry(server, id),
         {:ok, cells, _} <- VoxelRegion.World.Prefabs.definition_cells(geometry, anchor, orientation), do: {:ok, cells}
  end

  # 只带 id：内存里没有时经定位表装页（M2b），与其他装页入口同一等待时限。
  def instance_cells(server, id), do: VoxelRegion.World.PageLoad.call(server, {:instance_cells, id}, 300_000)

  defp prefab_keys(cells) do
    cells |> footprint_macros() |> Enum.map(&{0, &1}) |> region_keys() |> Enum.uniq()
  end

  def subscribe(server \\ @name, pid, have_seq, {{_, _, _}, {_, _, _}} = box, coarse_min_level) do
    VoxelRegion.World.PageLoad.call(server, {:subscribe, pid, have_seq, box, coarse_min_level})
  end

  def entries_after(server \\ @name, seq), do: VoxelRegion.World.PageLoad.call(server, {:entries_after, seq})

  @doc "预备 canonical L0 来源，在同一 World 回合冻结观察切点并订阅后续全部事务；快照由发送进程组装。"
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

    prepare(world_ref, Enum.map(CollisionSource.regions(l0_box), &{0, &1}), fn token ->
      Logger.info(
        "voxel_window_stage stage=prepare_done request=#{inspect(request_ref)} pid=#{inspect(self())} at_us=#{System.system_time(:microsecond)} elapsed_us=#{System.monotonic_time(:microsecond) - started}"
      )
      VoxelRegion.World.PageLoad.call(
        world_ref,
        {:canonical_snapshot, l0_box, subscriber_pid, request_ref, include_chunks, token},
        300_000
      )
    end)
  end

  @doc "运维的多格原始编辑（主体 `:operator`）：原子提交，每级父格去重后规约。"
  def apply_edits(server \\ @name, edits), do: apply_edits(server, :operator, edits)

  @doc """
  以指定主体做多格原始编辑；授权见 `VoxelRegion.Access`（创世 NPC 传 `{:genesis, cid}`）。
  无权的主体在装页准备之前就拒绝（同 `apply_edit/4`）。
  """
  def apply_edits(server, principal, edits) do
    valid = Enum.all?(edits, fn
      {{_, _, _} = coord, _material} -> valid_edit_coord?(coord)
      _ -> false
    end)

    cond do
      not valid -> {:error, :invalid_coordinate}
      (denied = Access.authorize(principal, :raw_edit)) != :ok -> denied
      true ->
        prepare(server, edit_keys(Enum.map(edits, &elem(&1, 0))), fn ->
          VoxelRegion.World.PageLoad.call(server, {:apply_edits, principal, edits}, 300_000)
        end)
    end
  end

  @doc "压实完整前缀；覆盖调用时的事务序号且落盘后才回复，期间World继续处理后缀提交。"
  def compact(server \\ @name), do: VoxelRegion.World.PageLoad.call(server, :compact, 300_000)

  @doc """
  全局系统维护：停服后一次性重建粗层，独占数据库与新 baseline 目录。

  仅供 release eval／离线工具调用；不启动 World、网络或模拟，不增加事务序号。
  opts 与 start_link/1 的存储、目录选项一致。新 L1–L5 baseline 须预先烘齐；
  返回重建统计。调用方必须保证没有其他 World 使用同一个日志库。
  """
  def rebuild_coarse(opts) do
    Task.async(fn ->
      {:ok, state} = restore(opts)
      # 离线重建读整个世界：有前缀时先装全部有行的页（同进程，装页入口与在线相同）。
      state = load_all(state)
      if state.checkpoint_timer, do: Process.cancel_timer(state.checkpoint_timer)
      VoxelRegion.World.CoarseRebuild.run(%{state | checkpoint_timer: nil})
    end)
    |> Task.await(:infinity)
  end

  defp load_all(%{resident: :all} = state), do: state

  defp load_all(%{log: {backend, handle}} = state) do
    pages =
      for {level, region, segment} <- backend.page_keys(handle), uniq: true,
          do: if(segment in VoxelRegion.World.Pages.fragment_codes(), do: {0, region}, else: {level, region})

    %{VoxelRegion.World.PageLoad.load_sync(state, [], pages, []) | resident: :all}
  end

  # ---- GenServer

  # 在线启动与离线维护共用同一个完整日志恢复入口；恢复本身不迁移真值、不唤醒模拟。
  defp restore(opts) do
    source = Keyword.get(opts, :source, FileStore)

    case source.open(opts) do
      {:ok, source_state} ->
        cv = source.content_version(source_state)
        world_dir = source.world_dir(source_state)
        author_catalog = Keyword.get(opts, :prefab_catalog_path, Application.get_env(:voxel_region, :prefab_catalog_path))
        runtime_catalog = Path.join(world_dir, "prefabs")
        # 启动准备进程只捕获两个路径；完整解析／展开在其堆内结束，World仅接纳轻描述。
        {:ok, prefabs, published} = Task.async(fn ->
          with {:ok, catalog} <- VoxelRegion.Prefab.Catalog.open(author_catalog, runtime_catalog),
            do: {:ok, catalog, VoxelRegion.Prefab.Catalog.publications(runtime_catalog, catalog)}
        end)
          |> Task.await(:infinity)

        # 正式启动用 DataService 表（application.ex）；不起数据库的测试默认文件后端。
        log = Keyword.get(opts, :log, OverlayLog.File)

        cache_limit =
          Keyword.get(
            opts,
            :payload_cache_bytes,
            Application.get_env(:voxel_region, :payload_cache_bytes, @default_cache_bytes)
          )

        # 缓存容量由Cache维护；二进制GC阈值沿用VM策略，不由缓存预算抬高回收下限。
        state = %{
          clock: Keyword.get(opts, :clock, {Clock, nil}),
          circuit_component_limit: VoxelRegion.World.CircuitAdmission.configure(opts),
          source: source,
          source_state: source_state,
          cv: cv,
          decoded: %{},
          region_bases: %{},
          snapshots: MapSet.new(),
          cache: Cache.new(cache_limit),
          served_headers: %{},
          overlay: %{},
          refined: %{},
          # refined 的派生索引（部件 => 宏格、L0 区域 => 该区 refined 子表），由 Canonical.put_refined/3 随 refined 维护，不持久化。
          refined_owners: %{},
          refined_regions: %{},
          refined_region_owners: %{},
          attachments: %{},
          # attachments 的派生索引（L0 区域 => 锚点在该区的槽），由 Canonical.put_attachments/drop_attachments 维护，不持久化。
          attachment_regions: %{},
          attachment_serial: 0,
          attachment_owners: %{},
          # Global system: finite quantity is canonical state, never reconstructed from rendering.
          liquid_units: %{},
          # liquid_units 的派生索引（L0 区域 => 该区数量子表），由 Canonical.put_liquid/2 维护，不持久化。
          liquid_regions: %{},
          liquid_active: MapSet.new(),
          # 已核对过没有待接纳液体格的区域载荷字节（Liquids.adopt_liquid_sources/2 的派生备忘，不持久化）。
          liquid_adopted: %{},
          liquid_falls: %{},
          liquid_timer: nil,
          # 下一未完成液体自然步的单调到期毫秒；等待装页/写回不清除。
          liquid_due: nil,
          # Test-only first-slice domain; the demo supplies its closed experimental bounds.
          liquid_bounds: Keyword.get(opts, :liquid_bounds, Application.get_env(:voxel_region, :liquid_bounds)),
          damage: %{},
          epochs: %{},
          tool_sessions: %{},
          thermal: load_thermal_environment(opts),
          thermal_work: ThermalWork.new(),
          # 下一未完成热自然步的单调到期毫秒；只有自然稳态才清除，等待不重置。
          thermal_due: nil,
          # 待到期节拍的定时器；nil 表示没有（休眠，或进行中的提交完成时再排）。
          thermal_timer: nil,
          # 最近一次零功率热提交之后的事务号：此后没有新事务时，电路种子本身不再推进热提交。
          thermal_quiet_seq: nil,
          # 进行中的分步热提交；nil 表示两次提交之间。
          thermal_run: nil,
          projectile_backend: Keyword.get(opts, :projectile_backend, Application.get_env(:voxel_region, :projectile_backend)),
          projectile_timer: nil,
          projectile_task: nil,
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
          # 只测试 GM 工具开关（World.Gm）：部署显式开启才为 true；不持久化。
          gm_tools: Keyword.get(opts, :gm_tools, VoxelRegion.World.Gm.enabled?()),
          # 合成账（R8-04）：材料 => 合成造成的累计净单位变化；随日志／检查点持久化。
          craft_ledger: %{},
          # 食物账（身体闭环 H1）：材料 => 被吃掉的累计单位（物质离开世界进入身体）；随日志／检查点持久化。
          food_ledger: %{},
          food_receipts: %{},
          # 溯源：花材料放下的 macro 格 => 放置者 cid。作者入口写的格、天然地形、液体流动改的格都无主；格一被别的编辑改动就清掉。
          placed_by: %{},
          macro_owners: %{},
          # macro_owners 的派生索引（L0 区域 => 该区子表、归属 => 宏格），由 Canonical.put_macro_owner/3 维护，不持久化。
          macro_owner_regions: %{},
          macro_owner_cells: %{},
          # 受保护区域（全局系统）：唯一真值，随日志/检查点持久化；物理边界与意图许可都只读它。
          protection: Protection.new(),
          # 传送信标（全局系统）：信标记录与角色调谐，随日志/检查点持久化（World.Beacons）。
          beacons: %{},
          beacon_attunements: %{},
          # 开发期部署开关：全员视为已调谐全部信标；不持久化。
          beacons_all_attuned: Keyword.get(opts, :beacons_all_attuned, VoxelRegion.World.Beacons.all_attuned?()),
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
          published: published,
          prefabs: prefabs,
          prefab_requests: %{},
          prefab_source_bytes: 0,
          overlay_regions: %{},
          # 页索引与攒下的脏单元（M2a，`World.Pages`），派生、不持久化。
          pages: VoxelRegion.World.Pages.new(),
          page_dirty: MapSet.new(),
          # 本笔写入口碰过的身份（覆盖页集合按根重算，`Pages.remember/2` 取走）。
          owners_touched: MapSet.new(),
          # 驻留集（`:all`为全量迁移哨兵）、P1退休推进的页代数及装页任务；有限观察不改变活动资格。
          resident: :all,
          page_generation: %{},
          page_load: VoxelRegion.World.PageLoad.new(),
          residency: Residency.new(),
          # structure 的 `(level, L0 页)` 片段索引、L1–L5 树冠片段与附件 id 的区域计数（M2b 派生，可由驻留真值重算）。
          structure_pages: %{},
          canopy: %{},
          aid_regions: %{},
          seq: 0,
          interaction_history: [],
          interaction_floor: 0,
          entries: %{},
          # 只供离线粗层重建（`CoarseRebuild`）沿用旧检查点函数；在线持久化走页表切点（`page_store`）。
          checkpoint_timer: nil,
          checkpoints: 0,
          # M2a 页表切点与写回进程（`World.PageCut`）；`published` 由恢复路径填。
          page_store: VoxelRegion.World.PageCut.new(nil, opts),
          entry_regions: %{},
          subs: %{},
          canonical_subs: %{},
          canonical_feeds: %{},
          canonical_snapshots: %{},
          simulation_windows: %{},
          # 只存本轮依赖ready的不可变输入；冷请求仍在PageLoad，不阻塞无关ready输入。
          input_ready: :queue.new(),
          input_current: nil,
          input_scheduled: false,
          replica_subs: %{},
          log: {log, log.open(world_dir, cv)}
        }

        {:ok, restore_pages(state)}

      {:error, :no_world} ->
        {:stop, {:no_world, Keyword.fetch!(opts, :root)}}
    end
  end

  @impl true
  def init(opts) do
    case restore(opts) do
      {:ok, state} ->
        state = environment_tolerance(state, load_thermal_environment(opts))
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
        # 未迁移 / 全新世界（尚无已发布前缀，内存即全部真值）：全量派生 structure 与树冠片段，全部非空单元都要写，首个切点即迁移（m2a §7）。
        # 索引在规范化（旧 g=1 行并成整件行等）之后从全量状态重建，规范化的结果随首个切点写出。
        # 有前缀（M2b）：structure / 树冠随页片段装入，不全量重算；整件几何汇总在窗口快照时按盒准备。
        state =
          if state.page_store.published == nil do
            {state, _, _} = refresh_structure(state, Map.keys(state.refined))
            state = VoxelRegion.World.Canopy.refresh_all(state)
            state = VoxelRegion.World.Pages.rebuild(state)
            %{state | page_dirty: VoxelRegion.World.Pages.units(state), page_store: %{state.page_store | wanted: true}}
          else
            state
          end
        state = state |> VoxelRegion.World.PageCut.start_writer() |> VoxelRegion.World.PageCut.maybe_open()
        # 重启时后缀可能已很长（上次写回卡住）：按恢复后的积压定级，接纳从第一条请求起生效。
        state = VoxelRegion.World.PageCut.assess(state)
        state = Thermal.rebuild_work(state)

        Logger.info(
          "voxel_region world #{FileStore.hex(state.cv)} ready, seq=#{state.seq}, resident=#{resident_count(state)}, " <>
            "root=#{state.source.world_dir(state.source_state)}"
        )

        state = schedule_liquid(state)
        state = Thermal.wake(state)
        state = VoxelRegion.World.Projectiles.wake(state)
        {:ok, state}

      error -> error
    end
  end

  # 积压硬上限（m2a §5.3）：会产生新提交的调用在任何裁决、扣账、创建身份或消费意图状态之前拒绝，经各入口既有的
  # `{:error, reason}` 回执（客户端为 `ResultFrame.error`）。工具 / 施法的 action 0 只查询、不提交，照常服务。
  # 进行中的动作（已接纳的施法、信标读条、热 / 液体步进）走到自己的提交边界；回落由写回确认恢复（`PageCut.assess/1`）。
  @commit_calls [:apply_edit, :apply_edits, :tool_intent, :production_intent, :attachment_intent, :prefab_intent,
    :place_prefab, :remove_prefab, :replace_prefab, :spell_intent, :material_supply, :liquid_fill, :gm, :parcel_install,
    :beacon_install, :author_regions, :liquid_experiment, :thermal_experiment, :publish_properties, :publish_parameters,
    :prepare, :adopt_liquid, :prepare_intent, :prepared_intent]

  defguardp backlog_rejects?(message, state)
            when state.page_store.level == :hard and is_tuple(message) and elem(message, 0) in @commit_calls and
                   not (elem(message, 0) in [:tool_intent, :spell_intent] and :erlang.map_get(:action, elem(message, 2)) == 0)

  # 热提交进行中，原生热域可能有尚未写回的节点：调用先写回属性记录（唯一真值），读到的与逐步写回时相同。
  # 豁免的消息整条处理链都不读写属性记录（区域载荷、工具目录、版本号），不必写回；身体接触只读脚格温度，
  # 由 Thermal.body_contacts 直接读原生侧当前值。
  @unflushed [:serve_item, :tool_definition, :content_version, :seq, :body_coherence, :body_contact, :interactions_since,
    :window_input, :window_geometry, :window_finished, :simulation_windows]

  # 装页任务与 World 的往来（M2b `World.PageLoad`）：不过闸、不写回热域。
  @page_calls [:page_need, :page_adopt, :page_stage, :page_commit, :page_yield, :window_input, :window_geometry, :window_finished, :simulation_windows, :prefab_inputs, :prefab_loaded, :prefab_known]

  # 统一授权的执行点：每个请求先经 `VoxelRegion.Access.admit/1`（未登记的消息、无权的主体在这里拒绝），再进入接纳与装页。
  @impl true
  def handle_call({:page_request, request, message}, from, state) do
    case Access.admit(message) do
      :ok -> gate_input(Admission.input({:call, message, from}, Clock.monotonic(state), request), state, 0) |> continue_callback()
      error -> {:reply, error, state}
    end
  end

  def handle_call(message, from, state) do
    case Access.admit(message) do
      :ok -> gate_input(Admission.input({:call, message, from}, Clock.monotonic(state)), state, 0) |> continue_callback()
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_cast({:page_cancel, request}, state) do
    {:noreply, cancel_input(state, request) |> Residency.request() |> Residency.maintain() |> schedule_inputs()}
  end

  def handle_cast({:release_preparation, token, caller}, state) do
    {:noreply, state |> VoxelRegion.World.PageLoad.release_preparation(token, caller) |> Residency.request() |> Residency.maintain() |> schedule_inputs()}
  end

  # 冷准备不占ready队列；同action/body的held直到真正接纳、失败或取消才释放。
  defp gate_input({:input, _context, entry} = input, state, attempt) do
    alias VoxelRegion.World.PageLoad
    message = Admission.message(input)
    key = PageLoad.order_key(message)
    failure = PageLoad.failure(state)

    cond do
      physical_input?(message) and not confirmed_input?(message) and failure != nil ->
        reject_simulation_input(input, state, failure.reason, not (attempt == 0 and PageLoad.held?(state, key)))
      match?({:call, _, _}, entry) and backlog_rejects?(message, state) ->
        finish_input(input, {:reply, {:error, :persist_backlog}, state})
      match?({:call, _, _}, entry) and is_tuple(message) and elem(message, 0) in @page_calls ->
        {:call, _, from} = entry
        call(message, from, state)
      attempt == 0 and PageLoad.held?(state, key) ->
        {:noreply, PageLoad.enqueue(state, key, input)}
      true ->
        case PageLoad.gate(state, Admission.preparing(input), attempt) do
          {:ready, state} ->
            if physical_input?(message), do: ready_input(input, state), else: run_input(input, state)
          {:deferred, state} -> {:noreply, PageLoad.hold(state, key)}
        end
    end
  end

  defp call(message, from, %{thermal_work: %{domain: %{pending: true}}} = state)
      when not (is_tuple(message) and elem(message, 0) in @unflushed) and message not in @unflushed,
      do: call(message, from, Thermal.flush(state, if(is_tuple(message), do: elem(message, 0), else: message)))

  defp call({:page_need, keys, exact, ids}, _from, state),
    do: {:reply, VoxelRegion.World.PageLoad.need(state, keys, exact, ids), state}

  defp call({:page_need, keys, exact, ids, task}, _from, state) do
    reply = VoxelRegion.World.PageLoad.need(state, keys, exact, ids, task)
    {:reply, reply, VoxelRegion.World.PageLoad.reserve(state, task, reply)}
  end

  # 分批暂存（每批一个有上界的回合）、整树闭合后一次标驻留、撞上别的任务暂存页时让出（M2b 统筹第四轮）。
  defp call({:page_stage, task, keys, units, ready}, _from, state) do
    started = System.monotonic_time(:microsecond)
    {state, loaded, ready} = VoxelRegion.World.PageLoad.stage(state, task, keys, units, ready)
    Logger.info("voxel_page_stage pages=#{length(keys)} units=#{length(units)} ready=#{length(ready)} " <>
      "us=#{System.monotonic_time(:microsecond) - started}")
    state = Thermal.touch(state, loaded)
    {:reply, {:ok, length(loaded)}, if(ready == [], do: state, else: schedule_liquid(state))}
  end

  defp call({:page_commit, task}, _from, state) do
    started = System.monotonic_time(:microsecond)
    {reply, state} = VoxelRegion.World.PageLoad.commit(state, task)
    Logger.info("voxel_page_commit reply=#{if reply == :ok, do: :ok, else: :more} us=#{System.monotonic_time(:microsecond) - started}")
    {:reply, reply, schedule_liquid(state)}
  end

  defp call({:page_yield, task, other}, _from, state), do: {:reply, :ok, VoxelRegion.World.PageLoad.yield(state, task, other)}

  defp call({:page_adopt, tokens, rows, located}, _from, state) do
    started = System.monotonic_time(:microsecond)
    {state, follow, loaded} = VoxelRegion.World.PageLoad.adopt(state, tokens, rows, located)
    Logger.info("voxel_page_adopt pages=#{length(tokens)} rows=#{length(rows)} us=#{System.monotonic_time(:microsecond) - started}")
    {:reply, follow, state |> Thermal.touch(loaded) |> schedule_liquid()}
  end

  defp call(:page_resident_all, _from, state), do: {:reply, :ok, %{state | resident: :all}}

  defp call(:content_version, _from, state), do: {:reply, state.cv, state}
  defp call(:seq, _from, state), do: {:reply, state.seq, state}
  defp call(:residency_status, _from, state), do: {:reply, Residency.observe(state), state}
  defp call(:maintain_residency, _from, state) do
    state = state |> Residency.request() |> Residency.maintain()
    {:reply, Residency.observe(state), state}
  end
  defp call(:simulation_windows, _from, state),
    do: {:reply, VoxelRegion.World.SimulationWindows.observe(state.simulation_windows), state}
  defp call(:admission_status, _from, state),
    do: {:reply, Map.put(Admission.observe(state.input_ready), :held_sequences, map_size(state.page_load.held)), state}
  defp call(:retry_simulation_io, _from, state) do
    {reply, state} = VoxelRegion.World.PageLoad.retry(state)
    {:reply, reply, state}
  end
  defp call({:simulation_windows, boxes}, {source, _}, state) do
    {reply, state} = accept_simulation_windows(state, source, boxes)
    {:reply, reply, state}
  end
  defp call({:interactions_since, cursor}, _from, state),
    do: {:reply, VoxelRegion.World.Interactions.since(state, cursor), state}
  defp call(:liquid_activity, _from, state), do:
    {:reply, %{active_cells: MapSet.size(state.liquid_active), scheduled: state.liquid_timer != nil}, state}
  defp call(:source, _from, state), do: {:reply, {state.source, state.source_state}, state}

  defp call({:prepare, keys}, {caller, _}, state) do
    started = System.monotonic_time(:microsecond)
    at = System.system_time(:microsecond)
    # 已物化载荷可直接供 payload_bytes 读取；预备不再重复触碰来源磁盘。
    # decoded() 的来源需求仍独立判断，载荷缓存不升格为世界真值。
    missing =
      Enum.filter(keys, &(needs_source?(state, &1) and not cached?(state, &1)))

    Logger.info(
      "voxel_source_prepare caller=#{inspect(caller)} at_us=#{at} elapsed_us=#{System.monotonic_time(:microsecond) - started} keys=#{length(keys)} missing=#{length(missing)}"
    )

    # 已驻留时本次 owner 调用即可完成接纳，避免排到下一轮热提交之后。
    adopt_started = System.monotonic_time(:microsecond)
    state = if missing == [],
      do: adopt_liquid_regions(state, Enum.uniq(for {0, region} <- keys, do: region)), else: state
    finished = System.monotonic_time(:microsecond)
    Logger.info("voxel_source_prepare_done caller=#{inspect(caller)} keys=#{length(keys)} missing=#{length(missing)} " <>
      "lookup_us=#{adopt_started - started} adopt_us=#{finished - adopt_started} total_us=#{finished - started}")
    token = make_ref()
    state = VoxelRegion.World.PageLoad.prepare(state, token, caller, keys)
    {:reply, {token, state.source, state.source_state, missing}, state}
  end

  defp call({:adopt_liquid, regions}, _, state) do
    {:reply, :ok, adopt_liquid_regions(state, regions)}
  end

  defp call({:prepare_intent, message}, from, state) do
    case intent_keys(state, message) do
      {:ok, keys} ->
        keys = Enum.uniq(keys)
        missing = Enum.filter(keys, &(needs_source?(state, &1) and not cached?(state, &1)))
        # 编辑链上的 L1+ 区域：载荷可能已缓存（供客户端），但归约读的是解码后的来源。
        undecoded = for {level, _} = key <- keys, level > 0, needs_source?(state, key), do: key
        if missing == [] and undecoded == [] do
          call({:prepared_intent, keys, message, []}, from, state)
        else
          token = make_ref()
          state = VoxelRegion.World.PageLoad.prepare(state, token, elem(from, 0), keys)
          {:reply, {:prepare, token, state.source, state.source_state, keys, missing, undecoded}, state}
        end
      error -> {:reply, error, state}
    end
  end

  defp call({:prepared_intent, keys, message, decoded}, from, state) do
    decoded = for {key, payload} <- decoded, needs_source?(state, key), into: state.decoded, do: {key, payload}
    state = adopt_liquid_regions(%{state | decoded: decoded}, Enum.uniq(for {0, region} <- keys, do: region))
    call(message, from, state)
  end

  defp call({:publish_properties, catalog}, _, state) do
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

  defp call({:publish_parameters, catalog, expected_digest}, _, state) do
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
  defp call({:thermal_experiment, experiment}, _, state) do
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

  # NPC 观察射线：一次 owner 调用读同一 seq，不写事务。
  defp call({:sight_snapshot, origin, rays}, _, state) do
    {hits, state} =
      Enum.map_reduce(rays, state, fn {direction, range}, s ->
        case Damage.trace(origin, direction, range, s, &target_at/2) do
          {:error, :no_target, s} ->
            {nil, s}

          {:ok, target, distance, s} ->
            {%{target: target, distance_m: distance, properties: property_state(s, target)}, s}
        end
      end)

    {:reply, %{seq: state.seq, hits: hits, attachments: :not_sampled}, state}
  end

  # 一次 owner 调用提供一致投影；物化缓存仍可丢弃。
  defp call({:material_snapshot, characters, cells}, from, state),
    do: call({:material_snapshot, characters, cells, :summary}, from, state)

  defp call({:material_snapshot, characters, cells, detail}, _, state) do
    {occupancy, state} = Enum.map_reduce(cells, state, fn cell, s ->
      {:ok, {material, _}, s} = cell_value(s, 0, cell)
      refined = Map.get(s.refined, cell, RefinedSlots.empty())
      slots = refined |> Enum.map(&elem(&1, 1)) |> Enum.group_by(fn {m, owner} -> {m, owner} end)
        |> Enum.map(fn {{m, {birth, occurrence} = owner}, values} ->
          # placed_by：放下这个实例的角色 cid（实例记录里的同一份溯源；作者放置或旧实例为 nil）。
          %{material: m, instance: [birth, occurrence], count: length(values),
            placed_by: Map.get(Map.get(s.instances, owner, %{}), :placed_by)}
        end)
      row = %{cell: Tuple.to_list(cell), material: material, refined: RefinedSlots.size(refined) > 0, slots: slots,
         placed_by: chunk_get(s.placed_by, cell)}
      row = if detail == :micro and RefinedSlots.size(refined) > 0 do
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

  defp call({:simulation_snapshot, characters, box}, _, state) do
    in_box = &VoxelRegion.PropertyObservation.contains?(&1, box)
    state = prepare_component_cache(state, box)
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
  defp call({:liquid_experiment, edits}, _, state) do
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

  defp call({:author_regions, regions}, _, state) do
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

  defp call(:magic_range, _, state), do: {:reply, state.magic && state.magic.range_m, state}
  defp call(:magic_digest, _, state), do: {:reply, state.magic && state.magic.digest, state}

  defp call({:caster_state, cid}, _, state) do
    reply = if state.magic, do: {:ok, caster_view(state, cid, @no_quote, 0.0, 0.0)}, else: {:error, :magic_unavailable}
    {:reply, reply, state}
  end

  defp call({:send_caster_state, cid, request_id, recipient}, from, state) do
    {:reply, result, state} = call({:caster_state, cid}, from, state)
    case result do
      {:ok, caster} -> publish_caster_state(recipient, request_id, caster)
      {:error, _} -> :ok
    end
    {:reply, result, state}
  end

  defp call({:spell_intent, actor, request}, from, state) do
    case current_actor(actor) do
      {:ok, current} -> prepare_spell(state, from, Map.put(current, :action_key, {actor.identity, request.client_intent_seq}), request)
      error -> {:reply, error, state}
    end
  end

  defp call({:tool_range, id}, _, state), do: {:reply, tool_range(state, id), state}

  defp call({:tool_definition, id}, _, state),
    do: {:reply, Map.fetch(state.properties.tools, id), state}

  defp call({:body_tool, actor, request, distance}, _, state) do
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

  defp call({:material_balances, cid}, _, state),
    do: {:reply, Enum.map(state.production_materials, &balance_state(state, cid, &1)), state}

  defp call({:material_supply, cid, supply_id, quantities}, _, state) do
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

  defp call({:gm_prepare, key, args}, _from, state), do: {:reply, VoxelRegion.World.Gm.prepare_move(state, key, args), state}

  defp call({:gm, key, :move_instance, args, geometry} = message, from, state),
    do: VoxelRegion.World.Gm.run(state, key, :move_instance, args, geometry) |> missing_pages(message, from)

  defp call({:gm, key, op, args} = message, from, state),
    do: VoxelRegion.World.Gm.run(state, key, op, args) |> missing_pages(message, from)

  defp call({:parcel_export, box}, _, state) do
    {result, state} = VoxelRegion.World.Parcel.export(state, box)
    {:reply, result, state}
  end

  defp call({:parcel_prepare, key}, _, state), do: {:reply, VoxelRegion.World.Parcel.preparation(state, key), state}

  defp call({:parcel_install, key, parcel, delta, definitions}, _, state),
    do: VoxelRegion.World.Parcel.install(state, key, parcel, delta, definitions)

  defp call({:beacon_install, key, record}, _, state),
    do: VoxelRegion.World.Beacons.install(state, key, record)

  defp call({:beacon_directory, cid}, _, state),
    do: {:reply, VoxelRegion.World.Beacons.directory(state, cid), state}

  defp call({:liquid_fill, cid, key, material, seed, level_y, max_cells} = message, from, state) do
    case Map.fetch(state.material_supplies, {cid, {:liquid_fill, key}}) do
      {:ok, receipt} -> {:reply, {:ok, receipt}, state}
      :error ->
        case liquid_fill_commit(state, cid, key, material, seed, level_y, max_cells) do
          {:ok, receipt, next} -> {:reply, {:ok, receipt}, next}
          {:error, reason} -> {:reply, {:error, reason}, state} |> missing_pages(message, from)
        end
    end
  end

  defp call({:production_intent, actor, request} = message, from, state) do
    with {:ok, current} <- current_actor(actor), true <- state.production_materials != [],
         :ready <- posed(state, message, from, {:production_intent, current, request}) do
      build_target(state, current, request) |> missing_pages(message, from)
    else
      {:deferred, _} = deferred -> deferred
      false -> {:reply, {:error, :production_unavailable}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp call({:attachment_intent, actor, request} = message, from, state) do
    with {:ok, current} <- current_actor(actor), true <- state.properties != nil,
         :ready <- posed(state, message, from, {:attachment_intent, current, request}) do
      attachment_target(state, current, request) |> missing_pages(message, from)
    else
      {:deferred, _} = deferred -> deferred
      false -> {:reply, {:error, :production_unavailable}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp call({:tool_intent, actor, request} = message, from, state) do
    started = System.monotonic_time(:microsecond)
    before = state
    tool = Map.fetch!(state.properties.tools, request.tool_id)

    result =
      case current_actor(actor) do
        {:error, reason} ->
          {:reply, {:error, reason}, before}

        {:ok, actor} ->
          refreshed = System.monotonic_time(:microsecond)

          # 刷新后的姿态决定射线与作用格（评审 A2）：按最终姿态复核闭包，缺页即挂起原消息（装齐重放时再刷新、再复核）。
          case posed(state, message, from, {:tool_intent, actor, request}) do
            {:deferred, _} = deferred -> deferred
            :ready -> tool_owner(before, state, actor, request, tool, started, refreshed)
          end
      end

    Logger.info(
      "voxel_tool_owner_done request_id=#{request.request_id} node=#{node()} elapsed_us=#{System.monotonic_time(:microsecond) - started}"
    )

    result
  end

  defp tool_owner(before, state, actor, request, tool, started, refreshed) do
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

          # 受保护区域许可：认领工具自身的规则在其适配里裁决；信标调谐不改世界，不受区域限制。
          tool["action"] not in ["protection.claim", "beacon.use"] and
              not Protection.permitted?(state.protection, {:character, actor.cid}, target_cells(state, target)) ->
            {:reply, {:error, :protected_region}, state}

          true ->
            attack_target(before, state, actor, request, target, tool)
        end
    end
  end

  # 裁决用的最终快照（刷新后的姿态等）的闭包复核：全部驻留即 `:ready`，否则挂起原消息装页，装齐重放（父稿 P4 接纳复核）。
  defp posed(%{resident: :all}, _message, _from, _final), do: :ready

  defp posed(state, message, from, final) do
    case VoxelRegion.World.PageLoad.missing_keys(state, VoxelRegion.World.Closure.needs(state, final)) do
      [] -> :ready
      keys -> defer_input(state, {:call, message, from}, keys)
    end
  end

  # 裁决中途发现缺页（动态洪泛伸进冷页）：挂起原消息装页、装齐后从头重新裁决，不当空气继续（父稿 P4）。
  defp missing_pages({:reply, {:error, {:pages_missing, keys}}, state}, message, from),
    do: defer_input(state, {:call, message, from}, Enum.uniq(VoxelRegion.World.Pages.expand(keys)))

  defp missing_pages(reply, _message, _from), do: reply

  defp call({:publish_prefabs, catalog}, _from, state) do
    {:reply, :ok, %{state | prefabs: Map.merge(state.prefabs, catalog)}}
  end

  defp call(:prefab_catalog, _, state), do: {:reply, VoxelRegion.Prefab.Catalog.public(state.prefabs), state}

  defp call({:prefab_request, operation}, from, state) do
    {:input, context, _} = state.input_current
    VoxelRegion.World.Definitions.start(state, from, context.request_ref, operation)
  end
  defp call({:prefab_inputs, token, roots}, {pid, _}, state) do
    {reply, state} = VoxelRegion.World.Definitions.inputs(state, token, pid, roots)
    {:reply, reply, state}
  end
  defp call({:prefab_loaded, token, id, bytes}, {pid, _}, state) do
    {reply, state} = VoxelRegion.World.Definitions.loaded(state, token, pid, id, bytes)
    {:reply, reply, state}
  end
  defp call({:prefab_known, token, ids}, {pid, _}, state),
    do: {:reply, VoxelRegion.World.Definitions.known(state, token, pid, ids), state}

  defp call(:published_prefab_metadata, _, state),
    do: {:reply, state.published, state}
  defp call(:material_catalog, _, state), do: {:reply, state.properties, state}

  defp call({:publish_prefab, actor, {id, bytes, geometry}, name}, _, state) do
    with {:ok, actor} <- current_actor(actor),
         {:ok, cache} <- Cache.put(state.cache, {:prefab, id}, bytes, id),
         {:ok, published} <- persist_prefab(state, actor.cid, name, id, bytes) do
      descriptor = VoxelRegion.Prefab.Catalog.descriptor(id,
        Path.join(state.prefab_dir, Base.encode16(id, case: :lower) <> ".vxpd"), byte_size(bytes), geometry)
      {:reply, {:ok, id},
       %{state | prefabs: Map.put(state.prefabs, id, descriptor), published: published, cache: cache}}
    else
      {:error, reason, _cache} -> {:reply, {:error, {:definition_cache, reason}}, state}
      error -> {:reply, error, state}
    end
  end

  defp call({:instance_cells, id}, _from, state) do
    cells = owner_cells(state, id)
    {:reply, if(cells == [], do: {:error, :instance_not_found}, else: {:ok, cells}), state}
  end

  defp call({:replacement_cells, target, geometry}, _from, state) do
    result =
      with {:ok, instance} <- fetch_instance(state, target),
           {:ok, _cells, macros} <-
             definition_cells(geometry, instance.anchor, instance.orientation) do
        {:ok, Enum.uniq(owner_cells(state, target) ++ macros)}
      end

    {:reply, result, state}
  end

  defp call({:place_prefab, _id, anchor, orientation, geometry}, _from, state) do
    place_tree(state, state, geometry, anchor, orientation, {0, 0}, 0, [])
  end

  defp call({:prefab_intent, actor, kind, request, geometry} = message, from, state) do
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
            if Protection.permitted?(state.protection, {:character, actor.cid}, prefab_intent_cells(state, kind, request, geometry)),
              do: player_prefab(state, actor, kind, request, geometry),
              else: {:reply, {:error, :protected_region}, state}
          if match?({:error, {:pages_missing, _}}, reply) do
            missing_pages({:reply, reply, next}, message, from)
          else
            unless previous != nil, do: Process.monitor(actor.gate)

            next = %{
              next
              | build_sessions:
                  Map.put(next.build_sessions, actor.gate, %{request: request, result: reply})
            }

            {:reply, reply, next}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp call({:remove_prefab, id}, _from, state) do
    ids = subtree_ids(state, id)

    case subtree_cells(state, ids) do
      [] -> {:reply, {:error, :instance_not_found}, state}
      cells -> prefab_reply(state, clear_subtree(state, ids, cells), cells)
    end
  end

  defp call({:replace_prefab, target, definition}, _from, state) do
    with {:ok, instance} <- fetch_instance(state, target) do
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

  defp call(:stats, _from, state) do
    stats =
      Cache.stats(state.cache)
      |> Map.merge(VoxelRegion.World.PageCut.backlog(state))
      |> Map.merge(%{
        scope: %{canonical_data: if(state.resident == :all, do: "loaded_persistent_state", else: "resident_pages"),
          cache: "process_local", runtime: "world", disk: "not_counted"},
        simulation_io: VoxelRegion.World.PageLoad.observe(state),
        residency: Residency.observe(state),
        simulation_progress: %{thermal: Thermal.progress(state), liquid: VoxelRegion.World.Liquids.progress(state),
          projectiles: VoxelRegion.World.Projectiles.progress(state)},
        entries: Cache.stats(state.cache).namespaces.payload.entries,
        shared_cache: Cache.stats(state.cache),
        prefab_residency: %{definitions: map_size(state.prefabs), preparing: map_size(state.prefab_requests),
          source_inflight_bytes: state.prefab_source_bytes, cache: Cache.stats(state.cache).namespaces.prefab},
        retained_transactions: map_size(state.entries),
        circuit_component_limit: state.circuit_component_limit,
        checkpoint_scheduled: state.page_store.timer != nil or state.page_store.cut != nil or state.page_store.wanted,
        published_seq: state.page_store.published,
        dirty_units: MapSet.size(state.page_dirty),
        checkpoints: state.checkpoints,
        resident_pages: resident_count(state),
        page_loads: map_size(state.page_load.tasks),
        page_waiters: map_size(state.page_load.callers),
        lru_bytes: Cache.stats(state.cache).namespaces.payload.value_bytes,
        resident_bytes: 0,
        cache_limit: Cache.stats(state.cache).limit_bytes,
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

  defp call({:serve_item, client_version, item}, _from, state) do
    started = System.monotonic_time(:microsecond)

    case serve_item(state, client_version, item) do
      {:error, reason, _state} ->
        {:reply, {:error, reason}, state}

      # 浏览请求只保留最终载荷缓存，期间解码的源数据随本区域释放。
      {reply, served} ->
        Logger.info(
          "voxel_serve_item level=#{item.level} region=#{inspect(item.region)} reply=#{elem(reply, 0)} " <>
            "hit=#{cached?(state, {item.level, item.region})} us=#{System.monotonic_time(:microsecond) - started}"
        )

        {:reply, {:ok, reply}, %{served | decoded: state.decoded}}
    end
  end

  defp call({:apply_edit, principal, coord, material}, from, state) do
    result = with :ok <- Access.authorize_cells(principal, state.protection, [coord], :raw_edit),
      {:ok, state} <- raw_liquid_edit(state, [{coord, material}]),
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

  # 游标早于已发布前缀：其后的历史已退休，显式拒绝，调用方改走 `canonical_snapshot_and_subscribe`（m2a §6.3，评审 R6）。
  defp call({:subscribe, _pid, have_seq, _box, _min_level}, _from, state) when state.page_store.published != nil and have_seq < state.page_store.published,
    do: {:reply, {:error, :cursor_expired}, state}

  defp call({:subscribe, pid, have_seq, box, min_level}, _from, state) do
    unless Map.has_key?(state.subs, pid), do: Process.monitor(pid)
    filter = {box, min_level}

    state.entries
    |> Enum.filter(fn {seq, _entry} -> seq > have_seq end)
    |> Enum.sort_by(fn {seq, _} -> seq end)
    |> Enum.each(fn {_, entry} -> send_filtered(pid, entry, filter) end)

    {:reply, :ok, %{state | subs: Map.put(state.subs, pid, filter)}}
  end

  # 供测试与诊断读历史：纯属性事务与检查点在内存只留投影字段，正文从持久日志补回。
  defp call({:entries_after, seq}, _from, state) when state.page_store.published != nil and seq < state.page_store.published,
    do: {:reply, {:error, :cursor_expired}, state}

  defp call({:entries_after, seq}, _from, %{log: {backend, handle}} = state) do
    retained = state.entries |> Enum.filter(fn {s, _} -> s > seq end) |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

    bodies =
      if Enum.any?(retained, &projection?/1),
        do: Map.new(for(txn <- backend.replay(handle), txn.seq > seq, do: {txn.seq, txn})),
        else: %{}

    {:reply, Enum.map(retained, &if(projection?(&1), do: Map.fetch!(bodies, &1.seq), else: &1)), state}
  end

  # 同回合冻结输入并登记订阅；编码与属性汇总均由同一个发送进程完成，后续增量排在快照标记之后。
  defp call({:canonical_snapshot, box, pid, request, include_chunks, token}, from, state) do
    state = VoxelRegion.World.PageLoad.release_preparation(state, token, elem(from, 0))
    call({:canonical_snapshot, box, pid, request, include_chunks}, from, state)
  end

  defp call({:canonical_snapshot, box, pid, request, include_chunks}, from, state) do
    started = System.monotonic_time(:microsecond)

    Logger.info(
      "voxel_window_stage stage=world_start request=#{inspect(request)} pid=#{inspect(self())} at_us=#{System.system_time(:microsecond)}"
    )

    unless Map.has_key?(state.canonical_subs, pid), do: Process.monitor(pid)
    feed = Map.get_lazy(state.canonical_feeds, pid, fn -> VoxelRegion.CanonicalFeed.start(pid, self()) end)
    token = make_ref()
    job = %{subscriber: pid, feed: feed, from: from, seq: state.seq, properties: state.properties, page_generation: state.page_generation,
      cursor: VoxelRegion.World.WindowSnapshot.freeze(state, box)}
    send(feed, {:snapshot, token, request, box, include_chunks, liquid_capacity(state)})

    Logger.info(
      "voxel_window_stage stage=world_send request=#{inspect(request)} pid=#{inspect(self())} at_us=#{System.system_time(:microsecond)} elapsed_us=#{System.monotonic_time(:microsecond) - started}"
    )

    {:noreply, %{state | canonical_subs: Map.put(state.canonical_subs, pid, box),
      canonical_feeds: Map.put(state.canonical_feeds, pid, feed),
      canonical_snapshots: Map.put(state.canonical_snapshots, token, job)}}
  end

  defp call({:window_input, token}, {feed, _}, state) do
    # 订阅者的 DOWN 可以先于发送进程已经排入的拉取消息；取消后不能再解引用已释放的输入。
    case Map.fetch(state.canonical_snapshots, token) do
      :error -> {:reply, {:error, :canonical_cancelled}, state}
      {:ok, %{feed: ^feed, cursor: cursor} = job} ->
        case VoxelRegion.World.WindowSnapshot.next(cursor) do
          :done ->
            {:reply, :done, put_in(state.canonical_snapshots[token], %{job | cursor: nil})}
          {items, cursor} ->
            {:reply, items, put_in(state.canonical_snapshots[token], %{job | cursor: cursor})}
        end
    end
  end

  defp call({:window_finished, token, result, payloads}, {feed, _}, state) do
    case Map.pop(state.canonical_snapshots, token) do
      {nil, _} -> {:reply, :ok, state}
      {%{feed: ^feed} = job, jobs} ->
        # 旧观察切点只用于发送，不能把缓存写回后来已变化的世界。
        state = if result == :ok and state.seq == job.seq do
          Enum.reduce(payloads, state, fn {key, {bytes, header}}, acc ->
            if Map.get(job.page_generation, key, 0) == Map.get(acc.page_generation, key, 0),
              do: cache_put(acc, key, bytes, header), else: acc
          end)
        else
          state
        end
        state = if result == :ok, do: state, else: %{state |
          canonical_subs: Map.delete(state.canonical_subs, job.subscriber),
          canonical_feeds: Map.delete(state.canonical_feeds, job.subscriber)}
        GenServer.reply(job.from, result)
        {:reply, :ok, %{state | canonical_snapshots: jobs}}
    end
  end

  defp call({:window_geometry, token, rows}, {feed, _}, state) do
    state = case Map.get(state.canonical_snapshots, token) do
      %{feed: ^feed, seq: seq, properties: properties, page_generation: generations}
          when seq == state.seq and properties == state.properties and generations == state.page_generation ->
        VoxelRegion.World.Observation.remember_component_geometry(state, rows)
      _ -> state
    end
    {:reply, :ok, state}
  end

  defp call({:replica_snapshot, box, pid}, _from, state) do
    case capture_canonical_snapshot(state, box) do
      {:ok, snapshot, state} ->
        unless Map.has_key?(state.replica_subs, pid), do: Process.monitor(pid)
        snapshot = %{snapshot | chunks: CollisionSource.snapshot_chunks(snapshot.regions, liquid_capacity(state))}
        {:reply, {:ok, snapshot}, %{state | replica_subs: Map.put(state.replica_subs, pid, box)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp call({:apply_edits, principal, edits}, from, state) do
    result = with :ok <- Access.authorize_cells(principal, state.protection, Enum.map(edits, &elem(&1, 0)), :raw_edit),
      {:ok, read} <- raw_liquid_edit(state, edits), do: apply_batch(read, edits)
    case result do
      {:ok, next_state} ->
        if next_state.seq == state.seq, do: acknowledge_noop(next_state, from)
        {:reply, {:ok, next_state.seq}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp call(:compact, from, state) do
    {:noreply, VoxelRegion.World.PageCut.compact(state, from)}
  end

  # Player / Scene 发来、要读页的异步消息（M2b）：过读取闭包的闸，缺页即挂起、装完重放。
  # 施法授权带最终姿态，结算重新求射线：同样过闸（评审 A2）。
  @paged_infos [:prepare_cast, :quote_cast, :authorize_cast, :prepare_beacon, :commit_beacon, :body_contact, :body_death]

  @impl true
  def handle_info({:player_spell_request, request, from, message}, state) do
    input = Admission.async_input(message, from, Clock.monotonic(state), request)
    gate_input(input, state, 0) |> continue_callback()
  end

  def handle_info({:DOWN, ref, :process, _pid, reason} = message, state) do
    result = if VoxelRegion.World.PageLoad.caller?(state, ref) do
      {:noreply, cancel_input(state, ref)}
    else
      case VoxelRegion.World.PageLoad.finish(state, ref, reason) do
        :unknown -> case VoxelRegion.World.Definitions.down(state, ref, reason) do
          {:handled, next} -> {:noreply, next}
          :unknown -> info(message, state)
        end
        {entries, attempt, state} -> {:noreply, Enum.reduce(entries, state, &redo(&1, attempt, reason, &2))}
      end
    end
    result = case result do
      {:reply, reply, state} -> {:reply, reply, Residency.request(state)}
      {:noreply, state} -> {:noreply, Residency.request(state)}
    end
    continue_callback(result)
  end

  def handle_info(message, state) do
    tag = if is_tuple(message), do: elem(message, 0), else: message
    state = if tag in [:thermal_tick, :thermal_step, :thermal_commit, :liquid_tick, :liquid_commit, :projectile_tick] or
      projectile_result?(message, state), do: Residency.request(state), else: state
    gated_info(message, state, 0) |> continue_callback()
  end

  defp gated_info(message, state, attempt) do
    if physical_input?(message) or VoxelRegion.World.PageLoad.order_key(message) != nil or
         (is_tuple(message) and elem(message, 0) in @paged_infos) or projectile_result?(message, state),
      do: gate_input(Admission.input({:info, message}, Clock.monotonic(state)), state, attempt),
      else: info(message, state)
  end

  defp info({:prefab_ready, token, result}, state),
    do: {:noreply, VoxelRegion.World.Definitions.finish(state, token, result)}

  # 投射物采样结果（`Projectiles.poll/1` 的任务回复）要按飞行段读世界：同样过闸。
  defp projectile_result?({ref, _results}, %{projectile_task: %Task{ref: ref}}), do: true
  defp projectile_result?(_message, _state), do: false

  # 装页任务结束：正常即重放挂起的消息（重新过闸），异常即对挂起的调用显式回错（不当空气）；模拟的装页唤醒调度。
  # 模拟装页完整结束才续原步；失败保留due/run/paused并显式停止，依赖修复后的公共retry只开启一次新attempt。
  defp redo(:wake, _attempt, reason, state) do
    if reason == :normal do
      state = put_in(state.page_load.paused, nil)
      if state.thermal_run, do: send(self(), {:thermal_step, state.thermal_run.ref})
      state |> Thermal.wake() |> schedule_liquid() |> VoxelRegion.World.Projectiles.wake()
    else
      state |> halt_simulation_io() |> reject_waiting_simulation_inputs(reason)
    end
  end

  defp redo({:input, _context, _entry} = input, attempt, :normal, state), do: replay(input, state, attempt + 1)
  defp redo({:input, _context, {:info, {:body_death, cid, feet}}} = input, _attempt, reason, state) do
    # 死亡掉落是已确认后果；原重试继续同一输入身份，同body后继不能越过尚未落地的前驱。
    Logger.error("voxel_death_drop_retry cid=#{cid} feet=#{inspect(feet)} error=#{inspect(reason)} retry_ms=1000")
    Process.send_after(self(), {:retry_death_drop, Admission.preparing(input)}, 1_000)
    state
  end
  defp redo({:input, _context, entry} = input, _attempt, reason, state) do
    result = case entry do
      {:call, _message, _from} -> {:reply, {:error, {:page_load_failed, reason}}, state}
      {:info, message} -> {:noreply, page_failed(message, {:page_load_failed, reason}, state)}
    end
    deliver_result(input, finish_input(input, result))
  end
  defp redo(entry, attempt, reason, state), do: redo(Admission.input(entry, Clock.monotonic(state)), attempt, reason, state)

  defp page_failed({:prepare_cast, key, actor, _request, from}, error, state) do
    send(actor.player, {:cast_failed, key})
    GenServer.reply(from, {:error, error})
    state
  end

  defp page_failed({:quote_cast, _actor, _request, from}, error, state) do
    GenServer.reply(from, {:error, error})
    state
  end

  # 授权时待施放已建立：按取消收尾（不扣能，调用方收到错误）。
  defp page_failed({:authorize_cast, key, _actor, _request}, error, state), do: cancel_pending_cast(state, key, error)

  defp page_failed({:prepare_beacon, key, actor, _request}, error, state) do
    send(actor.player, {:beacon_prepared, key, {:error, error}})
    state
  end

  defp page_failed({:commit_beacon, key, actor, _request}, error, state) do
    send(actor.player, {:beacon_committed, key, {:error, error}})
    state
  end

  # 投射物采样：放掉这次采样（与年龄不符的旧采样同样处理），任务位清空、下一拍重新采样，不让死任务封住投射物。
  defp page_failed({ref, _results}, _error, %{projectile_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    VoxelRegion.World.Projectiles.wake(%{state | projectile_task: nil})
  end

  # 身体接触每秒续报，下一次报告即重来；其余消息不带业务回复。
  defp page_failed(_message, _error, state), do: state

  defp replay(entry, state, attempt \\ 0)
  defp replay({:input, _context, _entry} = input, state, attempt),
    do: deliver_result(input, gate_input(input, state, attempt))
  defp replay(entry, state, attempt), do: replay(Admission.input(entry, Clock.monotonic(state)), state, attempt)

  # 同上：热提交自己的节拍与步消息之外，其他消息都先写回原生热域的变化。
  defp info(message, %{page_load: %{sim: %{status: :failed}}} = state)
       when message in [:thermal_tick, :thermal_commit, :liquid_commit, :projectile_tick] or
         (is_tuple(message) and elem(message, 0) in [:thermal_tick, :thermal_step, :liquid_tick]),
       do: {:noreply, halt_simulation_io(state)}

  defp info(message, %{thermal_work: %{domain: %{pending: true}}} = state)
      when message != :thermal_tick and not (is_tuple(message) and elem(message, 0) in [:thermal_step, :thermal_tick | @unflushed]),
      do: info(message, Thermal.flush(state, if(is_tuple(message), do: elem(message, 0), else: message)))

  defp info({:timeout, ref, :page_cut}, %{page_store: %{timer: ref}} = state),
    do: {:noreply, VoxelRegion.World.PageCut.want(put_in(state.page_store.timer, nil))}

  defp info({:timeout, _stale, :page_cut}, state), do: {:noreply, state}

  defp info({:timeout, ref, :replica_retire}, %{page_store: %{replica_timer: ref}} = state),
    do: {:noreply, VoxelRegion.World.PageCut.retire_replicas(put_in(state.page_store.replica_timer, nil))}

  # 积压中上限（m2a §5.3）：不开始新的投射物 / 液体 / 热步进（进行中的已走到提交边界）；`PageCut.assess/1` 回落时恢复调度。
  defp info(:projectile_tick, state) when state.page_store.level in [:mid, :hard],
    do: {:noreply, VoxelRegion.World.PageCut.pause(%{state | projectile_timer: nil})}

  defp info(:thermal_tick, %{thermal_run: nil} = state) when state.page_store.level in [:mid, :hard],
    do: {:noreply, state |> Thermal.fired() |> VoxelRegion.World.PageCut.pause()}

  # 积压硬上限：新施法、新信标读条都会产生新提交，在裁决前拒绝（同 `@commit_calls`）。死亡掉落不在此列：它是已确认死亡的后果、
  # 不是新的玩家意图，频率有限，被拒即没有重试通道（物品永久丢失），硬上限下照常提交（m2a §5.3）。
  defp info({:prepare_cast, key, actor, _request, from}, state) when state.page_store.level == :hard do
    send(actor.player, {:cast_failed, key})
    GenServer.reply(from, {:error, :persist_backlog})
    {:noreply, state}
  end

  defp info({:prepare_beacon, key, actor, _request}, state) when state.page_store.level == :hard do
    send(actor.player, {:beacon_prepared, key, {:error, :persist_backlog}})
    {:noreply, state}
  end

  defp info(message, state)
      when message == :page_pump or (is_tuple(message) and elem(message, 0) in [:page_begun, :page_ack, :page_published, :page_failed]),
      do: {:noreply, VoxelRegion.World.PageCut.handle(state, message)}


  defp info(:projectile_tick, state) do
    state = drain_thermal(state)
    {:noreply, VoxelRegion.World.Projectiles.poll(%{state | projectile_timer: nil})}
  end

  defp info({ref, results}, %{projectile_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = drain_thermal(state)
    {:noreply, VoxelRegion.World.Projectiles.accept(%{state | projectile_task: nil}, results)}
  end

  defp info(:liquid_commit, state), do: liquid_tick(state, nil)
  defp info({:liquid_tick, due}, %{liquid_due: due} = state), do: {:noreply, drive_inputs(state)}
  defp info({:liquid_tick, _stale}, state), do: {:noreply, state}

  # 魔法增量 4：Scene 的 Player 每秒报一次身体（脚位、身高、半径、皮肤温度与热容、体表面积、局部接触组织块的温度 / 热容 /
  # 与皮肤的导热）；本次算出的接触边留到下一次热提交使用。无接触且组织块与皮肤已在容差内平衡即注销。无热环境的世界忽略。
  defp info({:body_contact, cid, pid, body}, %{thermal: thermal} = state) when thermal != nil do
    {contacts, immersed, sole, state} = Thermal.body_contacts(state, body)

    bodies =
      if contacts == [] and abs(body.tissue_k - body.skin_k) <= thermal.config["tolerance_kelvin"] do
        Thermal.detach_body(state.bodies, cid)
      else
        {bodies, monitor} = case Map.get(state.bodies, cid) do
          %{pid: ^pid, monitor: monitor} -> {state.bodies, monitor}
          _ -> {Thermal.detach_body(state.bodies, cid), Process.monitor(pid)}
        end
        {:input, context, _} = state.input_current
        Map.put(bodies, cid, Map.merge(body, %{pid: pid, monitor: monitor, contacts: contacts,
          immersed: immersed, sole: sole, at: context.arrival_ms}))
      end

    {:noreply, Thermal.wake(%{state | bodies: bodies})}
  end

  defp info({:body_contact, _cid, _pid, _body}, state), do: {:noreply, state}

  # 全局系统功能：Scene seal/退出等待此 fence，先吸收旧 owner 已收到的热量，再交接身体。
  # 热内核每步同步回传；后续步从当前 bodies 取节点。迟到的旧 PID 不得摘掉新 Scene 的接触。
  defp info({:body_detach, cid, pid, ref}, state) do
    bodies = case Map.get(state.bodies, cid) do
      %{pid: ^pid} -> Thermal.detach_body(state.bodies, cid)
      _ -> state.bodies
    end
    send(pid, {:body_detached, ref})
    {:noreply, %{state | bodies: bodies}}
  end

  # 身体系数变化沿既有 0x83 推送本人；request 0 只刷新状态，报价与支出仍属于各自请求。
  # 会话身份交给 Gate 的既有出站边界拒旧；seal/stop 的 body_detach fence 已排在旧 owner 的消息之后。
  defp info({:body_coherence, cid, factor, gate, identity}, state) do
    value = {identity, factor}
    changed = Map.get(state.caster_coherence, cid) != value
    state = %{state | caster_coherence: Map.put(state.caster_coherence, cid, value)}

    if changed and state.magic != nil do
      publish_caster_state({gate, identity}, 0, caster_view(state, cid, @no_quote, 0.0, 0.0))
    end

    {:noreply, state}
  end

  # 身体闭环 H2：角色死亡（Scene 送来脚位），按 `death_drop/3` 裁决掉落并记账。
  defp info({:body_death, cid, feet}, state) do
    {result, state} = death_drop(state, cid, feet)
    Logger.info("voxel_death_drop " <> Enum.map_join(Map.put(result, :cid, cid), " ", fn {k, v} -> "#{k}=#{inspect(v)}" end))
    {:noreply, schedule_liquid(state)}
  end

  # 全局系统：Player 是唯一前摇/授权 owner，World 仅保存待支付的领域负载。
  defp info({:quote_cast, actor, request, from}, state) do
    {:reply, result, next} = prepare_spell(state, from, actor, request)
    publish_cast_reply(actor, request, result)
    GenServer.reply(from, result)
    {:noreply, next}
  end
  defp info({:prepare_cast, key, actor, request, from}, state) do
    case prepare_spell(state, from, Map.put(actor, :action_key, key), request) do
      {:noreply, next} -> {:noreply, next}
      {:reply, result, next} ->
        send(actor.player, {:cast_failed, key})
        GenServer.reply(from, result)
        {:noreply, next}
    end
  end
  defp info({:authorize_cast, key, actor, request}, state) do
    case authorized_pending(state, key, actor) do
      nil -> {:noreply, state}
      pending ->
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
    end
  end
  defp info({:cancel_cast, key, reason}, state), do: {:noreply, cancel_pending_cast(state, key, reason)}

  # 传送信标：Player 是读条 owner；World 只在开始与结束各校验一次，结果异步回给 Player（不回调 Player，避免互等）。
  defp info({:prepare_beacon, key, actor, request}, state) do
    {result, state} = VoxelRegion.World.Beacons.prepare(state, actor, request)
    send(actor.player, {:beacon_prepared, key, result})
    {:noreply, state}
  end

  defp info({:commit_beacon, key, actor, request}, state) do
    {result, state} = VoxelRegion.World.Beacons.commit_travel(state, actor, request)
    send(actor.player, {:beacon_committed, key, result})
    {:noreply, state}
  end

  # 定时提交按内核步分成多条消息推进，步间先处理已排队的工具、建造和查询调用；整段仍作为一笔热事务提交。
  # 无可推进的状态时休眠：不再排下一拍，直到事务或身体接触唤醒（R8-05）。
  defp info({:thermal_tick, due}, %{thermal_due: due} = state),
    do: {:noreply, drive_inputs(Thermal.fired(state))}
  defp info({:thermal_tick, _stale}, state), do: {:noreply, state}

  defp info(:thermal_tick, %{thermal_run: nil} = state) do
    # 热域读种子格的邻格与视线伙伴（M2b）：有未驻留页时本拍不开提交，装完由装页任务唤醒（父稿 P4“该步暂停”）。
    case VoxelRegion.World.PageLoad.request(state, &Thermal.seed_keys/1) do
      {:ready, state} ->
        state = state |> Thermal.fired() |> Thermal.begin(state.thermal_due)
        {:noreply, if(state.thermal_run, do: step_thermal(state), else: Thermal.rest(state))}

      {:loading, state} ->
        {:noreply, Thermal.fired(state)}
      {:failed, _failure, state} ->
        {:noreply, halt_simulation_io(state)}
    end
  end

  # 进行中的提交完成时才排下一次；此时到期的节拍不另起提交。
  defp info(:thermal_tick, state), do: {:noreply, Thermal.fired(state)}

  defp info({:thermal_step, ref}, %{thermal_run: %{ref: ref}} = state) do
    # 同 drain_thermal：每步前查驻留，缺页即暂停在步前（运行保持进行中），装齐后由 `:wake` 续步。
    case VoxelRegion.World.PageLoad.request(state, &Thermal.seed_keys/1) do
      {:ready, state} -> {:noreply, step_thermal(state)}
      {:loading, state} -> {:noreply, put_in(state.page_load.paused, ref)}
      {:failed, _failure, state} -> {:noreply, halt_simulation_io(state)}
    end
  end
  defp info({:thermal_step, _ref}, state), do: {:noreply, state}

  # 显式强制热步与 `:liquid_commit` 同为经 PageLoad／Admission 挂闸的物理输入：步前读取集缺页时原输入挂起、装齐后重放，
  # 不另起第二条等待路径。接纳后先完成进行中的定时提交，不把两段模拟混入同一事务；该提交途中又遇装页暂停时，
  # 本输入挂到同一模拟装页上重放，装齐后续完原提交再开始本次强制步，不静默吞掉。本次强制步自身开始后遇装页暂停，
  # 由 `:wake` 续完同一步。
  defp info(:thermal_commit, state) do
    state = drain_thermal(state)

    cond do
      VoxelRegion.World.PageCut.at_least?(state, :mid) ->
        {:noreply, state |> VoxelRegion.World.PageCut.pause() |> VoxelRegion.World.PageCut.maybe_open() |> Thermal.wake()}
      state.thermal_run != nil and match?(%{status: :loading}, state.page_load.sim) ->
        {:input, _context, entry} = state.input_current
        {keys, exact, _ids} = state.page_load.sim.request
        defer_input(state, entry, Enum.uniq(VoxelRegion.World.Pages.expand(keys) ++ exact))
      true ->
        state = if state.thermal_run, do: state, else: state |> Thermal.begin() |> drain_thermal()
        {:noreply, state |> VoxelRegion.World.PageCut.maybe_open() |> Thermal.wake()}
    end
  end

  defp info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = state |> VoxelRegion.World.PageLoad.release_preparations(pid) |> Residency.request()
    {windows, changed} = VoxelRegion.World.SimulationWindows.remove(state.simulation_windows, pid)
    if changed, do: Logger.info("voxel_simulation_windows source=#{inspect(pid)} reason=down sources=#{map_size(windows)} windows=0")
    state = if changed,
      do: %{state | simulation_windows: windows},
      else: state
    # 发送进程与订阅者都由 World 监视：退出即释放冻结引用，并让尚未完成的调用显式失败。
    {abandoned, jobs} = Enum.split_with(state.canonical_snapshots, fn {_, job} -> job.subscriber == pid or job.feed == pid end)
    for {_, job} <- abandoned, do: GenServer.reply(job.from, {:error, :canonical_feed_down})
    if feed = Map.get(state.canonical_feeds, pid), do: Process.exit(feed, :shutdown)
    failed = for {subscriber, feed} <- state.canonical_feeds, feed == pid, do: subscriber
    for subscriber <- failed, do: send(subscriber, {:canonical_source_error, :canonical_feed_down})
    state = %{state | canonical_snapshots: Map.new(jobs),
      canonical_subs: Map.drop(state.canonical_subs, failed), canonical_feeds: Map.drop(state.canonical_feeds, failed)}
    state = Enum.reduce(state.pending_casts, state, fn {_, pending}, acc ->
      if pending.actor.player == pid, do: cancel_pending_cast(acc, pending.actor.action_key, :invalid_session), else: acc
    end)
    detached = for {cid, body} <- state.bodies, body.pid == pid, do: cid
    state = %{
         state
         | subs: Map.delete(state.subs, pid),
           canonical_subs: Map.delete(state.canonical_subs, pid),
           canonical_feeds: Map.delete(state.canonical_feeds, pid),
           replica_subs: Map.delete(state.replica_subs, pid),
           tool_sessions: Map.delete(state.tool_sessions, pid),
           spell_sessions: Map.delete(state.spell_sessions, pid),
           claim_corners: Map.delete(state.claim_corners, pid),
           build_sessions: Map.delete(state.build_sessions, pid)
       }
    # 会话/订阅立即失效；已成立身体接触的物理摘离仍按同body的ready边界生效。
    state = Enum.reduce(detached, state, fn cid, state ->
      replay(Admission.input({:info, {:body_detach, cid, pid, make_ref()}}, Clock.monotonic(state)), state)
    end)
    {:noreply, state}
  end

  defp info({:simulation_windows, source, boxes, request}, state) do
    {reply, state} = accept_simulation_windows(state, source, boxes)
    send(source, {:simulation_windows_result, request, reply})
    {:noreply, state}
  end

  defp info(:input_continue, state), do: {:noreply, drive_inputs(%{state | input_scheduled: false})}
  defp info({:retry_death_drop, input}, state), do: {:noreply, replay(input, state, 1)}

  defp info(_msg, state), do: {:noreply, state}

  # 输入分类以实际副作用为准：prepare可能接纳来源液体；余额供给不改变当前物理输入。
  # 显式液体／热步也是到达的输入；缺页时运输原输入，不能只唤醒尚未到期的自然due。
  defp physical_input?(message) when message in [:liquid_commit, :thermal_commit], do: true
  defp physical_input?({tag, _, %{action: 0}}) when tag in [:tool_intent, :spell_intent], do: false
  defp physical_input?(message) when is_tuple(message) do
    tag = elem(message, 0)
    tag in (@commit_calls -- [:material_supply]) ++ [:prepare, :adopt_liquid, :prepare_intent, :prepared_intent,
      :body_tool, :body_contact, :body_detach, :body_death, :prepare_cast, :authorize_cast,
      :prepare_beacon, :commit_beacon] or is_reference(tag)
  end
  defp physical_input?(_), do: false

  # 上游已确认死亡后果不能因当前IO故障丢弃；保留原唯一context，不能泛化给普通新请求。
  defp confirmed_input?({:body_death, _, _}), do: true
  defp confirmed_input?(_), do: false

  defp reject_simulation_input(input, state, reason, release_order? \\ true) do
    message = Admission.message(input)
    error = {:simulation_input_failed, reason}
    Logger.error("voxel_input_failed kind=#{Admission.kind(message)} reason=#{inspect(error)}")
    result = case Admission.from(input) do
      nil -> {:noreply, page_failed(message, error, state)}
      _from -> {:reply, {:error, error}, state}
    end
    # 失败闸拒绝未排到同key头的新输入时，不能释放其前驱（尤其已确认死亡后果）的held。
    if release_order?, do: finish_input(input, result, :rejected), else: result
  end

  defp reject_waiting_simulation_inputs(state, reason) do
    {kept, rejected} = Enum.split_with(:queue.to_list(state.input_ready), &confirmed_input?(Admission.message(&1)))
    state = %{state | input_ready: :queue.from_list(kept)}
    Enum.reduce(rejected, state, fn input, state ->
      deliver_result(input, reject_simulation_input(input, state, reason))
    end)
  end

  defp halt_simulation_io(state) do
    for timer <- [state.thermal_timer, state.liquid_timer], timer != nil,
      do: Clock.cancel_timer(state, timer)
    if state.projectile_timer, do: Process.cancel_timer(state.projectile_timer)
    %{state | thermal_timer: nil, liquid_timer: nil, projectile_timer: nil}
  end

  defp continue_callback({:reply, reply, state}), do: {:reply, reply, state |> Residency.maintain() |> schedule_inputs()}
  defp continue_callback({:noreply, state}), do: {:noreply, state |> Residency.maintain() |> schedule_inputs()}

  defp ready_input(input, state) do
    {:input, previous, _} = input
    duplicate = confirmed_input?(Admission.message(input)) and
      Enum.any?(:queue.to_list(state.input_ready), fn {:input, existing, _} -> existing.id == previous.id end)
    if duplicate, do: {:noreply, state}, else: queue_ready_input(input, state)
  end

  defp queue_ready_input(input, state) do
    {:input, context, _} = input = Admission.ready(input, Clock.monotonic(state))
    Logger.info("voxel_input_ready id=#{inspect(context.id)} kind=#{Admission.kind(Admission.message(input))} round=#{context.ready_round} cutoff_ms=#{context.ready_cutoff_ms}")
    if :queue.is_empty(state.input_ready) and Admission.next_step(state, context.ready_cutoff_ms) == nil do
      run_input(input, state)
    else
      state = case Admission.from(input) do
        nil -> state
        from -> VoxelRegion.World.PageLoad.track(state, from, context.request_ref)
      end
      state = VoxelRegion.World.PageLoad.hold(state, VoxelRegion.World.PageLoad.order_key(input))
      {:noreply, %{state | input_ready: :queue.in(input, state.input_ready)} |> schedule_inputs()}
    end
  end

  defp run_input({:input, _, entry} = input, state) do
    state = %{state | input_current: input}
    result = case entry do
      {:call, message, from} ->
        if backlog_rejects?(message, state), do: {:reply, {:error, :persist_backlog}, state},
          else: call(message, from, state)
      {:info, message} -> info(message, state)
    end
    case result do
      {:deferred, next} -> {:noreply, %{next | input_current: nil}}
      result -> finish_input(input, result)
    end
  end

  defp finish_input(input, result, outcome \\ :accepted)
  defp finish_input(input, {:reply, reply, state}, outcome),
    do: {:reply, reply, complete_input(input, state, if(match?({:error, _}, reply), do: :rejected, else: outcome))}
  defp finish_input(input, {:noreply, state}, outcome), do: {:noreply, complete_input(input, state, outcome)}
  defp complete_input({:input, context, _} = input, state, outcome) do
    if context.ready_cutoff_ms != nil do
      Logger.info("voxel_input_#{outcome} id=#{inspect(context.id)} kind=#{Admission.kind(Admission.message(input))} round=#{context.ready_round} cutoff_ms=#{context.ready_cutoff_ms} seq=#{state.seq}")
    end
    state = %{state | input_current: nil}
    message = Admission.message(input)
    state = if VoxelRegion.World.PageLoad.input_dependencies(state, input) != :none or physical_input?(message) or
      VoxelRegion.World.PageLoad.order_key(message) != nil, do: Residency.request(state), else: state
    state = if from = Admission.from(input), do: VoxelRegion.World.PageLoad.accepted(state, from), else: state
    {queued, state} = VoxelRegion.World.PageLoad.release(state, VoxelRegion.World.PageLoad.order_key(input))
    Enum.reduce(queued, state, &replay/2)
  end

  defp deliver_result(input, {:reply, reply, state}) do
    GenServer.reply(Admission.from(input), reply)
    state
  end
  defp deliver_result(_input, {:noreply, state}), do: state

  defp defer_input(%{input_current: {:input, context, _}} = state, entry, keys) do
    input = {:input, %{context | ready_cutoff_ms: nil}, entry}
    {:deferred, VoxelRegion.World.PageLoad.defer(%{state | input_current: nil}, input, keys)}
  end

  defp cancel_input(state, identity) do
    {from, queued, state} = VoxelRegion.World.PageLoad.cancel(state, identity)
    state = VoxelRegion.World.Definitions.cancel(state, from)
    {removed, kept} = Enum.split_with(:queue.to_list(state.input_ready), &(from != nil and Admission.from(&1) == from))
    state = %{state | input_ready: :queue.from_list(kept)}
    {ready_queued, state} = Enum.reduce(removed, {[], state}, fn input, {all, state} ->
      {next, state} = VoxelRegion.World.PageLoad.release(state, VoxelRegion.World.PageLoad.order_key(input))
      {all ++ next, state}
    end)
    Enum.reduce(ready_queued ++ queued, state, &replay/2)
  end

  defp input_cutoff(state) do
    case :queue.peek(state.input_ready) do
      {:value, {:input, context, _}} -> context.ready_cutoff_ms
      :empty -> Clock.monotonic(state)
    end
  end

  defp schedule_inputs(%{input_scheduled: true} = state), do: state
  defp schedule_inputs(%{thermal_run: run} = state) when run != nil, do: state
  defp schedule_inputs(state) do
    step = Admission.next_step(state, input_cutoff(state))
    waiting = state.page_load.sim != nil or (step != nil and state.page_store.level in [:mid, :hard])
    if not waiting and (step != nil or not :queue.is_empty(state.input_ready)) do
      send(self(), :input_continue)
      %{state | input_scheduled: true}
    else
      state
    end
  end

  defp drive_inputs(state) do
    if failure = VoxelRegion.World.PageLoad.failure(state),
      do: state |> halt_simulation_io() |> reject_waiting_simulation_inputs(failure.reason),
      else: drive_ready_inputs(state)
  end

  defp drive_ready_inputs(state) do
    case Admission.next_step(state, input_cutoff(state)) do
      :thermal -> advance_thermal_input(state)
      :liquid ->
        {:noreply, state} = liquid_tick(state, state.liquid_due)
        state
      nil ->
        case :queue.out(state.input_ready) do
          {:empty, _} -> state
          {{:value, {:input, context, _} = input}, queue} ->
            state = %{state | input_ready: queue}
            # 追旧步可能改变闭包；只在实际接纳边界复核，重新缺页退出本轮ready。
            case VoxelRegion.World.PageLoad.gate(state, Admission.preparing(input), context.ready_round) do
              {:ready, state} -> deliver_result(input, run_input(input, state))
              {:deferred, state} -> state
            end
        end
    end
  end

  defp advance_thermal_input(state) when state.page_store.level in [:mid, :hard] and state.thermal_run == nil,
    do: state |> Thermal.fired() |> VoxelRegion.World.PageCut.pause()
  defp advance_thermal_input(state) do
    case VoxelRegion.World.PageLoad.request(state, &Thermal.seed_keys/1) do
      {:failed, _failure, state} -> halt_simulation_io(state)
      {:loading, state} ->
        state = Thermal.fired(state)
        if state.thermal_run, do: put_in(state.page_load.paused, state.thermal_run.ref), else: state
      {:ready, state} ->
        if state.thermal_run == nil do
          Logger.info("voxel_physics_step owner=thermal due_ms=#{inspect(state.thermal_due)}")
        end
        state = if state.thermal_run, do: state, else: state |> Thermal.fired() |> Thermal.begin(state.thermal_due)
        if state.thermal_run, do: step_thermal(state), else: Thermal.rest(state)
    end
  end

  defp liquid_tick(state, _due) when state.page_store.level in [:mid, :hard] do
    if state.liquid_timer, do: Clock.cancel_timer(state, state.liquid_timer)
    {:noreply, VoxelRegion.World.PageCut.pause(%{state | liquid_timer: nil})}
  end

  defp liquid_tick(state, due) do
    if state.liquid_timer, do: Clock.cancel_timer(state, state.liquid_timer)
    active = state.liquid_active

    # 步进读活动格的邻格（M2b）：有未驻留页时本步不推进，装完由装页任务唤醒调度（父稿 P4“该步暂停”）。
    case VoxelRegion.World.PageLoad.request(state, &VoxelRegion.World.Liquids.seed_keys/1) do
      {:ready, state} ->
        if due != nil, do: Logger.info("voxel_physics_step owner=liquid due_ms=#{due}")
        state = advance_liquid(%{state | liquid_active: MapSet.new()}, active) |> commit_active()
        {:noreply, VoxelRegion.World.Liquids.completed(state, due)}

      {:loading, state} ->
        {:noreply, %{state | liquid_timer: nil}}
      {:failed, _failure, state} ->
        {:noreply, halt_simulation_io(state)}
    end
  end

  defp accept_simulation_windows(state, source, boxes) do
    case VoxelRegion.World.SimulationWindows.normalize(boxes) do
      {:ok, boxes} ->
        {windows, changed} = VoxelRegion.World.SimulationWindows.put(state.simulation_windows, source, boxes)
        if changed, do: Logger.info("voxel_simulation_windows source=#{inspect(source)} reason=update sources=#{map_size(windows)} windows=#{length(boxes)}")
        next = if changed,
          do: Residency.request(%{state | simulation_windows: windows}),
          else: state
        {:ok, next}
      {:error, reason} = error ->
        Logger.warning("voxel_simulation_windows source=#{inspect(source)} reason=#{reason}")
        {error, state}
    end
  end

  defp step_thermal(state) do
    case Thermal.tick(state) do
      {:more, state} -> send(self(), {:thermal_step, state.thermal_run.ref}); state
      {:done, state, commit} -> state |> commit_thermal(commit) |> VoxelRegion.World.PageCut.maybe_open() |> Thermal.wake()
      {:needs_pages, keys, state} -> wait_thermal_pages(state, keys)
    end
  end

  # 图准备只交接同一自然段所需页，装页owner不推进模型时间。
  defp wait_thermal_pages(state, keys) do
    case VoxelRegion.World.PageLoad.request(state, keys) do
      {:loading, state} -> put_in(state.page_load.paused, state.thermal_run.ref)
      {:failed, _failure, state} -> halt_simulation_io(state)
      {:ready, state} -> send(self(), {:thermal_step, state.thermal_run.ref}); state
    end
  end

  defp drain_thermal(%{thermal_run: nil} = state), do: state

  # 每个内核步前都按当前热域查驻留（M2b，父稿 P4“有模拟资格但未驻留的页：该步暂停、请求装页、装齐后再推进”）：
  # 缺页即停在这一步之前，提交不结束、不写任何部分通量；装页任务结束后由 `:wake` 续步。
  defp drain_thermal(state) do
    case VoxelRegion.World.PageLoad.request(state, &Thermal.seed_keys/1) do
      {:failed, _failure, state} -> halt_simulation_io(state)
      {:loading, state} -> put_in(state.page_load.paused, state.thermal_run.ref)
      {:ready, state} ->
        case Thermal.tick(state) do
          {:more, state} -> drain_thermal(state)
          {:done, state, commit} -> commit_thermal(state, commit)
          {:needs_pages, keys, state} -> wait_thermal_pages(state, keys)
        end
    end
  end

  # 恢复（m2a §6.2 / §7，M2b §2.5）：有已发布前缀时只读全局行、日志后缀与活动索引，后缀涉及的页（与身份的整树）和活动页经装页入口装入，
  # 再重放后缀；前缀为 0（全新世界，库里没有可见页段）时内存即全部真值。没有前缀（未迁移或全新世界）时清掉未发布残留、
  # 按旧路径全量回放，首个切点写出全部页。
  defp restore_pages(%{log: {backend, handle}} = state) do
    alias VoxelRegion.World.{PageLoad, Pages}

    case backend.load_head(handle, Pages.activity_code()) do
      %{prefix: nil} ->
        :ok = backend.clear_unpublished(handle, nil)
        replay_log(state)

      %{prefix: 0} = head ->
        state
        |> Pages.install_globals(head.globals)
        |> replay_txns(head.txns)
        |> VoxelRegion.World.Canopy.refresh_all()
        |> put_in([:page_store, :published], 0)

      head ->
        started = System.monotonic_time(:microsecond)
        state = %{Pages.install_globals(state, head.globals) | resident: MapSet.new()}
        active = for %{region: region, payload: payload} <- head.activity, Pages.decode(payload), do: {0, region}
        {keys, ids} = Enum.reduce(head.txns, {[], []}, fn txn, {k, i} -> {k2, i2} = Pages.txn_needs(txn); {k2 ++ k, i2 ++ i} end)
        # 后缀写到的 L0 页重放后要重算树冠片段（片段不进日志）：连同粗层祖页扩 26 邻页装入（与编辑闭包相同）；活动页同样扩邻页（模拟读邻格）。
        touched = for {0, page} <- Enum.uniq(keys), do: page
        # 活动页同样带粗层祖页：恢复后第一步模拟提交就会逐级归约（评审 A2 / F1）。
        seeds = Pages.with_ancestors(active ++ for(page <- touched, do: {0, page}))
        state = PageLoad.load_sync(state, Enum.uniq(seeds), Enum.uniq(keys), Enum.uniq(ids))
        loaded = System.monotonic_time(:microsecond)
        state = state |> replay_txns(head.txns) |> VoxelRegion.World.Canopy.refresh_pages(touched)

        Logger.info("voxel_page_restore prefix=#{head.prefix} suffix=#{length(head.txns)} active=#{length(active)} " <>
          "resident=#{resident_count(state)} load_us=#{loaded - started} replay_us=#{System.monotonic_time(:microsecond) - loaded}")

        put_in(state.page_store.published, head.prefix)
    end
  end

  defp resident_count(%{resident: :all}), do: :all
  defp resident_count(%{resident: resident}), do: MapSet.size(resident)

  @impl true
  def terminate(_reason, state) do
    VoxelRegion.World.Definitions.stop(state)
    VoxelRegion.World.PageCut.stop_writer(state)
  end

  @impl true
  def code_change(:region_bases, state, _extra), do: {:ok, Map.put_new(state, :region_bases, %{})}
end
