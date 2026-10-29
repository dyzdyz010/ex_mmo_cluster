defmodule VoxelRegion.Bench.PagingEquiv do
  @moduledoc """
  只测试：分页迁移的同切点只读采集与既有发布等待。

  capture_regions/3 经正常 serve，在 prepare pin 内的精确完成回合计算固定页摘要；
  不把 World state 送出 owner，不冻结物理。产物只证明声明区域，不能当全世界 Q5。
  capture_static/3 按实际初始化完成事实选定一次X，H/A的发布闸保留该切点，B必须恰在已发布前缀；
  完整页目录来自自然单元或持久目录，身份目录独立读取 canonical 索引，不从属性结果反推。
  H 在冻结的确定序前源码运行原 Observation，A/B 在当前源码运行，均不复制求和算法。
  """
  import Bitwise
  alias MmoContracts.Voxel.{Codec, Payload}
  alias VoxelRegion.{RefinedSlots, World}
  alias VoxelRegion.World.{Canonical, Observation, Pages}

  @chunk_fields [:overlay, :refined, :attachments, :liquid_units, :macro_owners,
    :damage, :epochs, :placed_by, :liquid_active, :sources]
  @global_maps [:material_balances, :caster_energy, :material_supplies, :craft_ledger,
    :food_ledger, :food_receipts, :beacons, :beacon_attunements, :phase_inventory]
  @scalars [:seq, :attachment_serial, :material_units_per_micro, :interaction_history, :interaction_floor]
  @timeout 60_000

  @doc "旧全世界入口尚无安全完整资格；在任何 World 调用之前明确拒绝。"
  def capture(_path, _quiet_s) do
    raise ArgumentError, "full_world_q5_capture_unavailable: first_publication_cut_and_independent_identity_directory_required; use capture_regions/3 only for an explicit finite scope"
  end

  @doc "静态迁移样本的唯一资格构造：等待实际初始化完成，至多从C0转到一次真实compact切点X。"
  def capture_static(path, world, side) when side in ["H", "A", "B"] do
    world = GenServer.whereis(world) || raise("audit_owner_not_running")
    if side == "B" do
      facts = await_initialization(world, System.monotonic_time(:millisecond) + 600_000)
      capture_full(path, world, side, %{complete: true, initial_cut: facts.seq, selected_cut: facts.seq, readiness: facts})
    else
      gate = VoxelRegion.Bench.FirstPublication
      initial = gate.await_held(3_600_000)
      facts = try do
        observed = await_initialization(world, System.monotonic_time(:millisecond) + 600_000)
        if observed.content_version != initial.content_version or observed.seq < initial.seq,
          do: raise("audit_initialization_identity_changed")
        observed
      catch
        kind, reason ->
          gate.release(initial.content_version, initial.seq)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
      qualification = %{complete: true, initial_cut: initial.seq, selected_cut: facts.seq, readiness: facts}
      if facts.seq == initial.seq do
        capture_full(path, world, side, qualification)
      else
        :ok = gate.release(initial.content_version, initial.seq)
        published = await_published(initial.seq, 1_800, world) |> Jason.decode!()
        if published["published_seq"] != initial.seq or published["seq"] != facts.seq,
          do: raise("audit_initialization_changed_before_compact")
        :ok = gate.arm(initial.content_version, facts.seq, initial.seq)
        # 同一采集者持有请求：capture释放发布闸后才开始等完成，不能另挂一个300秒caller。
        compact = :gen_server.send_request(world, :compact)
        result = try do
          capture_full(path, world, side, qualification)
        catch
          kind, reason ->
            :gen_server.receive_response(compact, 0)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end
        case :gen_server.receive_response(compact, 60_000) do
          {:reply, :ok} -> result
          response -> raise("audit_compact_completion: #{inspect(response)}")
        end
      end
    end
  end

  # 等完成条件，不累计quiet时间，也不在采集失败后再挑另一份样本。
  defp await_initialization(world, deadline) do
    facts = sampled(world, :initialization)
    cond do
      facts.complete -> facts
      facts.io_failed -> raise "audit_initialization_io_failed"
      System.monotonic_time(:millisecond) >= deadline -> raise "audit_initialization_incomplete"
      true ->
        Process.sleep(50)
        await_initialization(world, deadline)
    end
  end

  @doc "完整采集：H为历史源码、A为当前选中切点发布前，B为同版本该切点冷恢复；任一漂移立即失败。"
  def capture_full(path, world, side, initialization \\ nil) when side in ["H", "A", "B"] do
    if File.exists?(path), do: raise(ArgumentError, "audit_output_exists")
    world = GenServer.whereis(world) || raise("audit_owner_not_running")
    held = if side in ["H", "A"], do: VoxelRegion.Bench.FirstPublication.await_held(3_600_000)

    try do
      before = sampled(world, {:directory, side})
      if held && (held.seq != before.seq or held.content_version != before.content_version),
        do: raise("audit_first_publication_cut_mismatch")
      if initialization && initialization.selected_cut != before.seq,
        do: raise("audit_initialization_changed_before_capture")
      pages = Map.new(before.regions, fn key ->
        page = sampled(world, {:page, key, before.content_version})
        same_cut!(before, page)
        {region_key(key), page}
      end)
      after_capture = sampled(world, {:full_fence, side})
      same_cut!(before, after_capture)
      if before.global_digests != after_capture.global_digests, do: raise("audit_global_state_changed")
      expected_ids = Enum.flat_map(Map.values(pages), & &1.q5.expected_identities) |> Enum.sort()
      properties = Enum.flat_map(Map.values(pages), & &1.q5.properties) |> Enum.sort_by(& &1.identity)
      actual_ids = Enum.map(properties, & &1.identity)
      if expected_ids != actual_ids or length(expected_ids) != MapSet.size(MapSet.new(expected_ids)),
        do: raise("audit_property_identity_coverage_incomplete")
      if before.expected_identities != nil and expected_ids != before.expected_identities,
        do: raise("audit_owner_identity_directory_incomplete")
      fields = @chunk_fields ++ [:region_bases, :instances, :attachment_owners]
      digests = Map.new(fields, fn field ->
        {field, merge_digests(Enum.map(Map.values(pages), &Map.fetch!(&1.digests, field)))}
      end) |> Map.merge(before.global_digests)
      result = %{seq: before.seq, content_version: before.content_version, published: before.published,
        coverage: %{schema: "paging-live-audit-v1", side: side,
          start_seq: before.seq, end_seq: after_capture.seq,
          published_start: before.published, published_end: after_capture.published,
          expected_regions: Enum.map(before.regions, &region_key/1), expected_identities: expected_ids,
          region_directory: before.directory_source, identity_directory: "canonical_inputs_by_home",
          first_publication_cut: if(initialization, do: initialization.initial_cut, else: if(held, do: held.seq)),
          capture_cut: if(held, do: held.seq, else: before.published), initialization: initialization,
          world_pid: inspect(world)},
        digests: digests, reads: Map.new(pages, fn {key, page} -> {key, page.payload_digest} end),
        payload_sequences: Map.new(pages, fn {key, page} -> {key, page.payload_seq} end),
        q5: %{properties: properties,
          damage_without_max_hp: merge_digests(Enum.map(Map.values(pages), & &1.q5.damage_without_max_hp))},
        runtime: %{otp: to_string(:erlang.system_info(:otp_release)), erts: to_string(:erlang.system_info(:version)),
          elixir: System.version(), modules: module_identity(side)}}
      File.write!(path, Jason.encode!(result), [:exclusive])
      Jason.encode!(%{seq: before.seq, content_version: before.content_version, published: before.published,
        regions: map_size(pages), identities: length(properties), side: side})
    after
      # 即使采集失败也解除本次闸；失败产物不会写成成功，随后编排正常停止自己的节点。
      if held, do: VoxelRegion.Bench.FirstPublication.release(held.content_version, held.seq)
    end
  end

  @doc "读取声明的有限完整 XYZ 区域；首尾和逐页同 seq、同全局摘要且范围完整后才写成功产物。"
  def capture_regions(path, world, regions) do
    if regions == [] or not is_list(regions), do: raise(ArgumentError, "empty_audit_scope")
    if length(regions) != MapSet.size(MapSet.new(regions)), do: raise(ArgumentError, "duplicate_audit_region")
    if File.exists?(path), do: raise(ArgumentError, "audit_output_exists")
    world = GenServer.whereis(world) || raise("audit_owner_not_running")
    regions = Enum.sort(regions)
    before = sampled(world, :fence)
    pages = Map.new(regions, fn key ->
      page = sampled(world, {:page, key, before.content_version})
      same_cut!(before, page)
      {region_key(key), page}
    end)
    after_capture = sampled(world, :fence)
    same_cut!(before, after_capture)
    if before.global_digests != after_capture.global_digests, do: raise("audit_global_state_changed")
    expected = Enum.map(regions, &region_key/1)
    if Enum.sort(Map.keys(pages)) != Enum.sort(expected), do: raise("audit_region_coverage_incomplete")
    result = %{schema: "paging-region-audit-v1", content_version: before.content_version,
      coverage: %{scope: "explicit_regions_only", expected_regions: expected,
        start_seq: before.seq, end_seq: after_capture.seq,
        published_start: before.published, published_end: after_capture.published},
      global_digests: before.global_digests, pages: pages}
    File.write!(path, Jason.encode!(result), [:exclusive])
    Jason.encode!(Map.drop(result, [:pages, :global_digests]))
  end

  defp sampled(world, mode) do
    pid = world
    id = make_ref()
    monitor = Process.monitor(pid)
    debug = %{id: id, caller: self(), mode: mode, from: nil}
    try do
      :ok = :sys.install(pid, {id, &__MODULE__.audit_hook/3, debug}, @timeout)
      case mode do
        :fence -> World.seq(world)
        :initialization -> World.liquid_activity(world)
        {:directory, _side} -> World.seq(world)
        {:full_fence, _side} -> World.seq(world)
        {:page, {level, region}, cv} ->
          request = Codec.encode_request(cv, [%{level: level, region: region, have_seq: 0, have_hash: 0}])
            |> IO.iodata_to_binary()
          case World.serve(world, request) do
            {:ok, reply} ->
              case Codec.decode_reply(IO.iodata_to_binary(reply)) do
                {:ok, ^cv, [{:payload, ^level, ^region, _bytes}]} -> :ok
                _ -> raise "audit_payload_identity_mismatch"
              end
            {:error, _} -> raise "audit_serve_failed"
          end
      end
      receive do
        {^id, {:ok, summary}} -> summary
        {^id, {:error, reason}} -> raise "audit_hook_projection_failed: #{reason}"
        {:DOWN, ^monitor, :process, ^pid, _} -> raise "audit_owner_exited"
      after
        @timeout -> raise "audit_completion_missing"
      end
    after
      # 只删除本次钩子；World退出时没有可留下的hook，不能清掉其他诊断。
      if Process.alive?(pid) do
        try do
          :sys.remove(pid, id, @timeout)
        catch
          :exit, {:noproc, _} -> :ok
          :exit, {:normal, _} -> :ok
        end
      end
      Process.demonitor(monitor, [:flush])
    end
  end

  @doc false
  def audit_hook(debug, {:in, {:"$gen_call", {caller, _} = from,
        {:page_request, request, message}}}, _name) when caller == debug.caller do
    if selected?(debug.mode, message), do: %{debug | from: {from, request}}, else: debug
  end
  # 历史 18f6cb4c 的正式入口尚无 page_request 信封，仍按同一 caller 与完整 From 对应输出。
  def audit_hook(debug, {:in, {:"$gen_call", {caller, _} = from, message}}, _name)
      when caller == debug.caller do
    if selected?(debug.mode, message), do: %{debug | from: {from, nil}}, else: debug
  end
  def audit_hook(%{from: {from, _request}} = debug, {:out, reply, from, state}, _name) do
    result = try do
      {:ok, projection(state, debug.mode, reply)}
    rescue
      error -> {:error, Atom.to_string(error.__struct__)}
    catch
      kind, _reason -> {:error, Atom.to_string(kind)}
    end
    send(debug.caller, {debug.id, result})
    :done
  end
  def audit_hook(debug, _event, _name), do: debug

  defp selected?(:fence, :seq), do: true
  defp selected?(:initialization, :liquid_activity), do: true
  defp selected?({:directory, _side}, :seq), do: true
  defp selected?({:full_fence, _side}, :seq), do: true
  defp selected?({:page, {level, region}, cv}, {:serve_item, cv, %{level: level, region: region}}), do: true
  defp selected?(_, _), do: false

  defp identity(state) do
    if state.thermal_run != nil, do: raise("audit_thermal_commit_in_progress")
    %{seq: state.seq, content_version: state.cv, published: state.page_store.published}
  end
  defp projection(state, :initialization, liquid) do
    io = get_in(state, [:page_load, :sim])
    facts = %{seq: state.seq, content_version: state.cv,
      liquid_active_cells: liquid.active_cells, liquid_scheduled: liquid.scheduled,
      liquid_due_ms: Map.get(state, :liquid_due, :legacy_timer_only),
      thermal_active: state.thermal != nil and state.thermal.active,
      thermal_due_ms: state.thermal_due, thermal_scheduled: state.thermal_timer != nil,
      thermal_running: state.thermal_run != nil, native_pending: state.thermal_work.domain.pending,
      projectile_scheduled: state.projectile_timer != nil, projectile_pending: state.projectile_task != nil,
      casts: map_size(state.pending_casts), bodies: map_size(state.bodies),
      semblances: map_size(if(state.thermal, do: Map.get(state.thermal, :semblances, %{}), else: %{})),
      io_failed: match?(%{status: :failed}, io), io_waiting: io != nil}
    complete = facts.liquid_active_cells == 0 and not facts.liquid_scheduled and
      facts.liquid_due_ms in [nil, :legacy_timer_only] and not facts.thermal_active and
      facts.thermal_due_ms == nil and not facts.thermal_scheduled and not facts.thermal_running and
      not facts.native_pending and not facts.projectile_scheduled and not facts.projectile_pending and
      facts.casts == 0 and facts.bodies == 0 and facts.semblances == 0 and not facts.io_waiting
    Map.put(facts, :complete, complete)
  end
  defp projection(state, :fence, seq) when seq == state.seq do
    thermal = state.thermal || %{}
    digests = Map.new(@global_maps, &{&1, digest(Map.fetch!(state, &1))})
      |> Map.merge(Map.new(@scalars, &{&1, digest([{&1, Map.fetch!(state, &1)}])}))
      |> Map.merge(%{thermal: digest(Map.drop(thermal, [:config, :sources])),
        protection: digest(state.protection.regions)})
    Map.put(identity(state), :global_digests, digests)
  end
  defp projection(state, {:full_fence, side}, seq) when seq == state.seq do
    eligible_cut!(state, side)
    projection(state, :fence, seq)
  end
  defp projection(state, {:directory, side}, seq) when seq == state.seq do
    eligible_cut!(state, side)
    published_regions = if side != "H" and state.page_store.published != nil do
      {backend, handle} = state.log
      # 冻结的历史18f使用M2a格式、没有fragment段；当前格式沿Pages唯一段定义。
      fragments = if side == "H", do: [], else: Pages.fragment_codes()
      backend.page_keys(handle) |> Enum.map(fn {level, region, segment} ->
        if segment in fragments, do: {level, Pages.coarse_region(level, region)}, else: {level, region}
      end)
    else
      []
    end
    {regions, source} = if side == "B" do
      {published_regions, "published_page_keys"}
    else
      # C0发布后P1可退休冷页；X的完整目录同时包含已发布来源、当前自然单元和本cut的删除单元。
      current = Enum.flat_map(Pages.units(state), &unit_region/1)
      selected = Enum.flat_map(state.page_store.cut.units, &unit_region/1)
      {published_regions ++ current ++ selected, "published_and_selected_cut_units"}
    end
    projection(state, :fence, seq)
    |> Map.merge(%{regions: regions |> Enum.uniq() |> Enum.sort(), directory_source: source,
      expected_identities: if(side == "H" or state.page_store.published == nil, do: expected_identities(state, :all), else: nil)})
  end
  defp projection(state, {:page, {level, region} = key, cv}, {:ok, {:payload, level, region, bytes}})
       when cv == state.cv do
    {:ok, header} = Codec.decode_payload_header(bytes)
    if header.seq > state.seq, do: raise("audit_payload_from_future")
    identity(state)
    |> Map.merge(%{digests: page_digests(state, key), q5: q5(state, key),
      payload_seq: header.seq,
      payload_digest: hex(:crypto.hash(:md5, Codec.stamp_payload_seq(bytes, 0)))})
  end

  defp same_cut!(before, current) do
    if before.seq != current.seq, do: raise("audit_sequence_changed")
    if before.content_version != current.content_version, do: raise("audit_content_version_changed")
    if before.published != current.published, do: raise("audit_publication_changed")
  end

  defp eligible_cut!(state, side) when side in ["H", "A"] do
    if (state.page_store.published != nil and state.page_store.published >= state.seq) or
         state.page_store.cut == nil or state.page_store.cut.seq != state.seq,
      do: raise("audit_not_before_selected_cut_publication")
  end
  defp eligible_cut!(state, "B") do
    if state.page_store.published != state.seq or state.page_store.cut != nil,
      do: raise("audit_not_at_exact_published_cut")
  end
  defp unit_region({:chunk, _, {x, y, z}}),
    do: [{0, {Integer.floor_div(x, 4), Integer.floor_div(y, 4), Integer.floor_div(z, 4)}}]
  defp unit_region({:page, _, key}), do: [key]
  defp unit_region({:fragment, _, {level, page}}), do: [{level, Pages.coarse_region(level, page)}]
  defp unit_region({:locator, _}), do: []

  defp module_identity(side) do
    modules = [World, Canonical, Observation, Pages, VoxelRegion.World.Payloads]
    modules = if side == "H", do: modules, else: [RefinedSlots | modules]
    Map.new(modules, &{Atom.to_string(&1), hex(&1.module_info(:md5))})
  end

  # 逐个既有自然单元归约，只在该页计一次；不累计整张驻留表。
  defp page_digests(state, {0, {px, py, pz}} = key) do
    chunks = for x <- 0..3, y <- 0..3, z <- 0..3, do: {px * 4 + x, py * 4 + y, pz * 4 + z}
    home = Pages.extract(state, {:page, :identity, key})
    digests = Map.new(@chunk_fields, fn field ->
      entries = Stream.flat_map(chunks, &Pages.extract(state, {:chunk, field, &1}))
      entries = case field do
        :overlay -> Stream.map(entries, fn {cell, value} -> {{0, cell}, value} end)
        :refined -> Stream.map(entries, fn {cell, value} -> {cell, legacy_slots(value)} end)
        :liquid_active -> Stream.map(entries, &{&1, true})
        :damage -> Stream.concat(entries, home.damage)
        _ -> entries
      end
      {field, digest(entries)}
    end)
    Map.merge(digests, %{region_bases: base_digest(state, key), instances: digest(home.instances),
      attachment_owners: digest(home.attachment_owners)})
  end
  defp page_digests(state, key) do
    Map.new(@chunk_fields ++ [:region_bases, :instances, :attachment_owners], &{&1, digest([])})
    |> Map.put(:region_bases, base_digest(state, key))
    |> Map.put(:overlay, digest(Stream.map(Pages.extract(state, {:page, :coarse_overlay, key}),
      fn {cell, value} -> {{elem(key, 0), cell}, value} end)))
  end
  defp base_digest(state, key) do
    case Pages.extract(state, {:page, :base, key}) do
      nil -> digest([])
      base -> digest([{key, Payload.encode(base, %{}, 0, state.cv)}])
    end
  end

  # 完整整件算法仍在Observation；本页只拥有home身份，无主附件按其锚点页计。
  defp q5(state, {0, region} = key) do
    home = Pages.extract(state, {:page, :identity, key})
    rows = Observation.component_observations(state, nil, Map.keys(home.instances)) ++
      (Observation.attachment_observations(state, nil)
       |> Enum.filter(fn row ->
         Map.get(state.pages.aid_home, row.incarnation, Canonical.region_of(VoxelRegion.Damage.macro(row))) == region
       end))
    properties = Enum.map(rows, fn row ->
      identity = if row.granularity == 2, do: %{granularity: 2, owner: row.owner},
        else: %{granularity: 3, incarnation: row.incarnation}
      row = row |> Observation.public_property() |> Map.update!(:observation_cells, &Enum.sort/1)
      entry = %{identity: json_value(identity), property: json_value(row)}
      if row.granularity == 2,
        do: Map.put(entry, :representative_witness, representative_witness(state, row.micro)), else: entry
    end) |> Enum.sort_by(& &1.identity)
    projected = Enum.map(home.damage, fn {key, row} ->
      {key, if(row.granularity == 2, do: Map.delete(row, :max_hp), else: row)}
    end)
    chunks = for x <- 0..3, y <- 0..3, z <- 0..3, do: {elem(region, 0) * 4 + x, elem(region, 1) * 4 + y, elem(region, 2) * 4 + z}
    local_damage = Stream.flat_map(chunks, &Pages.extract(state, {:chunk, :damage, &1}))
    %{properties: properties, expected_identities: expected_identities(state, region),
      home_damage_without_max_hp: digest(projected), damage_without_max_hp: digest(Stream.concat(local_damage, projected))}
  end
  defp q5(_state, _key), do: %{properties: [], expected_identities: [], home_damage_without_max_hp: digest([]), damage_without_max_hp: digest([])}

  # 测试见证从实占索引和已接纳目录独立取值，不从Observation行复制物性或选点规则。
  defp representative_witness(state, micro) do
    {target, _state} = Canonical.target_at(micro, state)
    defense = if target, do: Map.fetch!(state.properties.materials, target.material)["defense"]
    json_value(%{schema: :canonical_g2_point_v1, seq: state.seq, content_version: state.cv,
      target: target, catalog_defense: defense, property_digest: state.properties.digest})
  end

  # 目录来自实际有槽的 owner／aid，独立于 Observation 产生的行；装配父身份不冒充一个 g2 叶子。
  defp expected_identities(state, region) do
    g2 = for owner <- Map.keys(state.refined_owners),
      region == :all or Map.fetch!(state.pages.instance_home, owner) == region,
      do: %{granularity: 2, owner: Tuple.to_list(owner)}
    g3 = for {slot, {aid, _} = value} <- state.attachments,
      region == :all or Map.get_lazy(state.pages.aid_home, aid, fn ->
        Canonical.region_of(VoxelRegion.Damage.macro(VoxelRegion.Attachments.identity(slot, value)))
      end) == region, uniq: true, do: %{granularity: 3, incarnation: aid}
    Enum.sort(g2 ++ g3)
  end
  defp legacy_slots(value) when is_struct(value, RefinedSlots), do: RefinedSlots.to_map(value)
  defp legacy_slots(value) when is_map(value) and not is_struct(value), do: value

  defp merge_digests(values) do
    {count, sum} = Enum.reduce(values, {0, 0}, fn value, {count, sum} ->
      [n, hash] = String.split(value, ":")
      {count + String.to_integer(n), rem(sum + String.to_integer(hash, 16), 1 <<< 128)}
    end)
    "#{count}:#{Integer.to_string(sum, 16)}"
  end
  defp region_key({level, region}), do: Enum.join([level | Tuple.to_list(region)], ",")

  @doc "等到已发布前缀覆盖 seq，保留现有迁移预备调用。"
  def await_published(seq, timeout_s, world \\ World) do
    wait(seq, System.monotonic_time(:second) + timeout_s, world)
  end
  defp wait(seq, deadline, world) do
    stats = World.stats(world)
    cond do
      stats.published_seq != nil and stats.published_seq >= seq ->
        Jason.encode!(Map.take(stats, [:published_seq, :persist_level, :suffix_txns, :dirty_units, :checkpoints])
          |> Map.put(:seq, World.seq(world)))
      System.monotonic_time(:second) > deadline ->
        raise "published_seq #{inspect(stats.published_seq)} did not reach #{seq}"
      true ->
        Process.sleep(1_000)
        wait(seq, deadline, world)
    end
  end

  defp json_value(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_value()
  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, json_value(v)} end)
  defp json_value(value) when is_binary(value), do: Base.encode16(value, case: :lower)
  defp json_value(value), do: value

  # 原算法：每项确定性ETF的MD5按2^128求和，摘要顺序无关，另记项数。
  defp digest(entries) do
    {n, sum} = Enum.reduce(entries, {0, 0}, fn kv, {n, sum} ->
      <<h::128>> = :crypto.hash(:md5, :erlang.term_to_binary(kv, [:deterministic]))
      {n + 1, rem(sum + h, 1 <<< 128)}
    end)
    "#{n}:#{Integer.to_string(sum, 16)}"
  end
  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
end

defmodule VoxelRegion.Bench.FirstPublication do
  @moduledoc "只测试：初始C0及必要的一次静态X发布闸；只保存发布者与切点标量，不保存World或页正文。"
  use GenServer

  @doc "M0 在 World 前启动；File 小集成可显式传入原日志后端。"
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @doc "取得本次委托后端，数据语义仍归原后端。"
  def backend, do: GenServer.call(__MODULE__, :backend)
  @doc "等待真实 PageWriter 到达首次 publish，返回其实际切点。"
  def await_held(timeout), do: unwrap(GenServer.call(__MODULE__, :await_held, timeout))
  @doc "原发布者在此等待；超时或 controller 失败以错误结束真实写回尝试。"
  def hold(cv, seq, published \\ nil), do: unwrap(GenServer.call(__MODULE__, {:hold, cv, seq, published}, :infinity))
  @doc "自然初始化推进后，只允许一次把闸明确绑定到正常compact将发布的X。"
  def arm(cv, seq, previous), do: unwrap(GenServer.call(__MODULE__, {:arm, cv, seq, previous}))
  @doc "只释放同一内容身份与切点；完成/失败清理可重复调用而不新增发布。"
  def release(cv, seq), do: unwrap(GenServer.call(__MODULE__, {:release, cv, seq}))
  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: raise("first_publication_gate: #{reason}")

  @impl true
  def init(opts) do
    timeout = Keyword.fetch!(opts, :timeout_ms)
    true = is_integer(timeout) and timeout > 0
    {:ok, %{backend: Keyword.get(opts, :backend, VoxelRegion.OverlayLog.Db), timeout: timeout,
      held: nil, waiter: nil, released: nil, target: :first, rearmed: false}}
  end
  @impl true
  def handle_call(:backend, _from, state), do: {:reply, state.backend, state}
  def handle_call(:await_held, _from, %{held: %{identity: identity}} = state),
    do: {:reply, {:ok, identity}, state}
  def handle_call(:await_held, from, %{held: nil, waiter: nil, target: target} = state) when target != nil,
    do: {:noreply, %{state | waiter: {from, Process.monitor(elem(from, 0))}}}
  def handle_call(:await_held, _from, state), do: {:reply, {:error, :invalid_waiter_lifecycle}, state}
  def handle_call({:arm, cv, seq, previous}, _from,
        %{held: nil, target: nil, rearmed: false, released: %{content_version: cv, seq: previous}} = state)
      when seq > previous do
    {:reply, {:ok, :ok}, %{state | target: %{content_version: cv, seq: seq, published: previous}, rearmed: true}}
  end
  def handle_call({:arm, _, _, _}, _from, state), do: {:reply, {:error, :invalid_static_cut_transition}, state}
  def handle_call({:hold, _, _, _}, _from, %{target: nil} = state), do: {:reply, {:ok, :ok}, state}
  def handle_call({:hold, cv, seq, published}, from, %{held: nil, target: target} = state) do
    expected = %{content_version: cv, seq: seq, published: published}
    if (target == :first and published == nil) or target == expected,
      do: hold_publisher(state, from, cv, seq),
      else: {:reply, {:error, :unexpected_publication_cut}, state}
  end
  def handle_call({:hold, _, _, _}, _from, state), do: {:reply, {:error, :duplicate_first_publication}, state}
  def handle_call({:release, cv, seq}, _from, %{held: %{identity: %{content_version: cv, seq: seq}} = held} = state) do
    Process.cancel_timer(held.timer)
    Process.demonitor(held.monitor, [:flush])
    GenServer.reply(held.from, {:ok, :ok})
    {:reply, {:ok, :ok}, %{state | held: nil, released: held.identity, target: nil}}
  end
  def handle_call({:release, cv, seq}, _from, %{released: %{content_version: cv, seq: seq}} = state),
    do: {:reply, {:ok, :ok}, state}
  def handle_call({:release, _, _}, _from, state), do: {:reply, {:error, :wrong_publication_identity}, state}

  defp hold_publisher(state, from, cv, seq) do
    identity = %{content_version: cv, seq: seq}
    monitor = Process.monitor(elem(from, 0))
    timer = Process.send_after(self(), {:expired, monitor}, state.timeout)
    if state.waiter do
      {waiter, ref} = state.waiter
      Process.demonitor(ref, [:flush])
      GenServer.reply(waiter, {:ok, identity})
    end
    {:noreply, %{state | held: %{from: from, identity: identity, monitor: monitor, timer: timer}, waiter: nil}}
  end

  @impl true
  def handle_info({:expired, ref}, %{held: %{monitor: ref} = held} = state) do
    GenServer.reply(held.from, {:error, :publication_timeout})
    {:stop, :publication_timeout, state}
  end
  def handle_info({:DOWN, ref, :process, _, _}, %{held: %{monitor: ref}} = state),
    do: {:stop, :publisher_exited, state}
  def handle_info({:DOWN, ref, :process, _, _}, %{waiter: {_from, ref}} = state),
    do: {:noreply, %{state | waiter: nil}}
  def handle_info(_message, state), do: {:noreply, state}
end

defmodule VoxelRegion.Bench.FirstPublicationLog do
  @moduledoc "只测试：完整委托正式日志契约，仅在首次 publish 前等待同一 PageWriter 的测试闸。"
  alias VoxelRegion.Bench.FirstPublication, as: Gate
  def open(root, cv) do
    backend = Gate.backend()
    {backend, backend.open(root, cv), cv}
  end
  def append({backend, handle, _}, txn), do: backend.append(handle, txn)
  def replay({backend, handle, _}), do: backend.replay(handle)
  def checkpoint({backend, handle, _}, txn), do: backend.checkpoint(handle, txn)
  def prefix({backend, handle, _}), do: backend.prefix(handle)
  def clear_unpublished({backend, handle, _}, prefix), do: backend.clear_unpublished(handle, prefix)
  def write_pages({backend, handle, _}, seq, rows), do: backend.write_pages(handle, seq, rows)
  def publish({backend, handle, cv}, seq, rows, globals) do
    :ok = Gate.hold(cv, seq, backend.prefix(handle))
    backend.publish(handle, seq, rows, globals)
  end
  def load({backend, handle, _}), do: backend.load(handle)
  def collect({backend, handle, _}, prefix, limit), do: backend.collect(handle, prefix, limit)
  def load_head({backend, handle, _}, activity), do: backend.load_head(handle, activity)
  def read_pages({backend, handle, _}, keys, fragments), do: backend.read_pages(handle, keys, fragments)
  def locate({backend, handle, _}, ids), do: backend.locate(handle, ids)
  def page_keys({backend, handle, _}), do: backend.page_keys(handle)
end
