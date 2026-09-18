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

  alias VoxelRegion.Attachments
  use GenServer
  require Logger
  import Bitwise
  alias VoxelRegion.{OverlayLog, Damage}
  alias VoxelRegion.{CollisionSource, FileStore, Prefab, Reducer}
  alias VoxelRegion.{Combustion, Liquid, Phase}
  alias MmoContracts.Voxel.{CanonicalDelta, CanonicalSnapshot, Codec, Payload}

  @micro VoxelRegion.Spatial.micro_resolution()
  @max_level 5
  @resident_level 4
  @default_cache_bytes 512 * 1024 * 1024
  @name __MODULE__

  # ---- API

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))

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

  @doc "角色确认余额；单位为一个 canonical 微格体积。"
  def material_balances(server, cid),
    do: GenServer.call(server, {:material_balances, cid}, 300_000)

  @doc "普通角色查询或付费建造，复用世界事务。"
  def production_intent(server, actor, request) do
    if valid_edit_coord?(request.coord) do
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
          # Test-only first-slice domain; the demo supplies its closed experimental bounds.
          liquid_bounds: Keyword.get(opts, :liquid_bounds, Application.get_env(:voxel_region, :liquid_bounds)),
          damage: %{},
          epochs: %{},
          tool_sessions: %{},
          thermal: load_thermal_environment(opts),
          thermal_work: empty_thermal_work(),
          material_balances: %{},
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
          prefabs:
            Prefab.load(
              Keyword.get(
                opts,
                :prefab_catalog_path,
                Application.get_env(:voxel_region, :prefab_catalog_path)
              )
            ),
          overlay_regions: %{},
          seq: 0,
          entries: %{},
          subs: %{},
          canonical_subs: %{},
          replica_subs: %{},
          log: {log, log.open(world_dir, cv)}
        }

        state = replay_log(state)

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
        state = if liquid_enabled?(state), do: adopt_liquid_sources(state), else: state

        Logger.info(
          "voxel_region world #{FileStore.hex(cv)} ready, seq=#{state.seq}, root=#{world_dir}"
        )

        if liquid_enabled?(state), do: schedule_liquid(state)
        if state.thermal, do: Process.send_after(self(), :thermal_commit, 500)
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

  def handle_call({:publish_properties, catalog}, _, state) do
    compatible =
      Damage.material_units(catalog) == state.material_units_per_micro and
        (map_size(state.attachments) == 0 or
           Map.get(state.properties, :attachments) == Map.get(catalog, :attachments)) and
        Enum.all?(VoxelRegion.Circuit.devices(state.damage), fn {_, {_, c}} ->
          Map.fetch!(state.properties.tools, c.tool_id) == Map.get(catalog.tools, c.tool_id)
        end) and
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
      publish_property_catalog(state, catalog, state.thermal)
    else
      {:reply, {:error, :property_version_in_use}, state}
    end
  end

  def handle_call({:publish_parameters, catalog, expected_digest}, _, state) do
    cond do
      state.properties.digest != expected_digest ->
        {:reply, {:error, :property_version_mismatch}, state}

      not compatible_parameters?(state.properties, catalog) ->
        {:reply, {:error, :property_version_in_use}, state}

      true ->
        publish_property_catalog(state, catalog, parameter_thermal_reference(state, catalog))
    end
  end

  def handle_call({:thermal_experiment, config}, _, state) do
    true = config["classification"] == "Test-only"

    true =
      config["ambient_kelvin"] > 0 and config["environment_w_per_m2_k"] > 0 and
        config["tolerance_kelvin"] > 0

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

    if state.thermal == nil, do: Process.send_after(self(), :thermal_commit, 500)
    state = thermal_commit(rebuild_thermal_work(%{state | thermal: thermal}), [])
    {:reply, :ok, state}
  end

  # Test-only authored initial supply, unavailable through Gate player messages.
  def handle_call({:liquid_experiment, edits}, _, state) do
    true = liquid_enabled?(state)
    true = Enum.all?(edits, fn {cell,_} -> valid_edit_coord?(cell) and liquid_inside?(cell,state.liquid_bounds) end)
    changes = for {cell,m} <- edits, Phase.liquid?(m) or phase_material?(state,m) or Map.has_key?(state.liquid_units,cell),
      into: %{}, do: {cell,if(Phase.liquid?(m) or phase_material?(state,m),do: liquid_capacity(state),else: 0)}
    values = for {cell,m} <- edits, phase_material?(state,m), into: %{},
      do: {cell,{Phase.energy(%{material: m},1.0,state.properties.materials[m],phase_ambient(state)),liquid_capacity(state)*1.0}}
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

  def handle_call({:tool_range, id}, _, state) do
    result =
      with %{tools: tools} <- state.properties,
           {:ok, tool} <- Map.fetch(tools, id),
           do: tool["range_macro"]

    {:reply, if(is_number(result), do: result, else: {:error, :invalid_tool}), state}
  end

  def handle_call({:material_balances, cid}, _, state),
    do: {:reply, Enum.map(state.production_materials, &balance_state(state, cid, &1)), state}

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

                not same_tool_target?(target, request) ->
                  {:reply, {:error, :stale_target}, state}

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
          {:reply, reply, next} = player_prefab(state, actor, kind, request)
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
    {:reply, :ok, compact_log(state)}
  end

  @impl true
  def handle_info(:liquid_commit, state) do
    state = advance_liquid(state)
    schedule_liquid(state)
    {:noreply, state}
  end

  def handle_info(:thermal_commit, state) do
    started = System.monotonic_time(:microsecond)

    state =
      if state.thermal.active or map_size(VoxelRegion.Circuit.devices(state.damage)) > 0,
        do: advance_thermal(state),
        else: state

    Process.send_after(self(), :thermal_commit, 500)

    if state.thermal.active,
      do:
        Logger.info(
          "voxel_thermal_callback elapsed_us=#{System.monotonic_time(:microsecond) - started}"
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

        previous =
          state.entries
          |> Enum.filter(fn {seq, _} -> seq > have_seq end)
          |> Enum.sort_by(&elem(&1, 0))

        transactions = Enum.map(previous, fn {_, e} -> project_transaction(e, level, region) end)
        has_region = Enum.any?(transactions, &(&1 == :region))

        transactions =
          Enum.reject(transactions, &(&1 != :region and &1.entries == [] and &1.coarse == []))

        served = %{
          state
          | served_headers: Map.put(state.served_headers, key, {header.seq, header.hash})
        }

        if client_version == state.cv and header.hash == have_hash and header.seq == have_seq do
          {{:unchanged, level, region}, served}
        else
          entry_reply = {:entries, level, region, transactions}
          payload_reply = {:payload, level, region, bytes}

          if client_version == state.cv and have_seq > 0 and known and not has_region and
               transactions != [] and
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

    ids = live_instance_ids(refined, state.instances)

    %{
      payload
      | liquid_units: for({cell, units} <- state.liquid_units,
            local = Payload.local(region, cell), Payload.in_span?(local),
            into: %{}, do: {Payload.cell_index(local), units}),
        attachments: Attachments.extract(state.attachments, region),
        refined: refined,
        instances: Map.take(state.instances, ids),
        format_version: if(map_size(refined) > 0 or payload.format_version == 5, do: 5, else: 4)
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
    with {:ok, definition} <- Map.fetch(state.prefabs, id), true <- orientation in 0..23 do
      cells = Prefab.footprint(definition, anchor, orientation)
      macros = footprint_macros(cells)

      if Enum.all?(macros, &valid_edit_coord?/1),
        do: {:ok, cells, macros},
        else: {:error, :invalid_coordinate}
    else
      :error -> {:error, :definition_not_found}
      false -> {:error, :invalid_orientation}
    end
  end

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
    for {cell, slots} <- state.refined,
        Enum.any?(slots, fn {_, {_, owner}} -> MapSet.member?(ids, owner) end),
        do: cell
  end

  defp clear_subtree(state, ids, cells) do
    next =
      Enum.reduce(cells, state, fn cell, s ->
        slots =
          Map.fetch!(s.refined, cell)
          |> Map.reject(fn {_, {_, owner}} -> MapSet.member?(ids, owner) end)

        refined =
          if map_size(slots) == 0,
            do: Map.delete(s.refined, cell),
            else: Map.put(s.refined, cell, slots)

        put_overlay(%{s | refined: refined}, 0, cell, {0, MmoContracts.Voxel.Skins.uniform(0)})
      end)

    owned =
      Map.filter(next.attachment_owners, fn {_, {owner, _}} -> MapSet.member?(ids, owner) end)
      |> Map.keys()
      |> MapSet.new()

    %{
      next
      | instances: Map.drop(next.instances, MapSet.to_list(ids)),
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
    delta =
      Enum.reduce(cells, %{}, fn cell, delta ->
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
           ) do
      {next, balances} =
        Enum.reduce(delta, {state, %{}}, fn {m, n}, {s, b} ->
          {s, paid} = settle_material(s, actor.cid, m, n)
          {s, Map.merge(b, paid.material_balances)}
        end)

      {:ok, next, %{material_balances: balances}}
    else
      {:error, _} = error -> error
    end
  end

  defp prefab_payment(_before, state, _cells, settlement), do: {:ok, state, settlement}

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
    nodes = Prefab.occurrences(definition, anchor, orientation, before.seq + 1, parent, slot)

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
      if Enum.all?(Map.keys(additions), &valid_edit_coord?/1) do
        Enum.reduce_while(additions, {:ok, state}, fn {cell, added}, {:ok, s} ->
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
        end)
      else
        {:error, :invalid_coordinate}
      end

    case result do
      {:ok, next} ->
        instances =
          Enum.reduce(nodes, next.instances, fn {owner, instance, _}, acc ->
            Map.put(acc, owner, instance)
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
            Enum.uniq(Map.keys(additions) ++ changed ++ Attachments.macros(slots)),
            actor
          )
        end

      {:error, reason} ->
        {:reply, {:error, reason}, before}
    end
  end

  defp live_instance_ids(refined, instances) do
    owners =
      Enum.reduce(refined, %{}, fn {_, slots}, acc ->
        local = Enum.reduce(slots, %{}, fn {_, {_, id}}, owners -> Map.put(owners, id, true) end)
        Map.merge(acc, local)
      end)

    MmoContracts.Voxel.Refined.ancestors(instances, Map.keys(owners))
  end

  defp prefab_reply(before, state, cells, settlement \\ %{}) do
    started = System.monotonic_time(:microsecond)
    removed = Map.keys(before.attachments) -- Map.keys(state.attachments)
    cells = Enum.uniq(cells ++ Attachments.macros(removed))

    state = %{
      state
      | seq: before.seq + 1,
        instances: Map.take(state.instances, live_instance_ids(state.refined, state.instances))
    }

    # owner 更换仍发布完整 L0；只有实际 slot/材质变化才重建结构和碰撞。
    material_changes =
      Enum.filter(cells, fn cell ->
        old = Map.get(before.refined, cell, %{})
        new = Map.get(state.refined, cell, %{})

        map_size(old) != map_size(new) or
          Enum.any?(old, fn {slot, {material, _}} ->
            case Map.get(new, slot) do
              {^material, _} -> false
              _ -> true
            end
          end)
      end)

    {state, attachment_keys, settlement} = prune_attachments(before, state, cells, settlement)

    with {:ok, state, settlement} <- prefab_payment(before, state, cells, settlement) do
      {:ok, coarse, state, _} = reduce_batch(state, attachment_dirty(state, cells), 1, [], 0)
      {coarse_txn, state} = select_transaction(state, coarse)
      terrain_payloads = state.payloads
      {state, structure_keys, structure_cells} = refresh_structure(state, cells)
      structure_done = System.monotonic_time(:microsecond)
      l0_keys = Enum.uniq(region_keys(Enum.map(cells, &{0, &1})) ++ attachment_keys)
      keys = l0_keys ++ structure_keys
      {entries, state} = region_afterimages(state, l0_keys, terrain_payloads)
      region_count = length(entries)

      entries = entries ++ structure_entries(state, structure_cells)

      regions_done = System.monotonic_time(:microsecond)
      {state, metadata} = damage_geometry(before, state, cells, false)

      txn =
        Map.merge(%{coarse_txn | entries: entries ++ coarse_txn.entries}, metadata)
        |> Map.merge(settlement)

      with {:ok, chunks} <- canonical_changes(before, state, Enum.map(material_changes, &{0, &1})),
           collision_done = System.monotonic_time(:microsecond),
           :ok <- append_log(state, txn) do
        log_done = System.monotonic_time(:microsecond)
        state = %{state | entries: Map.put(state.entries, state.seq, txn)}
        fanout(state, txn)
        fanout_canonical(state, txn, chunks, keys, before)

        Logger.info(
          "voxel_prefab seq=#{state.seq} cells=#{length(cells)} regions=#{region_count} structure_cells=#{length(structure_cells)} " <>
            "state_structure_us=#{structure_done - started} regions_us=#{regions_done - structure_done} " <>
            "collision_us=#{collision_done - regions_done} log_us=#{log_done - collision_done} " <>
            "fanout_us=#{System.monotonic_time(:microsecond) - log_done}"
        )

        {:reply, {:ok, state.seq}, state}
      else
        {:error, reason} -> {:reply, {:error, reason}, before}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, before}
    end
  end

  defp region_keys(cells) do
    for {level, {x, y, z}} <- cells,
        rx <- floor_div(x - 1, 64)..floor_div(x + 1, 64),
        ry <- floor_div(y - 1, 64)..floor_div(y + 1, 64),
        rz <- floor_div(z - 1, 64)..floor_div(z + 1, 64),
        do: {level, {rx, ry, rz}}
  end

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
    do: backend.append(handle, attachment_metadata(state, txn))

  # canonical 附件归属与ID分配水位随同一日志／检查点持久化；网络槽副本仍只需要全局ID。
  defp attachment_metadata(state, txn),
    do:
      Map.merge(txn, %{
        attachment_serial: state.attachment_serial,
        attachment_owners: state.attachment_owners,
        material_units_per_micro: state.material_units_per_micro
      })

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

  # 全局系统功能：占用与属性在同一 GenServer 提交点采样。
  defp property_context(state) do
    %{
      hp_enabled: state.properties != nil,
      digest: if(state.properties, do: state.properties.digest, else: <<0::256>>),
      thermal_enabled: state.thermal != nil,
      ambient_kelvin: if(state.thermal, do: state.thermal.config["ambient_kelvin"], else: 0.0)
    }
  end

  defp component_observations(%{properties: nil}, _box), do: []

  defp component_observations(state, box) do
    owners =
      for {cell, slots} <- state.refined,
          box == nil or VoxelRegion.PropertyObservation.contains?(cell, box),
          {slot, {material, {birth, _} = owner}} <- slots,
          into: %{} do
        {owner,
         %{
           micro: Prefab.micro_coord(cell, slot),
           granularity: 2,
           incarnation: birth,
           owner: owner,
           material: material
         }}
      end

    Enum.map(owners, fn {owner, target} ->
      property_state(state, target)
      |> Map.put(:observation_cells, subtree_cells(state, MapSet.new([owner])))
    end)
  end

  defp property_snapshot(state, box) do
    macros =
      for {_, t} <- state.damage,
          t.granularity in [0, 1, 4],
          VoxelRegion.PropertyObservation.relevant?(t, box),
          do: %{t | seq: state.seq, request_id: 0}

    %{
      property_states:
        macros ++ component_observations(state, box) ++ attachment_observations(state, box),
      property_context: property_context(state),
      epochs: state.epochs
    }
    |> public_properties()
    |> VoxelRegion.PropertyObservation.project(box)
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
            subtree_cells(before, MapSet.new([row.owner])) ++
              subtree_cells(state, MapSet.new([row.owner]))

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

  defp send_filtered(pid, %{entries: entries, coarse: coarse} = txn, filter) do
    entries = Enum.filter(entries, &matches?(&1, filter))
    coarse = Enum.filter(coarse, &matches_cell?(&1.level, &1.cell, filter))

    if entries != [] or coarse != [] do
      bin =
        Codec.encode_transaction(%{txn | entries: entries, coarse: coarse})
        |> IO.iodata_to_binary()

      send(pid, {:voxel_log_transaction_payload, bin})
    end
  end

  defp send_filtered(pid, entry, filter) do
    if matches?(entry, filter),
      do: send(pid, {:voxel_log_entry_payload, IO.iodata_to_binary(Codec.encode_entry(entry))})
  end

  defp matches?(%{payload: bytes}, filter) do
    {:ok, h} = Codec.decode_payload_header(bytes)
    {x, y, z} = h.region

    matches_span?(
      h.level,
      {x * 64, y * 64, z * 64},
      {x * 64 + 63, y * 64 + 63, z * 64 + 63},
      filter
    )
  end

  defp matches?(%{structure: _, level: level, cell: cell}, filter),
    do: matches_cell?(level, cell, filter)

  defp matches?(entry, {{{x0, y0, z0}, {x1, y1, z1}}, min_level}) do
    {rx, ry, rz} = region_of(entry.coord)

    in_box =
      rx >= x0 - 1 and rx <= x1 + 1 and ry >= y0 - 1 and ry <= y1 + 1 and rz >= z0 - 1 and
        rz <= z1 + 1

    in_box or Enum.any?(entry.coarse, &(&1.level >= min_level))
  end

  defp matches_cell?(level, cell, filter), do: matches_span?(level, cell, cell, filter)

  defp matches_span?(level, {ax, ay, az}, {bx, by, bz}, {{{x0, y0, z0}, {x1, y1, z1}}, min_level}) do
    step = 1 <<< level

    level >= min_level or
      (floor_div(ax * step, 64) <= x1 + 1 and floor_div((bx + 1) * step - 1, 64) >= x0 - 1 and
         floor_div(ay * step, 64) <= y1 + 1 and floor_div((by + 1) * step - 1, 64) >= y0 - 1 and
         floor_div(az * step, 64) <= z1 + 1 and floor_div((bz + 1) * step - 1, 64) >= z0 - 1)
  end

  defp project_transaction(%{entries: entries, coarse: coarse} = txn, level, region) do
    {ox, oy, oz} = Payload.origin(region)

    replacement =
      Enum.any?(entries, fn
        %{structure: _, level: l, cell: cell} ->
          l == level and Payload.in_span?(Payload.local(region, cell))

        %{payload: bytes} ->
          {:ok, h} = Codec.decode_payload_header(bytes)
          {x, y, z} = h.region

          h.level == level and x * 64 <= ox + 65 and x * 64 + 63 >= ox and y * 64 <= oy + 65 and
            y * 64 + 63 >= oy and z * 64 <= oz + 65 and z * 64 + 63 >= oz

        _ ->
          false
      end)

    if replacement do
      :region
    else
      cells =
        Enum.filter(entries, fn e ->
          level == 0 and Map.has_key?(e, :coord) and
            Payload.in_span?(Payload.local(region, e.coord))
        end)

      coarse =
        Enum.filter(coarse, fn e ->
          e.level == level and Payload.in_span?(Payload.local(region, e.cell))
        end)

      %{txn | entries: cells, coarse: coarse}
    end
  end

  defp project_transaction(entry, level, region) do
    project_transaction(
      %{seq: entry.seq, entries: [%{entry | coarse: []}], coarse: entry.coarse},
      level,
      region
    )
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
        ids = live_instance_ids(refined, instances)

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
    liquid_dirty = Enum.map(Map.keys(liquid_changes), &{0,&1})
    state = %{state | liquid_units: Liquid.apply_changes(state.liquid_units, liquid_changes)}

    removed_slots =
      for {slot, {id, _}} <- state.attachments, MapSet.member?(removed_attachments, id), do: slot

    state = %{state | attachments: Map.drop(state.attachments, removed_slots)}

    removed_cells =
      if MapSet.size(removed_owners) == 0, do: [], else: subtree_cells(state, removed_owners)

    state =
      if removed_cells == [],
        do: state,
        else:
          clear_subtree(state, removed_owners, removed_cells)
          |> then(fn s ->
            %{s | instances: Map.take(s.instances, live_instance_ids(s.refined, s.instances))}
          end)

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
        if removed_slots == [],
          do: {:ok, state},
          else: commit_attachment(before, state, removed_slots, settlement)

      {geometry_changed, state} ->
        changed = Enum.uniq(geometry_changed ++ liquid_dirty)
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

            {state, metadata} =
              damage_geometry(before, state, Enum.map(geometry_changed, &elem(&1, 1)), true)

            {state, phase_rows} = put_phase_values(state, phase_values)
            metadata = Map.update!(metadata, :property_states, &(&1 ++ phase_rows))
            if_phase_dirty = Map.keys(phase_values) |> Enum.flat_map(&[&1 | VoxelRegion.Thermal.neighbors(&1)])
            state = put_in(state.thermal_work.geometry, Map.drop(state.thermal_work.geometry, if_phase_dirty))
            metadata = if state.thermal, do: Map.put(metadata,:thermal,state.thermal), else: metadata
            imaged = System.monotonic_time(:microsecond)
            txn = Map.merge(txn, metadata) |> Map.merge(settlement)

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
              state = %{state | entries: Map.put(state.entries, state.seq, txn)}
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

              {:ok, state}
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

    %{state | entries: %{state.seq => txn}}
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
          |> Map.take(~w(ambient_kelvin environment_w_per_m2_k tolerance_kelvin))

        true =
          Enum.all?(
            ~w(ambient_kelvin environment_w_per_m2_k tolerance_kelvin),
            &is_number(config[&1])
          ) and
            config["ambient_kelvin"] > 0 and config["environment_w_per_m2_k"] >= 0 and
            config["tolerance_kelvin"] > 0

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
          if material != 0 and not (phase_material?(state,material) and Map.has_key?(state.liquid_units,cell) and
            rem(div(slot,@micro),@micro) >= div(state.liquid_units[cell]*@micro+liquid_capacity(state)-1,liquid_capacity(state))),
            do: %{
              micro: cell |> Tuple.to_list() |> Enum.map(&(&1 * @micro)) |> List.to_tuple(),
              granularity: 0,
              incarnation: Map.get(state.epochs, cell, 0),
              owner: {0, 0},
              material: material
            }

        {target, state}
    end
  end

  defp property_state(state, target) do
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
                component_max_hp(state, target.owner)

              3 ->
                attachment_max_hp(state, target)

              4 ->
                m["max_hp_per_macro"] *
                  VoxelRegion.ThermalAttachments.volume(
                    Attachments.slot(target),
                    state.properties
                  )

              0 ->
                Damage.max_hp(m, 0) * phase_volume(state, target)

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
             do: Map.put(row, :temperature_kelvin, state.thermal.config["ambient_kelvin"]),
             else: row
      end

    # 整件 HP 记录上的环境值仅声明附件默认温度；命中槽的确认温度由 granularity 4 覆盖。
    if state.thermal && target.granularity == 3 && Map.has_key?(m, "heat_capacity_per_macro"),
      do: Map.put(row, :temperature_kelvin, state.thermal.config["ambient_kelvin"]),
      else: row
  end

  # 全局系统功能：温度和 HP 仍由同一个 World 的稀疏状态记录持有。
  # 每 500 ms 提交一次；原生核按容量/接触选择不超过 50 ms 的稳定步长。
  # 派生工作集不写日志；缓存只含身份、材质与暴露面，数值批次读取当前权威记录。
  defp empty_thermal_work,
    do: %{
      hot: MapSet.new(),
      cells: MapSet.new(),
      geometry: %{},
      edges: [],
      builds: 0,
      seeds: nil,
      ordered: [],
      attachment_cells: nil,
      attachment_graph: nil,
      solid_nodes: %{},
      thermal_slots: %{},
      indexed_edges: []
    }

  defp rebuild_thermal_work(%{thermal: nil} = state),
    do: %{state | thermal_work: empty_thermal_work()}

  defp rebuild_thermal_work(state) do
    hot = thermal_hot(state)

    active = state.thermal.active or Enum.any?(state.damage, fn {_, t} -> fuel_exhausted?(t) end)
    %{state | thermal: %{state.thermal | active: active}, thermal_work: %{empty_thermal_work() | hot: hot}}
  end

  defp thermal_hot(state) do
      for {_, t} <- state.damage,
          Map.get(t, :burning, false) or
            (Map.has_key?(t, :temperature_kelvin) and
               abs(t.temperature_kelvin - state.thermal.config["ambient_kelvin"]) >
                 state.thermal.config["tolerance_kelvin"]),
          cell <- thermal_cells(t),
          into: MapSet.new(),
          do: cell
  end

  defp thermal_cells(%{granularity: 4} = t), do: Attachments.macros([Attachments.slot(t)])
  defp thermal_cells(t), do: [Damage.macro(t)]

  defp advance_thermal(state) do
    start = System.monotonic_time(:microsecond)
    before = state
    state = put_in(state.thermal_work.builds, 0)
    {state, visited} = circuit_steps(state, 0.5, MapSet.new())
    # 同一提交内只扩张热域，避免容差边缘反复删添接触；批末按当前真值收缩。
    hot = thermal_hot(state)
    state = %{state | thermal_work: %{state.thermal_work | hot: hot},
      thermal: %{state.thermal | active: map_size(state.thermal.sources) > 0 or MapSet.size(hot) > 0}}
    # 燃料耗尽表示材料被消耗，不保留可重新采掘的整块木材。
    # 微格／附件沿已有最低层整件完整度语义归零，其余未燃料量记入移除账。
    {state, visited} = Enum.reduce(state.damage, {state, visited}, fn {_, row}, {s, keys} ->
      if fuel_exhausted?(row) do
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

    Logger.info(
      "voxel_thermal_sim simulated_s=0.5 max_step_ms=50 elapsed_us=#{System.monotonic_time(:microsecond) - start} hot=#{MapSet.size(work.hot)} candidates=#{map_size(work.geometry)} geometry_builds=#{work.builds}"
    )

    rows =
      for key <- visited,
          t <- [Map.fetch!(state.damage, key)],
          Map.get(before.damage, key) != t,
          do: %{t | seq: state.seq + 1, request_id: 0}

    phase_changes = for {_,t}<-state.damage, phase_target?(state,t),
      q=Map.get(state.liquid_units,Damage.macro(t),liquid_capacity(state)),
      e=Phase.energy(t,q/liquid_capacity(state),state.properties.materials[t.material],state.thermal.config["ambient_kelvin"]),
      Phase.material(t.material,e,q/liquid_capacity(state),state.properties.materials)!=t.material,
      into: %{}, do: {Damage.macro(t),q}
    dead = Enum.filter(rows, &(&1.hp == 0.0 and not phase_target?(state,&1)))

    if dead == [] and map_size(phase_changes)>0 do
      {:ok,state}=commit_liquid(state,phase_changes,%{property_states: rows})
      state
    else
    if dead == [] do
      thermal_commit(state, rows)
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
        commit_liquid(state, phase_changes, %{property_states: rows}, macros, owners, attachments)

      state
    end
    end
  end

  defp fuel_exhausted?(row), do: Map.get(row, :remaining_fuel_j, 1.0) <= 1.0e-9

  defp circuit_steps(state, remaining, visited) when remaining < 1.0e-12, do: {state, visited}

  defp circuit_steps(state, remaining, visited) do
    if map_size(VoxelRegion.Circuit.devices(state.damage)) == 0 do
      thermal_steps(state, remaining, visited, %{})
    else
      plan =
        VoxelRegion.Circuit.plan(
          state.attachments,
          state.damage,
          state.properties,
          state,
          &target_at/2,
          remaining
        )

      {state, visited} = thermal_steps(plan.state, plan.duration, visited, plan.powers)

      {damage, visited} =
        Enum.reduce(plan.outputs, {state.damage, visited}, fn {id, c}, {damage, visited} ->
          key = {3, id}
          {Map.update!(damage, key, &Map.put(&1, :circuit, c)), MapSet.put(visited, key)}
        end)

      thermal =
        state.thermal
        |> Map.update(:circuit_supplied_j, plan.supplied_j, &(&1 + plan.supplied_j))
        |> Map.update(:circuit_light_j, plan.light_j, &(&1 + plan.light_j))
        |> Map.update(:circuit_cooling_j, plan.cooling_j, &(&1 + plan.cooling_j))
        |> Map.update(:circuit_rejected_j, plan.rejected_j, &(&1 + plan.rejected_j))

      Logger.info(
        "voxel_circuit simulated_s=#{plan.duration} nodes=#{plan.nodes} edges=#{plan.edges} solve_us=#{plan.elapsed_us} supplied_j=#{plan.supplied_j} light_j=#{plan.light_j} cooling_j=#{plan.cooling_j} rejected_j=#{plan.rejected_j}"
      )

      circuit_steps(
        %{state | damage: damage, thermal: thermal},
        remaining - plan.duration,
        visited
      )
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

    electric_cells =
      for {key, _} <- powers,
          cell <-
            (case key do
               {4, {type, p}} -> Attachments.macros([{div(type, 3), rem(type, 3), p}])
               {_, p} -> [Damage.macro(%{micro: p})]
             end),
          into: MapSet.new(),
          do: cell

    combustion_cells =
      for {_, t} <- state.damage,
          Map.get(t, :burning, false),
          cell <- thermal_cells(t),
          into: MapSet.new(),
          do: cell

    seeds =
      state.thermal_work.hot
      |> MapSet.union(MapSet.new(Map.keys(state.thermal.sources)))
      |> MapSet.union(electric_cells)
      |> MapSet.union(combustion_cells)

    # 热种子不变时复用六邻域；编辑仍通过 geometry 删除使拓扑失效。
    cells =
      if seeds == state.thermal_work.seeds,
        do: state.thermal_work.cells,
        else: seeds |> Enum.flat_map(&[&1 | VoxelRegion.Thermal.neighbors(&1)]) |> MapSet.new()

    # 上批 geometry 的键恰好是 cells；编辑只会删键。集合未变且未删键时直接复用。
    reuse_geometry =
      cells == state.thermal_work.cells and
        map_size(state.thermal_work.geometry) == MapSet.size(cells)

    missing =
      if reuse_geometry,
        do: MapSet.new(),
        else: MapSet.difference(cells, MapSet.new(Map.keys(state.thermal_work.geometry)))

    neighborhood_done = System.monotonic_time(:microsecond)

    geometry =
      if reuse_geometry,
        do: state.thermal_work.geometry,
        else: Map.take(state.thermal_work.geometry, MapSet.to_list(cells))

    {geometry, state} =
      Enum.reduce(missing, {geometry, state}, fn cell, {geometry, s} ->
        {nodes, s} =
          VoxelRegion.ThermalGeometry.cell(
            cell,
            s.refined,
            s.properties.materials,
            s,
            &target_at/2,
            &phase_volume/2
          )

        {Map.put(geometry, cell, nodes), s}
      end)

    geometry_done = System.monotonic_time(:microsecond)

    attachment_cells = state.thermal_work.attachment_cells ||
      Enum.map(state.attachments, fn {slot, value} -> {slot, value, Attachments.macros([slot])} end)

    {ordered, edges, indexed_edges, solid_nodes, thermal_slots, attachment_graph, state} =
      if cells == state.thermal_work.cells and MapSet.size(missing) == 0 do
        {state.thermal_work.ordered, state.thermal_work.edges, state.thermal_work.indexed_edges,
         state.thermal_work.solid_nodes, state.thermal_work.thermal_slots, state.thermal_work.attachment_graph, state}
      else
        nodes = geometry |> Map.values() |> List.flatten() |> Map.new()

        slots =
          for {slot, value, footprint} <- attachment_cells,
              Enum.any?(footprint, &MapSet.member?(cells, &1)), into: %{}, do: {slot, value}

        # 只添删热域时复用；旧域内的编辑失效仍重建，因无热容量宿主也会改变附件暴露面。
        if MapSet.disjoint?(missing, state.thermal_work.cells) and
             nodes == state.thermal_work.solid_nodes and slots == state.thermal_work.thermal_slots do
          {state.thermal_work.ordered, state.thermal_work.edges, state.thermal_work.indexed_edges,
           nodes, slots, state.thermal_work.attachment_graph, state}
        else
          solid_nodes = nodes
          {nodes, state, attachment_graph} =
            VoxelRegion.ThermalAttachments.add(nodes, slots, state.properties, state, &target_at/2, &phase_volume/2,
              state.thermal_work.attachment_graph)

          # 默认记录仅由目录、配置和几何派生；已有温度/HP/燃料仍只读 state.damage。
          defaults = %{state | damage: %{}}
          ordered = Enum.map(nodes, fn {key, n} ->
            {key, Map.merge(n, %{damage_key: Damage.key(n.target), cell: Damage.macro(n.target),
                                cells: thermal_cells(n.target), default: property_state(defaults, n.target),
                                ignition: if(Combustion.combustible?(n.material),
                                  do: n.material["ignition_kelvin"] * 1.0, else: nil)})}
          end)
          edges = VoxelRegion.ThermalGeometry.contacts(nodes)
          indices = ordered |> Enum.with_index() |> Map.new(fn {{cell, _}, i} -> {cell, i} end)

          {ordered, edges,
           for({a, b, g} <- edges, do: {Map.fetch!(indices, a), Map.fetch!(indices, b), g}),
           solid_nodes, slots, attachment_graph, state}
        end
      end

    nodes_done = System.monotonic_time(:microsecond)

    work = %{
      state.thermal_work
      | geometry: geometry,
        cells: cells,
        edges: edges,
        seeds: seeds,
        ordered: ordered,
        attachment_cells: attachment_cells,
        attachment_graph: attachment_graph,
        solid_nodes: solid_nodes,
        thermal_slots: thermal_slots,
        indexed_edges: indexed_edges,
        builds: state.thermal_work.builds + MapSet.size(missing)
    }

    sources =
      Map.filter(state.thermal.sources, fn {cell, source} ->
        Enum.any?(Map.get(geometry, cell, []), fn {_, n} ->
          same_target?(source.target, n.target) and source.remaining_j > 0
        end)
      end)

    # 拓扑只缓存身份与材料；温度和 HP 每批从唯一权威记录取值。
    duration =
      Enum.reduce(sources, duration, fn {_, s}, dt -> min(dt, s.remaining_j / s.power_w) end)

    duration =
      Enum.reduce(ordered, duration, fn {_, n}, dt ->
        row = Map.get(state.damage, n.damage_key)

        if row && Map.get(row, :burning, false) do
          min(dt, row.remaining_fuel_j / row.power_w)
        else
          dt
        end
      end)

    duration =
      # 空列表是已派生的合法空气格；只有缺键才表示几何尚未派生。
      if Enum.any?(seeds, &(not Map.has_key?(geometry, &1))),
        do: min(duration, 0.05),
        else: duration

    {targets, input} =
      Enum.map(ordered, fn {node_key, n} ->
        # Damage.key 含完整目标身份；已有记录直接读取，最终提交统一盖 seq/request_id。
        t =
          case Map.fetch(state.damage, n.damage_key) do
            {:ok, t} -> t
            :error -> %{n.default | seq: state.seq}
          end

        temperature = Map.get(t, :temperature_kelvin, config["ambient_kelvin"])
        cell = n.cell
        source = if t.granularity == 0, do: Map.get(sources, cell)

        combustion = if Map.get(t, :burning, false), do: t.power_w, else: 0.0

        electric = Map.get(powers, node_key, 0.0)

        # World 声明事件与相变数值输入；NIF 在批内维护焓和温度，材质替换仍由 World 提交。
        ignition =
          if n.ignition != nil and t.hp > 0 and
               not Map.get(t, :burning, false) and not fuel_exhausted?(t),
            do: n.ignition,
            else: nil

        phase =
          if phase_target?(state, t) do
            volume = phase_volume(state, t)
            {Phase.energy(t, volume, n.material, config["ambient_kelvin"]), volume * 1.0,
             n.material["phase_transition_kelvin"] * 1.0,
             volume * n.material["latent_heat_per_macro_j"],
             n.material["heat_capacity_per_macro"] * 1.0, Phase.liquid?(t.material)}
          end

        {{cell, n.cells, t, temperature, electric, combustion},
         {{temperature, t.hp, t.max_hp, n.capacity, n.material["thermal_conductivity"] * 1.0,
          n.material["heat_resistance_kelvin"] * 1.0, n.exposed_faces * 1.0,
          electric + combustion + if(source, do: source.power_w * 1.0, else: 0.0),
          abs(electric + combustion + if(source, do: source.power_w * 1.0, else: 0.0)) * duration,
          Enum.any?(n.cells, &MapSet.member?(state.thermal_work.hot, &1)) or
            source != nil or combustion > 0 or electric != 0},
          {ignition, phase, t.granularity in [1, 4]}}}
      end)
      |> Enum.unzip()

    prepared = System.monotonic_time(:microsecond)

    {done, result, supplied, environment} =
      VoxelRegion.ThermalNative.advance(
        input,
        indexed_edges,
        config["ambient_kelvin"] * 1.0,
        config["environment_w_per_m2_k"] * 1.0,
        config["tolerance_kelvin"] * 1.0,
        duration
      )

    calculated = System.monotonic_time(:microsecond)

    {changes, sources, hot, losses, combustion_used} =
      Enum.zip_reduce(targets, result, {[], %{}, [], %{}, 0.0}, fn {cell, target_cells, t, old_temperature,
                                                                    _electric, combustion},
                                                                   result,
                                                                   {changes, left, hot, losses,
                                                                    combustion_used} ->
        {temperature, hp, phase_energy} =
          case result do
            {temperature, hp, _remaining} -> {temperature, hp, nil}
            {temperature, hp, _remaining, energy} -> {temperature, hp, energy}
          end
        source = if t.granularity == 0, do: Map.get(sources, cell)
        remaining = if source, do: max(0.0, source.remaining_j - source.power_w * done), else: 0.0

        left =
          if t.granularity == 0 and Map.has_key?(sources, cell) and remaining > 1.0e-9,
            do: Map.put(left, cell, %{Map.fetch!(sources, cell) | remaining_j: remaining}),
            else: left

        {burned, energy, _used} =
          if combustion > 0 and Map.get(t, :burning, false),
            do: Combustion.step(t, done),
            else: {t, 0.0, 0.0}

        burned = if phase_energy == nil, do: burned, else: Map.put(burned, :phase_energy_j, phase_energy)
        burned = damage_pick_baseline(burned, hp)

        hot =
          if abs(temperature - config["ambient_kelvin"]) > config["tolerance_kelvin"] or
               Map.get(burned, :burning, false), do: target_cells ++ hot, else: hot

        pool = if t.granularity == 4, do: {3, t.incarnation}, else: {2, t.owner}

        losses =
          if t.granularity in [1, 4] and hp < t.hp,
            do:
              Map.update(losses, pool, {t, t.hp - hp}, fn {row, loss} ->
                {row, loss + t.hp - hp}
              end),
            else: losses

        hp = if t.granularity in [1, 4], do: t.hp, else: hp

        if temperature == old_temperature and hp == t.hp and burned == t do
          {changes, left, hot, losses, combustion_used + energy}
        else
          t = burned |> Map.put(:temperature_kelvin, temperature) |> Map.put(:hp, hp)
          {[{Damage.key(t), t} | changes], left, hot, losses, combustion_used + energy}
        end
      end)

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
    {damage, propagated} = ignite_heated_materials(state, damage, ordered)
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

    work = if active, do: %{work | hot: hot}, else: %{empty_thermal_work() | builds: work.builds}

    Logger.info(
      "voxel_thermal_kernel simulated_s=#{done} nodes=#{length(input)} edges=#{length(indexed_edges)} prepare_us=#{prepared - started} nif_us=#{calculated - prepared} accept_us=#{System.monotonic_time(:microsecond) - calculated}"
    )

    Logger.info(
      "voxel_thermal_prepare neighborhood_us=#{neighborhood_done - started} geometry_us=#{geometry_done - neighborhood_done} nodes_us=#{nodes_done - geometry_done} input_us=#{prepared - nodes_done}"
    )

    {%{state | damage: damage, thermal: thermal, thermal_work: work}, changed, done}
  end

  defp thermal_commit(state, rows) do
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
    }

    start = System.monotonic_time(:microsecond)
    :ok = append_log(state, txn)
    persisted = System.monotonic_time(:microsecond)
    state = %{state | entries: Map.put(state.entries, state.seq, txn)}
    fanout(state, txn)
    fanout_canonical(state, txn, [], [], state)
    broadcast = System.monotonic_time(:microsecond)

    Logger.info(
      "voxel_thermal_commit seq=#{state.seq} sim_s=#{state.thermal.elapsed_s} states=#{length(rows)} persist_us=#{persisted - start} broadcast_us=#{broadcast - persisted} active=#{state.thermal.active} supplied_j=#{state.thermal.supplied_j} environment_j=#{state.thermal.environment_j}"
    )

    state
  end

  # 点燃只消费实际温度；热源、电热和燃烧热共用接触导热，不另设火种邻接真值。
  defp ignite_heated_materials(state, damage, ordered) do
    # 不可燃材质不需要读取或构造默认损伤记录。
    for {_, node} <- ordered, node.ignition != nil, reduce: {damage, []} do
      {rows, changed} ->
        material = node.material
        target = Map.get_lazy(rows, node.damage_key, fn -> %{node.default | seq: state.seq} end)
        if target.hp > 0 and
             not Map.get(target, :burning, false) and not fuel_exhausted?(target) and
             Map.get(target, :temperature_kelvin, state.thermal.config["ambient_kelvin"]) >= material["ignition_kelvin"] do
          row = Combustion.ignite(target, material, combustion_volume(state, target))
          {Map.put(rows, Damage.key(row), row), [{Damage.key(row), row} | changed]}
        else
          {rows, changed}
        end
    end
  end

  defp component_max_hp(state, owner) do
    for cell <- subtree_cells(state, MapSet.new([owner])),
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
        phase_target?(s,target) and Map.has_key?(s.liquid_units,Damage.macro(target)) and
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
              (t.temperature_kelvin - s.thermal.config["ambient_kelvin"])

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
            thermal =
              case Map.get(t, :circuit) do
                %{remaining_j: joules} ->
                  Map.update(s.thermal, :circuit_removed_j, joules, &(&1 + joules))

                nil ->
                  s.thermal
              end

            {%{s | damage: Map.delete(s.damage, key), thermal: thermal},
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
          String.starts_with?(tool["action"], "circuit.") ->
            operate_circuit(before, state, actor, request, target, tool)

          String.starts_with?(tool["action"], "combustion.") ->
            operate_combustion(before, state, actor, request, target, tool)

          tool["action"] in ["phase.cool", "phase.heat"] ->
            operate_phase(before, state, actor, request, target, tool)

          phase_target?(state,target) and not Phase.liquid?(target.material) ->
            damage_phase_solid(before, state, actor, request, target, tool)

          tool["action"] == "heat" ->
            feed_heater(before, state, actor, request, target, tool)

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
                  if target.material in state.production_materials do
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
                    state = %{state | entries: Map.put(state.entries, state.seq, txn)}
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

  # 全局系统功能：投料与有限能源同笔保存；建造不产生能源，拆除不返还已经消费的燃料。
  defp operate_circuit(before, state, actor, request, target, tool) do
    with true <-
           request.action == 1 and state.thermal != nil and target.granularity == 3 and
             elem(target.owner, 1) < 3,
         true <-
           tool["action"] != "circuit.install" or
             Map.get(state.properties.materials[target.material], "electrical_conductivity", 0) > 0,
         {:ok, anchor, size} <-
           VoxelRegion.Circuit.shape(attachment_slots(state, target.incarnation)),
         {:ok, c, state, settlement} <-
           circuit_operation(state, actor, target, tool, anchor, size) do
      target = target |> Map.put(:circuit, c) |> Map.put(:seq, state.seq + 1)

      next = %{
        state
        | seq: state.seq + 1,
          damage: Map.put(state.damage, Damage.key(target), target)
      }

      txn =
        Map.merge(
          %{
            seq: next.seq,
            entries: [],
            coarse: [],
            property_states: [target],
            thermal: next.thermal
          },
          settlement
        )

      case append_log(next, txn) do
        :ok ->
          next = %{next | entries: Map.put(next.entries, next.seq, txn)}
          fanout(next, txn)
          fanout_canonical(next, txn, [], [], before)

          Logger.info(
            "voxel_circuit_input seq=#{next.seq} cid=#{actor.cid} id=#{target.incarnation} action=#{tool["action"]} kind=#{c.kind} closed=#{c.closed} remaining_j=#{c.remaining_j}"
          )

          {:reply, {:ok, next.seq}, next}

        {:error, reason} ->
          {:reply, {:error, reason}, before}
      end
    else
      false -> {:reply, {:error, :not_a_circuit_face}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp circuit_operation(state, actor, target, tool, anchor, size) do
    c = Map.get(target, :circuit)

    case tool["action"] do
      "circuit.install" when c == nil ->
        {:ok,
         %{
           tool_id: tool["tool_id"],
           kind: tool["circuit_kind"],
           anchor: anchor,
           size: size,
           closed: true,
           fault: 0,
           remaining_j: 0.0,
           voltage_v: 0.0,
           current_a: 0.0,
           power_w: 0.0
         }, state, %{}}

      "circuit.toggle" when c != nil and c.kind == 2 ->
        {:ok, %{c | closed: not c.closed}, state, %{}}

      "circuit.feed" when c != nil and c.kind == 1 ->
        fuel = tool["fuel_material_id"]
        units = tool["fuel_units"] * state.material_units_per_micro

        if Map.get(state.material_balances, {actor.cid, fuel}, 0) >= units do
          {state, settlement} = settle_material(state, actor.cid, fuel, -units)

          state =
            put_in(
              state.thermal,
              Map.update(
                state.thermal,
                :circuit_fed_j,
                tool["circuit_energy_j"],
                &(&1 + tool["circuit_energy_j"])
              )
            )

          {:ok, %{c | remaining_j: c.remaining_j + tool["circuit_energy_j"]}, state, settlement}
        else
          {:error, :insufficient_material}
        end

      _ ->
        {:error, :invalid_circuit_operation}
    end
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

  defp combustion_volume(_state, target), do: Damage.volume(target.granularity)

  defp combustion_operation(before, state, actor, target, tool, material) do
    volume = combustion_volume(state, target)
    capacity = material["heat_capacity_per_macro"] * volume
    ambient = state.thermal.config["ambient_kelvin"]
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
        next = %{next | entries: Map.put(next.entries, next.seq, txn)}
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

  defp feed_heater(before, state, actor, request, target, tool) do
    fuel = tool["fuel_material_id"]
    units = tool["fuel_units"] * state.material_units_per_micro

    cond do
      request.action != 1 or state.thermal == nil ->
        {:reply, {:error, :thermal_unavailable}, state}

      target.granularity != 0 or
          "heat.receiver" not in state.properties.materials[target.material]["tags"] ->
        {:reply, {:error, :not_a_heater}, state}

      Map.get(state.material_balances, {actor.cid, fuel}, 0) < units ->
        {:reply, {:error, :insufficient_material}, state}

      true ->
        {state, settlement} = settle_material(state, actor.cid, fuel, -units)
        cell = Damage.macro(target)
        previous = Map.get(state.thermal.sources, cell)

        remaining =
          if previous && same_target?(previous.target, target),
            do: previous.remaining_j,
            else: 0.0

        source = %{
          target: target,
          power_w: tool["heat_power_w"],
          remaining_j: remaining + tool["heat_energy_j"]
        }

        thermal = %{
          state.thermal
          | sources: Map.put(state.thermal.sources, cell, source),
            active: true
        }

        next = %{state | seq: state.seq + 1, thermal: thermal} |> rebuild_thermal_work()

        txn =
          Map.merge(
            %{seq: next.seq, entries: [], coarse: [], property_states: [], thermal: thermal},
            settlement
          )

        case append_log(next, txn) do
          :ok ->
            next = %{next | entries: Map.put(next.entries, next.seq, txn)}
            fanout(next, txn)
            fanout_canonical(next, txn, [], [], before)

            Logger.info(
              "voxel_heater_feed seq=#{next.seq} cid=#{actor.cid} cell=#{inspect(cell)} fuel=#{fuel} units=#{units} energy_j=#{tool["heat_energy_j"]} remaining_j=#{source.remaining_j}"
            )

            {:reply, {:ok, next.seq}, next}

          {:error, reason} ->
            {:reply, {:error, reason}, before}
        end
    end
  end

  defp leaf_component?(state, owner),
    do: not Enum.any?(state.instances, fn {_, i} -> Map.get(i, :parent_id, {0, 0}) == owner end)

  defp dismantle_target(before, _state, _actor, %{granularity: 0}) do
    {:reply, {:error, :not_a_component}, before}
  end

  defp dismantle_target(before, state, actor, target) do
    # 拆卸只认权威射线命中的叶子 occurrence，不采用客户端选中的父级。
    if not leaf_component?(state, target.owner) do
      {:reply, {:error, :not_a_leaf_component}, before}
    else
      ids = MapSet.new([target.owner])
      cells = subtree_cells(state, ids)

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

  # ??????????????????????????????????
  defp recover_units(state, target, units) do
    row=Map.get(state.damage,Damage.key(target),target)
    case Map.fetch(row,:remaining_fuel_j) do
      :error -> units
      {:ok,remaining} ->
        capacity=Combustion.capacity_j(state.properties.materials[target.material],combustion_volume(state,target))
        floor(units*remaining/capacity)
    end
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
  defp damage_geometry(before, state, cells, macro_edit) do
    cells = MapSet.new(cells)
    epochs = if macro_edit, do: Map.new(cells, &{&1, state.seq}), else: %{}

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
            if Map.has_key?(t, :temperature_kelvin) and not phase_target?(before,t),
              do:
                sum +
                  state.properties.materials[t.material]["heat_capacity_per_macro"] *
                    Damage.volume(t.granularity) *
                    (t.temperature_kelvin - state.thermal.config["ambient_kelvin"]),
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

        %{state.thermal | active: true, sources: sources}
        |> Map.update(:removed_j, removed_j, &(&1 + removed_j))
        |> Map.update(:discarded_source_j, discarded, &(&1 + discarded))
        |> Map.update(:discarded_fuel_j,Enum.reduce(removed,0.0,fn t,sum->sum+Map.get(t,:remaining_fuel_j,0.0) end),
          &(&1+Enum.reduce(removed,0.0,fn t,sum->sum+Map.get(t,:remaining_fuel_j,0.0) end)))
      end

    {state, attachment_states} =
      attachment_damage(before, %{state | damage: damage, thermal: thermal})

    thermal = state.thermal
    metadata = %{property_states: states ++ attachment_states, epochs: epochs}
    metadata = if thermal, do: Map.put(metadata, :thermal, thermal), else: metadata
    affected = cells |> Enum.flat_map(&[&1 | VoxelRegion.Thermal.neighbors(&1)])
    work = %{state.thermal_work | geometry: Map.drop(state.thermal_work.geometry, affected)}

    state = %{
      state
      | epochs: Map.merge(state.epochs, epochs),
        thermal: thermal,
        thermal_work: work
    }

    state =
      if before.attachments == state.attachments, do: state, else: rebuild_thermal_work(state)

    {state, metadata}
  end

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
        thermal: Map.get(txn, :thermal, state.thermal),
        phase_inventory: Map.merge(state.phase_inventory, Map.get(txn, :phase_inventory, %{})),
        material_balances:
          Map.merge(state.material_balances, Map.get(txn, :material_balances, %{}))
    }
  end

  defp balance_state(state, cid, material) do
    %{
      seq: state.seq,
      material: material,
      balance: Map.get(state.material_balances, {cid, material}, 0),
      cost: @micro * @micro * @micro * state.material_units_per_micro
    }
  end

  defp settle_material(state, cid, material, delta) do
    key = {cid, material}
    balance = Map.get(state.material_balances, key, 0) + delta

    {%{state | material_balances: Map.put(state.material_balances, key, balance)},
     %{material_balances: %{key => balance}}}
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
        result = if request.action in [2,3],
          do: transfer_liquid(before, actor, request),
          else: build_material(before, actor, request)

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

  # Global system: phase energy/HP live in existing property rows. Inventory
  # carries only their extensive sums; material_balances remains quantity SSOT.
  defp phase_enabled?(s), do: s.properties != nil and Enum.any?(s.properties.materials,fn {_,m}->Phase.enabled?(m) end)
  defp phase_material?(s,m), do: s.properties != nil and Phase.enabled?(s.properties.materials[m])
  defp phase_target?(s,t), do: t.granularity == 0 and phase_material?(s,t.material)
  defp phase_volume(s,t), do: if(phase_target?(s,t),
    do: Map.get(s.liquid_units,Damage.macro(t),liquid_capacity(s))/liquid_capacity(s), else: 1.0)
  defp phase_ambient(s), do: s.thermal.config["ambient_kelvin"]

  defp phase_values(state,cells) do
    if phase_enabled?(state) do
      Enum.reduce(Enum.uniq(cells),{%{},state},fn cell,{values,s}->
        micro=cell |> Tuple.to_list() |> Enum.map(&(&1*@micro)) |> List.to_tuple()
        {target,s}=target_at(micro,s)
        value=if target && phase_target?(s,target) do
          row=property_state(s,target)
          q=Map.get(s.liquid_units,cell,liquid_capacity(s))
          {Phase.energy(row,q/liquid_capacity(s),s.properties.materials[row.material],phase_ambient(s)),
            q*row.hp/row.max_hp}
        else
          {0.0,0.0}
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

  defp transfer_phase_inventory(state,cid,cell,material,action,moved,balance) do
    if phase_material?(state,material) do
      {values,state}=phase_values(state,[cell])
      carried=inventory_phase(state,cid,material,balance)
      source=if action==2,do: Map.fetch!(values,cell),else: carried
      q=if action==2,do: Map.fetch!(state.liquid_units,cell),else: balance
      portion=Phase.scale(source,moved/q)
      sign=if action==2,do: -1,else: 1
      values=Phase.add(values,cell,Phase.scale(portion,sign))
      inventory=Phase.add(%{{cid,material}=>carried},{cid,material},Phase.scale(portion,-sign))
      state=%{state | phase_inventory: Map.merge(state.phase_inventory,inventory)}
      {state,values,inventory}
    else
      {state,%{},%{}}
    end
  end

  defp put_phase_values(state,values) do
    Enum.reduce(values,{state,[]},fn {cell,{energy,integrity}},{s,rows}->
      case Map.get(s.liquid_units,cell) do
        nil -> {s,rows}
        q ->
          micro=cell |> Tuple.to_list() |> Enum.map(&(&1*@micro)) |> List.to_tuple()
          {target,s}=target_at(micro,s)
          row=property_state(s,target)
          volume=q/liquid_capacity(s)
          maximum=s.properties.materials[row.material]["max_hp_per_macro"]*volume
          row=row |> Map.merge(%{max_hp: maximum,hp: maximum*max(0.0,min(1.0,integrity/q)),
            phase_energy_j: energy,temperature_kelvin: Phase.temperature(row.material,energy,volume,s.properties.materials),
            seq: s.seq,request_id: 0})
          s=%{s | damage: Map.put(s.damage,Damage.key(row),row)}
          # Moved thermal nodes become ordinary hot seeds, even if net quantity is unchanged.
          s=if s.thermal,do: %{s | thermal: %{s.thermal | active: true},
            thermal_work: %{s.thermal_work | hot: MapSet.put(s.thermal_work.hot,cell)}},else: s
          {s,[row|rows]}
      end
    end)
  end

  defp operate_phase(before,state,actor,request,target,tool) do
    with true <- request.action==1 and phase_target?(state,target) and state.thermal != nil,
         true <- (tool["action"]=="phase.cool" and Phase.liquid?(target.material)) or
           (tool["action"]=="phase.heat" and not Phase.liquid?(target.material)),
         fuel=tool["fuel_material_id"], units=tool["fuel_units"],
         true <- Map.get(state.material_balances,{actor.cid,fuel},0)>=units do
      cell=Damage.macro(target)
      q=Map.get(state.liquid_units,cell,liquid_capacity(state))
      {values,state}=phase_values(state,[cell])
      {energy,integrity}=Map.fetch!(values,cell)
      cool=tool["action"]=="phase.cool"
      budget=tool[if(cool,do: "cooling_energy_j",else: "heat_energy_j")]
      goal=if cool,do: 0.0,else: q/liquid_capacity(state)*state.properties.materials[target.material]["latent_heat_per_macro_j"]
      needed=max(0.0,if(cool,do: energy-goal,else: goal-energy))
      used=min(budget,needed)
      signed=if cool,do: -used,else: used
      # 预算足够时工具已抵达精确终点；避免负初焓的减加抵消把结果留在阈值下方。
      next_energy=if budget>=needed,do: goal,else: energy+signed
      thermal=state.thermal |> Map.update(:phase_supplied_j,signed,&(&1+signed))
        |> Map.update(:phase_paid_j,budget,&(&1+budget))
        |> Map.update(:phase_unused_j,budget-used,&(&1+budget-used))
      {state,settlement}=settle_material(%{state | thermal: thermal},actor.cid,fuel,-units)
      settlement=Map.merge(settlement,%{phase_values: %{cell=>{next_energy,integrity}}})
      case commit_liquid(state,%{cell=>q},settlement) do
        {:ok,next}->
          Logger.info("voxel_phase seq=#{next.seq} action=#{tool["action"]} cell=#{inspect(cell)} units=#{q} used_j=#{used} unused_j=#{budget-used}")
          {:reply,{:ok,next.seq},next}
        {:error,reason}->{:reply,{:error,reason},before}
      end
    else
      false -> {:reply,{:error,:invalid_phase_operation},before}
    end
  end

  # Pick 进度不消耗材料完整度；真实损伤仍扣减首次采掘时的基准，不能通过采回修复。
  defp damage_pick_baseline(target, hp) do
    case Map.fetch(target, :pick_baseline_hp) do
      {:ok, baseline} -> Map.put(target, :pick_baseline_hp, max(0.0, baseline - (target.hp - hp)))
      :error -> target
    end
  end

  # 固体采回携带操作前焓；Pick 用持续维护的基准，recover 用当前 HP 比例。
  defp damage_phase_solid(before,state,actor,request,target,tool) do
    material=state.properties.materials[target.material]
    cell=Damage.macro(target)
    q=Map.get(state.liquid_units,cell,liquid_capacity(state))
    {values,state}=phase_values(state,[cell])
    pick=request.action==1 and tool["action"]=="damage.impact.pick"
    target=if pick,do: Map.put_new(target,:pick_baseline_hp,target.hp),else: target
    carried=if pick and target.hp>0.0,
      do: {elem(values[cell],0),q*target.pick_baseline_hp/target.max_hp},else: values[cell]
    amount=Damage.amount(material,tool,0)*q/liquid_capacity(state)
    hp=max(0.0,target.hp-amount)
    target=if pick or request.action==2,do: target,else: damage_pick_baseline(target,hp)
    target=%{target | hp: hp,seq: state.seq+1,request_id: 0}
    state=%{state | damage: Map.put(state.damage,Damage.key(target),target)}
    values=Map.put(values,cell,{elem(values[cell],0),q*target.hp/target.max_hp})
    settlement=if request.action==2 or target.hp==0.0 do
      carried=if pick or request.action==2,do: carried,else: values[cell]
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
  defp schedule_liquid(state), do: Process.send_after(self(), :liquid_commit, max(1, round(state.properties.liquid["step_seconds"] * 1000)))
  defp liquid_inside?({x,y,z}, {{lx,ly,lz},{hx,hy,hz}}), do: x>=lx and x<hx and y>=ly and y<hy and z>=lz and z<hz

  defp enable_liquid(before, state) do
    if not liquid_enabled?(before) and liquid_enabled?(state) do
      state=adopt_liquid_sources(state)
      schedule_liquid(state)
      state
    else
      state
    end
  end

  defp adopt_liquid_sources(state) do
    # Test-only domain admission reads canonical source + replayed overlay, so an
    # emptied source cell stays empty on restart. No perpetual emitter or refill.
    {{lx,ly,lz},{hx,hy,hz}}=state.liquid_bounds
    cells=for x<-lx..(hx-1),y<-ly..(hy-1),z<-lz..(hz-1),do: {x,y,z}
    {_open,water,state}=liquid_cells(state,cells)
    changes=Map.drop(water,Map.keys(state.liquid_units))
    {:ok,state}=commit_liquid(state,changes,%{})
    state
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

  defp liquid_cells(state, cells, liquid_material \\ 21) do
    Enum.reduce(Enum.uniq(cells), {%{},%{},state}, fn cell,{open,water,s} ->
      region=region_of(cell)
      if needs_source?(s,{0,region}), do: :ok=s.source.ensure(s.source_state,0,region)
      {:ok,{material,_},s}=cell_value(s,0,cell)
      available=(material==0 or material==liquid_material) and not Map.has_key?(s.refined,cell)
      # Legacy Water21 without a suffix is a full macro, not an empty cell.
      water=if material == liquid_material, do: Map.put(water,cell,Map.get(s.liquid_units,cell,liquid_capacity(s))), else: water
      {Map.put(open,cell,available),water,s}
    end)
  end

  defp transfer_liquid(before, actor, request) do
    expected=if request.action==2,do: "liquid.scoop",else: "liquid.pour"
    with true <- liquid_enabled?(before),
         true <- Phase.liquid?(request.material) and request.material in before.production_materials,
         true <- liquid_inside?(request.coord,before.liquid_bounds),
         {:ok,tool} <- Map.fetch(before.properties.tools,request.tool_id),
         true <- tool["action"] == expected,
         :ok <- build_reach(actor.eye,request.coord,tool["range_macro"]),
         :ok <- liquid_sight(before,actor.eye,request.coord),
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
        {state,carried,inventory}=transfer_phase_inventory(state,actor.cid,request.coord,request.material,
          request.action,transfer.transferred_units,balance)
        {state,settlement}=settle_material(state,actor.cid,request.material,transfer.balance-balance)
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
      at=fn micro,s ->
        case target_at(micro,s) do
          {%{material: material},s} when material in [21,22]->{nil,s}
          {%{granularity: 0}=target,s}->
            if phase_target?(s,target) do
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
    # Authored new water starts at the configured ambient, once only. Ordinary
    # movement/pour always supplies the actual transported extensive values.
    values=if phase_enabled?(state) do
      Enum.reduce(changes,values,fn {cell,q},v->
        {:ok,{old,_},_}=cell_value(state,0,cell)
        if q>0 and old==0 and not Map.has_key?(supplied_values,cell) do
          e=Phase.energy(%{material: liquid_material},q/liquid_capacity(state),state.properties.materials[liquid_material],phase_ambient(state))
          Map.put(v,cell,{e,q*1.0})
        else
          v
        end
      end)
    else
      values
    end
    values=Map.merge(values,supplied_values)
    edits=Enum.map(changes,fn {cell,q}->
      {:ok,{old,_},_}=cell_value(state,0,cell)
      old=if phase_material?(state,old),do: old,else: liquid_material
      material=cond do
        q==0 -> 0
        phase_material?(state,old) -> Phase.material(old,elem(Map.fetch!(values,cell),0),q/liquid_capacity(state),state.properties.materials)
        true -> liquid_material
      end
      {cell,material}
    end)
    settlement=Map.merge(settlement,%{liquid_changes: changes,phase_values: values})
    apply_batch(state,edits++extra_edits,false,settlement,owners,attachments)
  end

  defp advance_liquid(state) do
    Enum.reduce([21,22],state,&advance_liquid(&2,&1))
  end

  defp advance_liquid(state,material) do
    # Two stages need the downward cell and the horizontal neighbors of both levels.
    cells=for {x,y,z} <- Map.keys(state.liquid_units), dy <- [0,-1],
      {dx,dz} <- [{0,0},{-1,0},{1,0},{0,-1},{0,1}],
      cell={x+dx,y+dy,z+dz}, liquid_inside?(cell,state.liquid_bounds), do: cell
    {open,water,state}=liquid_cells(state,cells,material)
    config=state.properties.liquid
    {changes,stages}=Liquid.step_transfers(water,state.liquid_bounds,liquid_capacity(state),
      config["gravity_units_per_step"],config["side_units_per_step"],&Map.get(open,&1,false))
    {values,state}=phase_values(state,Map.keys(water))
    values=if phase_enabled?(state),do: Enum.reduce(stages,values,fn {q,flows},v->Phase.transport(v,q,flows) end),else: %{}
    # Equal incoming/outgoing quantity can still transport heat and integrity.
    affected=if phase_enabled?(state),do: for({_q,flows}<-stages,{a,b,_}<-flows,c<-[a,b],do: c),else: []
    changes=Enum.reduce(affected,changes,fn c,m->Map.put_new(m,c,Map.get(water,c,0)) end)
    case commit_liquid(state,changes,%{phase_values: Map.take(values,Map.keys(changes)),liquid_material: material}) do
      {:ok,next}->next
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
                   balance_state(before, actor.cid, request.material).balance >=
                     @micro * @micro * @micro * before.material_units_per_micro,
                   do: :ok,
                   else: {:error, :insufficient_material}
                 ),
               :ok <- if(phase_material?(before,request.material) and
                   elem(inventory_phase(before,actor.cid,request.material,balance_state(before,actor.cid,request.material).balance),1)<=0,
                 do: {:error,:broken_material},else: :ok),
               false <- Map.has_key?(before.refined, request.coord),
               {:ok, {0, _}, state} <- cell_value(before, 0, request.coord) do
            {state, settlement} =
              settle_material(
                state,
                actor.cid,
                request.material,
                -@micro * @micro * @micro * state.material_units_per_micro
              )

            if phase_material?(state,request.material) do
              cost=liquid_capacity(state)
              balance=balance_state(before,actor.cid,request.material).balance
              carried=inventory_phase(before,actor.cid,request.material,balance)
              portion=Phase.scale(carried,cost/balance)
              inventory=Phase.add(%{{actor.cid,request.material}=>carried},{actor.cid,request.material},Phase.scale(portion,-1))
              state=%{state | phase_inventory: Map.merge(state.phase_inventory,inventory)}
              # Inventory Ice stays solid; any later thermal phase completion is ordinary simulation.
              apply_batch(state,[{request.coord,request.material}],false,Map.merge(settlement,%{
                liquid_changes: %{request.coord=>cost},phase_values: %{request.coord=>portion},phase_inventory: inventory}))
            else
              apply_batch(state, [{request.coord, request.material}], false, settlement)
            end
          else
            :error -> {:error, :invalid_tool}
            true -> {:error, :occupied}
            {:ok, _, _} -> {:error, :occupied}
            {:error, reason} -> {:error, reason}
          end
  end

  defp build_reach(eye, coord, range) do
    squared =
      Enum.zip(Tuple.to_list(eye), Tuple.to_list(coord))
      |> Enum.reduce(0.0, fn {a, b}, sum -> sum + (a - b - 0.5) * (a - b - 0.5) end)

    if squared <= range * range, do: :ok, else: {:error, :out_of_reach}
  end

  # 参数只改变下一次计算；实例温度、HP、余燃料、源预算与相变焓不改写。
  defp compatible_parameters?(old, new) do
    material_fields = ~w(display_name tags heat_capacity_per_macro thermal_conductivity heat_resistance_kelvin ignition_kelvin fuel_energy_per_macro_j burn_power_per_macro_w electrical_conductivity phase_peer_material_id phase_transition_kelvin latent_heat_per_macro_j)
    tool_fields = ~w(display_name interval_seconds fuel_units heat_energy_j heat_power_w cooling_energy_j circuit_energy_j)
    phase_fields = ~w(phase_peer_material_id phase_transition_kelvin latent_heat_per_macro_j heat_capacity_per_macro max_hp_per_macro)

    old.attachments == new.attachments and old.liquid == new.liquid and
      Enum.all?(old.materials, fn {id, material} ->
        case Map.fetch(new.materials, id) do
          {:ok, next} ->
            Map.drop(material, material_fields) == Map.drop(next, material_fields) and
              (not Phase.enabled?(material) or Map.take(material, phase_fields) == Map.take(next, phase_fields))
          :error -> false
        end
      end) and
      Enum.all?(old.tools, fn {id, tool} ->
        case Map.fetch(new.tools, id) do
          {:ok, next} -> Map.drop(tool, tool_fields) == Map.drop(next, tool_fields)
          :error -> false
        end
      end)
  end

  defp parameter_thermal_reference(%{thermal: nil}, _), do: nil
  defp parameter_thermal_reference(state, catalog) do
    ambient = state.thermal.config["ambient_kelvin"]
    rebase = Enum.reduce(state.damage, 0.0, fn {_, row}, sum ->
      old = state.properties.materials[row.material]
      if row.granularity in [0, 1, 4] and Map.has_key?(row, :temperature_kelvin) and not Phase.enabled?(old) do
        volume = if row.granularity == 4,
          do: VoxelRegion.ThermalAttachments.volume(Attachments.slot(row), state.properties),
          else: Damage.volume(row.granularity)
        next=catalog.materials[row.material]
        previous=volume*Map.get(old,"heat_capacity_per_macro",0.0)*(row.temperature_kelvin-ambient)
        current=if row.granularity==0 and Phase.enabled?(next),
          do: Phase.energy(row,volume,next,ambient),
          else: volume*next["heat_capacity_per_macro"]*(row.temperature_kelvin-ambient)
        sum + current - previous
      else
        sum
      end
    end)
    Map.update(state.thermal, :parameter_rebase_j, rebase, &(&1 + rebase))
  end

  # 复用既有同步落盘后广播边界；失败时目录与所有实例状态一起保持旧值。
  defp publish_property_catalog(state, catalog, thermal) do
    if (map_size(state.damage) == 0 and thermal == state.thermal) or state.properties.digest == catalog.digest do
      {:reply, :ok, enable_liquid(state, rebuild_thermal_work(%{state | properties: catalog}))}
    else
      rows = for {_, t} <- state.damage,
        do: %{t | digest: catalog.digest, seq: state.seq + 1, request_id: 0}
      next = %{state | properties: catalog, thermal: thermal, seq: state.seq + 1,
        damage: Map.new(rows, &{Damage.key(&1), &1})} |> rebuild_thermal_work()
      txn = %{seq: next.seq, entries: [], coarse: [], property_states: rows, thermal: thermal}
      case append_log(next, txn) do
        :ok ->
          next = %{next | entries: Map.put(next.entries, next.seq, txn)}
          fanout(next, txn)
          fanout_canonical(next, txn, [], [], state)
          Logger.info("voxel_parameter_publication seq=#{next.seq} old=#{Base.encode16(state.properties.digest, case: :lower)} new=#{Base.encode16(catalog.digest, case: :lower)} rebase_j=#{if thermal, do: Map.get(thermal, :parameter_rebase_j, 0.0), else: 0.0}")
          {:reply, :ok, enable_liquid(state, next)}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    end
  end

  defp validate_damage_catalog(state) do
    if map_size(state.damage) > 0 do
      true =
        state.properties != nil and
          Enum.all?(state.damage, fn {_, t} -> t.digest == state.properties.digest end)
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

    dirty = Enum.map(Attachments.macros(slots), &{0, &1})
    {:ok, coarse, state, _} = reduce_batch(state, dirty, 1, [], 0)
    {coarse_txn, state} = select_transaction(state, coarse)
    keys = region_keys(dirty)

    {state, structure_keys, structure_cells} =
      refresh_structure(state, Enum.map(dirty, &elem(&1, 1)))

    {entries, state} = region_afterimages(state, keys, before.payloads)

    entries = entries ++ structure_entries(state, structure_cells)

    keys = Enum.uniq(keys ++ structure_keys)
    txn = Map.merge(%{coarse_txn | entries: entries ++ coarse_txn.entries}, settlement)

    case append_log(state, txn) do
      :ok ->
        state = %{state | entries: Map.put(state.entries, state.seq, txn)}
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
