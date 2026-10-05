defmodule VoxelRegion.World.Payloads do
  @moduledoc """
  全局系统功能：区域载荷物化与可丢弃的载荷缓存（L0–L3 按最近使用淘汰，L4+ 常驻）、区域快照与结构条目。

  由 `VoxelRegion.World` 拆出的状态函数：输入与返回都是 World 状态，真值归属与调用时机仍由 World 决定。
  """
  alias VoxelRegion.{Attachments, LogProjection}
  require Logger
  import Bitwise
  alias VoxelRegion.CollisionSource
  alias MmoContracts.Voxel.{Codec, Payload}
  import VoxelRegion.World.Canonical
  alias VoxelRegion.World.{Log, Edits, AttachmentOps}

  @max_level 5
  @resident_level 4

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

  @doc "缓存或来源字节直接返回；需物化时可用严格字节上限跳过已知不可能更小的候选。"
  def payload_bytes(state, level, region, byte_limit \\ :infinity) do
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

              if byte_limit != :infinity and
                   Codec.payload_min_bytes(Payload.min_body_bytes(payload, overrides)) >= byte_limit do
                {:not_smaller, state}
              else
                payload = with_refined(state, payload)
                bytes = Payload.encode(payload, overrides, state.seq, state.cv)
                {:ok, header} = Codec.decode_payload_header(bytes)
                {:ok, bytes, header, cache_put(state, key, bytes, header)}
              end

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
  def neighboring_bases(state, level, {rx, ry, rz}) do
    for dx <- -1..1,
        dy <- -1..1,
        dz <- -1..1,
        {dx, dy, dz} != {0, 0, 0},
        {:ok, p} <- [Map.fetch(state.region_bases, {level, {rx + dx, ry + dy, rz + dz}})],
        do: {p, {dx, dy, dz}}
  end

  def ring_overrides(bases, region) do
    {ox, oy, oz} = Payload.origin(region)

    for {p, {dx, dy, dz}} <- bases,
        x <- ring_axis(dx),
        y <- ring_axis(dy),
        z <- ring_axis(dz),
        into: %{},
        do: {{x, y, z}, Payload.value(p, Payload.local(p.region, {ox + x, oy + y, oz + z}))}
  end

  def ring_axis(-1), do: 0..0
  def ring_axis(0), do: 1..(Payload.extent() - 2)
  def ring_axis(1), do: (Payload.extent() - 1)..(Payload.extent() - 1)

  def with_refined(state, %Payload{level: 0, region: region} = payload) do
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

  def with_refined(state, %Payload{level: level, region: region} = payload) do
    structure =
      for {{^level, cell}, grid} <- state.structure,
          local = Payload.local(region, cell),
          Payload.in_span?(local),
          into: %{},
          do: {Payload.cell_index(local), grid}

    %{payload | structure: structure}
  end

  def live_instance_ids(refined, instances, macro_owners) do
    owners =
      Enum.reduce(refined, %{}, fn {_, slots}, acc ->
        local = Enum.reduce(slots, %{}, fn {_, {_, id}}, owners -> Map.put(owners, id, true) end)
        Map.merge(acc, local)
      end)

    MmoContracts.Voxel.Refined.ancestors(instances, Enum.uniq(Map.keys(owners) ++ Map.values(macro_owners)))
  end

  def region_keys(cells), do: LogProjection.region_keys(cells)

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
    faces = Attachments.l1_faces(state.attachments, Enum.map(cells, &Edits.parent_of/1))

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

  def cache_fetch(state, key) do
    case Map.fetch(state.payloads, key) do
      {:ok, {bytes, header}} -> {:ok, bytes, header, count(cache_touch(state, key), :hits)}
      :error -> {:miss, count(state, :misses)}
    end
  end

  def cache_touch(state, {level, _} = key) when level < @resident_level do
    tick = state.tick + 1
    old = Map.fetch!(state.lru_ticks, key)
    lru = :gb_trees.insert({tick, key}, true, :gb_trees.delete({old, key}, state.lru))
    %{state | lru: lru, lru_ticks: Map.put(state.lru_ticks, key, tick), tick: tick}
  end

  def cache_touch(state, _key), do: state

  def cache_put(state, {level, _} = key, bytes, header) do
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

  def cache_delete(state, {level, _} = key) do
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

  def cache_evict(state) do
    if state.lru_bytes > state.cache_limit and :gb_trees.size(state.lru) > 0 do
      {{_tick, key}, _value, _lru} = :gb_trees.take_smallest(state.lru)
      cache_evict(count(cache_delete(state, key), :evictions))
    else
      state
    end
  end

  def count(state, field),
    do: %{state | cache_stats: Map.update!(state.cache_stats, field, &(&1 + 1))}

  # serve 与副本共用物化字节；快照头只推进到当前事务前缀。
  def canonical_region_bytes(state, coord) do
    with {:ok, bytes, _, state} <- payload_bytes(state, 0, coord) do
      {:ok, Codec.stamp_payload_seq(bytes, state.seq), state}
    end
  end

  def canonical_regions(state, coords) do
    Enum.reduce_while(coords, {:ok, [], state}, fn coord, {:ok, regions, state} ->
      case canonical_region_bytes(state, coord) do
        {:ok, bytes, state} -> {:cont, {:ok, regions ++ [{coord, bytes}], state}}
        _ -> {:halt, {:error, :canonical_incomplete}}
      end
    end)
  end

  def canonical_chunks(state, coords) do
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
end
