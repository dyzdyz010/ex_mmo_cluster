defmodule VoxelRegion.World.Payloads do
  alias VoxelRegion.RefinedSlots
  @moduledoc """
  全局系统功能：区域载荷物化与 `World.Cache` 中可丢弃的载荷条目（各级一律按最近使用淘汰）、区域快照与结构条目。

  由 `VoxelRegion.World` 拆出的状态函数：输入与返回都是 World 状态，真值归属与调用时机仍由 World 决定。
  """
  alias VoxelRegion.{Attachments, LogProjection}
  require Logger
  import Bitwise
  alias VoxelRegion.CollisionSource
  alias MmoContracts.Voxel.{Codec, Payload}
  import VoxelRegion.World.Canonical
  alias VoxelRegion.World.{Log, Edits, AttachmentOps}

  alias VoxelRegion.World.Cache

  @max_level VoxelRegion.Spatial.max_level()

  # ---- 应答

  def serve_item(state, client_version, %{
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

          # 游标早于已发布前缀：其后的历史已退休（m2a §6.3），只能给整区载荷，不能用残缺的后缀冒充完整增量。
          client_version != state.cv or have_seq == 0 or not known or expired?(state, have_seq) ->
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

  @doc "缓存或来源字节直接返回；需物化时可用严格字节上限跳过已知不可能更小的候选。"
  def payload_bytes(state, level, region, byte_limit \\ :infinity) do
    key = {level, region}

    case cache_fetch(state, key) do
      {:ok, bytes, header, state} ->
        {:ok, bytes, header, state}

      {:miss, state} ->
        started = System.monotonic_time(:microsecond)
        case terrain_input(state, level, region) do
          :source -> source_bytes(state, level, region)
          {:terrain, cells, bases} ->
          case terrain(state, level, region, cells, bases) do
            {:ok, payload, overrides, state} ->
              terrain_end = System.monotonic_time(:microsecond)
              if byte_limit != :infinity and
                   Codec.payload_min_bytes(Payload.min_body_bytes(payload, overrides)) >= byte_limit do
                {:not_smaller, state}
              else
                {payload, state} = with_refined(state, payload)
                encode_start = System.monotonic_time(:microsecond)

                # 有上限时先看地形段的压缩前缀：已不短于上限就不再编细节、压缩完整 body（结论与完整编码后比较相同）。
                encoded =
                  if byte_limit == :infinity,
                    do: {:ok, Payload.encode(payload, overrides, state.seq, state.cv)},
                    else: Payload.encode_below(payload, overrides, state.seq, state.cv, byte_limit)
                encode_end = System.monotonic_time(:microsecond)

                case encoded do
                  :not_smaller ->
                    {:not_smaller, state}

                  {:ok, bytes} ->
                    {:ok, header} = Codec.decode_payload_header(bytes)
                    cache_start = System.monotonic_time(:microsecond)
                    state = cache_put(state, key, bytes, header)
                    cache_end = System.monotonic_time(:microsecond)
                    {x, y, z} = region
                    Logger.info(fn ->
                      "voxel_payload_materialize pid=#{:erlang.pid_to_list(self())} seq=#{state.seq} cv=#{state.cv} level=#{level} x=#{x} y=#{y} z=#{z} source=materialize " <>
                        "start_us=#{started} terrain_end_us=#{terrain_end} encode_start_us=#{encode_start} encode_end_us=#{encode_end} cache_start_us=#{cache_start} cache_end_us=#{cache_end} " <>
                        "terrain_us=#{terrain_end - started} encode_us=#{encode_end - encode_start} cache_us=#{cache_end - cache_start} elapsed_us=#{cache_end - started} " <>
                        "raw_bytes=#{header.raw_bytes} body_bytes=#{header.body_bytes} payload_bytes=#{byte_size(bytes)}"
                    end)
                    {:ok, bytes, header, state}
                end
              end

            {:error, :missing, state} ->
              {:error, :missing, state}

            {:error, reason, state} ->
              {:error, reason, state}
          end
        end
    end
  end

  # 未改动区域沿来源字节直通；完整载荷与材料读取共用同一个物化判据。
  defp terrain_input(state, level, region) do
    key = {level, region}
    cells = Map.get(state.overlay_regions, key, MapSet.new())
    bases = neighboring_bases(state, level, region)
    if MapSet.size(cells) == 0 and not MapSet.member?(state.snapshots, key) and bases == [],
      do: :source, else: {:terrain, cells, bases}
  end

  defp source_bytes(state, level, region) do
    case state.source.read(state.source_state, level, region) do
      {:ok, bytes, header} -> {:ok, bytes, header, cache_put(state, {level, region}, bytes, header)}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @doc "液体候选的地形材料与覆盖表；纯 source 只临时解材料段，不建立完整 decoded 驻留。"
  def terrain_materials(state, level, region) do
    case terrain_input(state, level, region) do
      :source ->
        result = case cache_fetch(state, {level, region}) do
          {:ok, bytes, header, state} -> {:ok, bytes, header, state}
          {:miss, state} -> source_bytes(state, level, region)
        end
        with {:ok, bytes, _, loaded} <- result do
          case Payload.decode_cells(bytes) do
            {:ok, materials} -> {:ok, materials, %{}, loaded}
            {:error, reason} -> {:error, reason, loaded}
          end
        end
      {:terrain, cells, bases} ->
        with {:ok, payload, overrides, loaded} <- terrain(state, level, region, cells, bases),
          do: {:ok, payload.cells, overrides, loaded}
    end
  end

  defp terrain(state, level, region, cells, bases) do
    case decoded(state, level, region) do
      {:ok, payload, state} ->
        overrides = Map.new(cells, fn cell ->
          {Payload.local(region, cell), Map.fetch!(state.overlay, {level, cell})}
        end)
        {:ok, payload, Map.merge(ring_overrides(bases, payload), overrides), state}
      error -> error
    end
  end

  # ---- 载荷缓存：条目存于统一 `World.Cache`（见 cache_fetch/cache_put），各级一律按 LRU 淘汰。

  # 已提交完整区域拥有自己的 core；ring 是相邻 core 的投影，不展开成常驻逐格增量。
  def neighboring_bases(state, level, {rx, ry, rz}) do
    for dx <- -1..1,
        dy <- -1..1,
        dz <- -1..1,
        {dx, dy, dz} != {0, 0, 0},
        {:ok, p} <- [Map.fetch(state.region_bases, {level, {rx + dx, ry + dy, rz + dz}})],
        do: {p, {dx, dy, dz}}
  end

  @doc "邻core相对当前载荷ring的实际值差额；相同值不构造覆盖，后续overlay仍优先。"
  def ring_overrides(bases, %Payload{} = center) do
    core = Payload.extent() - 2

    Enum.reduce(bases, %{}, fn {p, {dx, dy, dz}}, overrides ->
      xs = ring_axis(dx)
      x = xs.first
      count = xs.last - x + 1

      for y <- ring_axis(dy), z <- ring_axis(dz), reduce: overrides do
        acc ->
          local = {x, y, z}
          neighbor_local = {x - core * dx, y - core * dy, z - core * dz}
          Payload.put_row_differences(center, local, p, neighbor_local, count, acc)
      end
    end)
  end

  def ring_axis(-1), do: 0..0
  def ring_axis(0), do: 1..(Payload.extent() - 2)
  def ring_axis(1), do: (Payload.extent() - 1)..(Payload.extent() - 1)

  @doc "沿唯一细节与树冠构造路径补载荷，记录固定标量阶段；返回载荷与原状态契约不变。"
  def with_refined(state, %Payload{} = payload) do
    started = System.monotonic_time(:microsecond)
    {payload,state}=with_existing_details(state,payload)
    details_end = System.monotonic_time(:microsecond)
    {anchors,instances,residual,structure,state}=VoxelRegion.World.Canopy.project(state,payload.level,payload.region)
    payload = %{payload | canopy: anchors,canopy_instances: instances,canopy_residual: residual,
       canopy_residual_structure: structure,base_instances: nil,base_format_version: nil}
    canopy_end = System.monotonic_time(:microsecond)
    {x, y, z} = payload.region
    # 只取已经构造的表大小与二进制长度；不为观测再遍历槽、状态或编码正文。
    Logger.info(fn ->
      "voxel_payload_details pid=#{:erlang.pid_to_list(self())} seq=#{state.seq} cv=#{state.cv} level=#{payload.level} x=#{x} y=#{y} z=#{z} source=with_refined " <>
        "details_start_us=#{started} details_end_us=#{details_end} canopy_end_us=#{canopy_end} details_us=#{details_end - started} canopy_us=#{canopy_end - details_end} " <>
        "cells_bytes=#{byte_size(payload.cells)} fmi_bytes=#{byte_size(payload.fmi)} maps_bytes=#{byte_size(payload.maps)} " <>
        "records_entries=#{map_size(payload.records)} refined_entries=#{refined_count(payload)} refined_records_entries=#{refined_count(payload)} instances_entries=#{map_size(payload.instances)} " <>
        "structure_entries=#{map_size(payload.structure)} attachments_entries=#{map_size(payload.attachments)} liquid_units_entries=#{map_size(payload.liquid_units)} " <>
        "canopy_entries=#{map_size(payload.canopy)} canopy_instances_entries=#{map_size(payload.canopy_instances)} canopy_residual_entries=#{map_size(payload.canopy_residual)} canopy_residual_structure_entries=#{map_size(payload.canopy_residual_structure)}"
    end)
    {payload,state}
  end
  defp refined_count(%Payload{refined_encoding: nil, refined: refined}), do: map_size(refined)
  defp refined_count(%Payload{refined_encoding: encoding}), do: MmoContracts.Voxel.Refined.Encoding.size(encoding)

  defp with_existing_details(state, %Payload{level: 0, region: {rx, ry, rz} = region} = payload) do
    # 载荷跨度含一圈 ring：只看本区与 26 个相邻区的 refined 宏格（区域索引），不扫全世界。
    near = refined_in_regions(state, for(dx <- -1..1, dy <- -1..1, dz <- -1..1, do: {rx + dx, ry + dy, rz + dz}))

    span = MapSet.filter(near, &Payload.in_span?(Payload.local(region, &1)))

    # 记录直接引用已接纳槽的有序前缀；该O(1)投影不再另存可写备忘。
    record_start = System.monotonic_time(:microsecond)
    {records, slot_count, record_bytes} =
      Enum.reduce(Map.take(state.refined, MapSet.to_list(span)), {%{}, 0, 0}, fn {cell, slots}, {records, slot_count, record_bytes} ->
        index = Payload.cell_index(Payload.local(region, cell))
        bin = RefinedSlots.sorted_records(slots)
        {Map.put(records, index, {RefinedSlots.size(slots), bin}),
         slot_count + RefinedSlots.size(slots), record_bytes + byte_size(bin)}
      end)
    record_end = System.monotonic_time(:microsecond)

    owners_start = System.monotonic_time(:microsecond)
    macro_owners = for {cell, _} = entry <- macro_owners_in_regions(state, for(dx <- -1..1, dy <- -1..1, dz <- -1..1, do: {rx + dx, ry + dy, rz + dz})),
      Payload.in_span?(Payload.local(region, cell)), into: %{}, do: entry
    # 跨度内微格的持有者：部件索引里与跨度相交的身份（与逐槽扫描这些格得到的集合相同）。
    owners = for {owner, cells} <- state.refined_owners, not MapSet.disjoint?(cells, span), do: owner
    ids = MmoContracts.Voxel.Refined.ancestors(state.instances, Enum.uniq(owners ++ Map.values(macro_owners)))
    owners_end = System.monotonic_time(:microsecond)
    # 原循环内只累计已访问槽与所选字节；两个时间区间分别覆盖原 record 与 owner 自然小段。
    Logger.info(fn ->
      "voxel_payload_records pid=#{:erlang.pid_to_list(self())} seq=#{state.seq} cv=#{state.cv} level=0 x=#{rx} y=#{ry} z=#{rz} source=with_existing_details " <>
        "record_start_us=#{record_start} record_end_us=#{record_end} record_loop_us=#{record_end - record_start} " <>
        "owners_start_us=#{owners_start} owners_end_us=#{owners_end} owners_us=#{owners_end - owners_start} " <>
        "slots=#{slot_count} record_bytes=#{record_bytes}"
    end)

    {%{
       payload
       | liquid_units: for({cell, units} <- liquid_in_regions(state, for(dx <- -1..1, dy <- -1..1, dz <- -1..1, do: {rx + dx, ry + dy, rz + dz})),
             local = Payload.local(region, cell), Payload.in_span?(local),
             into: %{}, do: {Payload.cell_index(local), units}),
         attachments: Attachments.extract(attachments_around_region(state, region), region),
         refined: %{},
         refined_encoding: MmoContracts.Voxel.Refined.Encoding.new(records),
         instances: Map.take(state.instances, ids),
         format_version: if(ids != [] or payload.format_version == 5, do: 5, else: 4)
     }, state}
  end

  defp with_existing_details(state, %Payload{level: level, region: region} = payload) do
    # 跨度（含 ring）覆盖的 L0 页上的 structure 片段（`structure_pages`），不扫全部 structure。
    structure =
      for page <- VoxelRegion.World.Canopy.span_regions(level, region),
          cell <- Map.get(state.structure_pages, {level, page}, MapSet.new()),
          local = Payload.local(region, cell),
          Payload.in_span?(local),
          into: %{},
          do: {Payload.cell_index(local), Map.fetch!(state.structure, {level, cell})}

    {%{payload | structure: structure}, state}
  end

  @doc "整个世界仍有微格或宏格的实例及其祖先：微格持有者直接读部件索引，与逐槽扫描整表的集合相同。"
  def live_instance_ids(state),
    do: MmoContracts.Voxel.Refined.ancestors(state.instances,
      Enum.uniq(Map.keys(state.refined_owners) ++ Map.keys(state.macro_owner_cells)))

  @doc """
  本笔失去全部格（且没有存活后代）的实例：只在本笔碰过的身份及其祖先里裁（评审 A1 / F2）。内存里还有别的实例——
  例如按需装页时整树尚未闭合、或别处未改动的——不因本笔与它们无关的提交被当成死实例删掉；存活判据与 `live_instance_ids/1` 相同。
  """
  def dead_instances(state) do
    touched = for id <- Map.get(state, :owners_touched, MapSet.new()), not match?({:aid, _}, id), Map.has_key?(state.instances, id), do: id

    if touched == [] do
      []
    else
      live = MapSet.new(live_instance_ids(state))
      for id <- MmoContracts.Voxel.Refined.ancestors(state.instances, touched), not MapSet.member?(live, id), do: id
    end
  end

  @doc "裁掉 `dead_instances/1`。"
  def prune_instances(state), do: Map.drop(state.instances, dead_instances(state))

  def region_keys(cells), do: LogProjection.region_keys(cells)

  @doc "游标早于已发布前缀（保留历史只含前缀之后的事务，m2a §6.3）。"
  def expired?(state, seq), do: state.page_store.published != nil and seq < state.page_store.published

  # 全局系统功能：结构增量与地形独立；空字节删除该格，消费者同时更新 core/ring。
  def structure_entries(state, cells) do
    Enum.map(Enum.sort(cells), fn {level, cell} = key ->
      %{seq: state.seq, level: level, cell: cell, structure: Map.get(state.structure, key, <<>>)}
    end)
  end

  def region_afterimages(state, keys, terrain_payloads, terrain_changes \\ []) do
    Enum.map_reduce(Enum.sort(Enum.uniq(keys)), state, fn {level, region} = key, s ->
      started = System.monotonic_time(:microsecond)
      s = %{cache_delete(s, key) | snapshots: MapSet.put(s.snapshots, key)}

      {bytes, s} =
        case Map.fetch(terrain_payloads, key) do
          {:ok, {prior, _header}} ->
            {details, s} = with_refined(s, %Payload{level: level, region: region})

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
            if Edits.needs_source?(s, key), do: :ok = s.source.ensure(s.source_state, level, region)
            {:ok, bytes, _, s} = payload_bytes(s, level, region)
            {bytes, s}
        end

      Logger.info(
        "voxel_region_afterimage seq=#{s.seq} level=#{level} region=#{inspect(region)} reused=#{Map.has_key?(terrain_payloads, key)} elapsed_us=#{System.monotonic_time(:microsecond) - started}"
      )

      {Log.region_entry(s.seq, bytes), s}
    end)
  end

  # 结构与地形分别派生；地形 early-stop 不得截断仍会变化的局部细化。
  def refresh_structure(state, cells) do
    cells = AttachmentOps.attachment_dirty(state, cells) |> Enum.map(&elem(&1, 1))
    parents = Enum.map(cells, &Edits.parent_of/1)
    faces = Attachments.l1_faces(attachments_near_parents(state, parents), parents)

    {state, _, changed} =
      Enum.reduce(1..@max_level, {state, cells, []}, fn level, {s, dirty, changed} ->
        parents = dirty |> Enum.map(&Edits.parent_of/1) |> Enum.uniq()

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
              keys = region_keys([key])

              s =
                Enum.reduce(keys, put_structure(s, key, grid), fn k, s ->
                  %{cache_delete(s, k) | snapshots: MapSet.put(s.snapshots, k)}
                end)

              {s, [key | changed]}
            end
          end)

        {s, parents, changed}
      end)

    {state, region_keys(changed), changed}
  end

  @doc "读取同一共享缓存中的payload条目；header仍为纯协议头。"
  def cache_fetch(state, key) do
    case Cache.get(state.cache, {:payload, key}) do
      {:ok, %{bytes: bytes, metadata: %Cache.PayloadMetadata{header: header}}, cache} ->
        {:ok, bytes, header, %{state | cache: cache}}
      {:miss, cache} -> {:miss, %{state | cache: cache}}
    end
  end

  @doc "只读当前合法payload，不改变LRU。"
  def cached_payload(state, key) do
    case Cache.peek(state.cache, {:payload, key}) do
      {:ok, %{bytes: bytes, metadata: %Cache.PayloadMetadata{header: header}}} -> {:ok, {bytes, header}}
      :miss -> :error
    end
  end

  @doc "只查payload命名空间的当前键；用于定向失效与冻结，不作预算重算。"
  def cached_keys(state), do: Enum.map(Cache.keys(state.cache, :payload), &elem(&1, 1))

  @doc "对外仍投影原字节／header pair，不传播检查标记。"
  def export_cached(state, keys \\ nil) do
    for key <- keys || cached_keys(state), {:ok, pair} <- [cached_payload(state, key)], into: %{}, do: {key, pair}
  end

  @doc "缓存成员判断不取正文、不修改统计。"
  def cached?(state, key), do: Cache.peek(state.cache, {:payload, key}) != :miss

  @doc "合法暖条目的检查结论随同一Cache entry退休。"
  def checked_liquid(state, region) do
    case Cache.peek(state.cache, {:payload, {0, region}}) do
      {:ok, %{metadata: %Cache.PayloadMetadata{liquid_checked: true}}} ->
        {:ok, _bytes, _header, next} = cache_fetch(state, {0, region})
        {:checked, next}
      _ -> :unchecked
    end
  end

  @doc "无提交检查完成后只更新该entry元信息，不替换bytes或退休pin。"
  def mark_liquid_checked(state, region) do
    key = {:payload, {0, region}}
    case Cache.peek(state.cache, key) do
      {:ok, %{metadata: %Cache.PayloadMetadata{} = metadata}} ->
        case Cache.update_metadata(state.cache, key, %{metadata | liquid_checked: true}) do
          {:ok, cache} -> %{state | cache: cache}
          {:error, reason, _} ->
            Logger.warning("voxel_cache_metadata_rejected key=#{inspect(key)} reason=#{inspect(reason)}")
            state
        end
      :miss -> state
    end
  end

  @doc "新payload只进入共享预算；缓存拒收显式记录，已生成的正常输出由请求在途owner持有。"
  def cache_put(state, key, bytes, header) do
    cache = Cache.delete(state.cache, {:payload, key})
    version = {header.content_version, header.seq, header.hash}
    metadata = %Cache.PayloadMetadata{header: header}
    case Cache.put(cache, {:payload, key}, bytes, version, metadata) do
      {:ok, next} -> %{state | cache: next}
      {:error, reason, next} ->
        Logger.warning("voxel_cache_store_rejected key=#{inspect(key)} bytes=#{byte_size(bytes)} reason=#{inspect(reason)}")
        %{state | cache: next}
    end
  end

  @doc "权威失效显式退休payload；共享缓存中的prefab不受该键删除影响。"
  def cache_delete(state, key), do: %{state | cache: Cache.delete(state.cache, {:payload, key})}

  # serve 与副本共用物化字节；快照头只推进到当前事务前缀。
  def canonical_region_bytes(state, coord) do
    with {:ok, bytes, _, state} <- payload_bytes(state, 0, coord) do
      {:ok, Codec.stamp_payload_seq(bytes, state.seq), state}
    end
  end

  @doc "组装完整区域；已经冻结的字节是本轮只读输入，不受工作进程临时 LRU 淘汰影响。"
  def canonical_regions(state, coords, captured \\ %{}) do
    Enum.reduce_while(coords, {:ok, [], state}, fn coord, {:ok, regions, state} ->
      result = case Map.fetch(captured, {0, coord}) do
        {:ok, {bytes, _header}} -> {:ok, Codec.stamp_payload_seq(bytes, state.seq), state}
        :error -> canonical_region_bytes(state, coord)
      end
      case result do
        {:ok, bytes, state} -> {:cont, {:ok, regions ++ [{coord, bytes}], state}}
        _ -> {:halt, {:error, :canonical_incomplete}}
      end
    end)
  end

  @doc "按提交的完整宏格变化集投影碰撞；旧侧只读变化格，完整占用仅构造真实变化的 new chunk。"
  def canonical_changed_chunks(before, after_state, changes) do
    groups = Enum.group_by(changes, fn {coord, _cells} -> CollisionSource.region_coord(coord) end)

    Enum.reduce_while(groups, {:ok, []}, fn {region, changes}, {:ok, chunks} ->
      with {:ok, old_at} <- collision_reader(before, region),
           {:ok, new_at} <- collision_reader(after_state, region) do
        chunks = Enum.reduce(changes, chunks, fn {coord, cells}, acc ->
          case CollisionSource.capture_changed(coord, old_at, new_at, cells) do
            nil -> acc
            chunk -> [chunk | acc]
          end
        end)
        {:cont, {:ok, chunks}}
      else
        _ -> {:halt, {:error, :canonical_incomplete}}
      end
    end)
    |> case do
      {:ok, chunks} -> {:ok, Enum.sort_by(chunks, & &1.coord)}
      error -> error
    end
  end

  defp collision_reader(state, region) do
    with {:ok, payload, state} <- decoded(state, 0, region) do
      {:ok, fn cell ->
        material = case Map.fetch(state.overlay, {0, cell}) do
          {:ok, {material, _}} -> material
          :error -> Payload.material(payload, Payload.local(region, cell))
        end
        {material, CollisionSource.phase_slots(material, Map.get(state.refined, cell, RefinedSlots.empty()),
          Map.get(state.liquid_units, cell), liquid_capacity(state))}
      end}
    end
  end
end
