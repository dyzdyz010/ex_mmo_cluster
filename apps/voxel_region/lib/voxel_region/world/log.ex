defmodule VoxelRegion.World.Log do
  @moduledoc """
  全局系统功能：overlay 日志：追加、回放、区域换基底与压实检查点。

  由 `VoxelRegion.World` 拆出的状态函数：输入与返回都是 World 状态，真值归属与调用时机仍由 World 决定。
  """
  alias VoxelRegion.{Attachments, LogProjection}
  require Logger
  alias VoxelRegion.Damage
  alias VoxelRegion.{Liquid, Protection}
  alias MmoContracts.Voxel.{Codec, Payload}
  import VoxelRegion.World.Canonical
  alias VoxelRegion.World.{Payloads, Edits, Production}

  # ---- 日志

  def append_log(%{log: {backend, handle}} = state, txn),
    do: backend.append(handle, attachment_metadata(state, Map.drop(txn, [:liquid_falls, :casts, :operation])))

  # canonical 附件归属与ID分配水位随同一日志／检查点持久化；网络槽副本仍只需要全局ID。
  def attachment_metadata(state, txn),
    do:
      Map.merge(txn, %{
        attachment_serial: state.attachment_serial,
        attachment_owners: state.attachment_owners,
        prefab_instances: state.instances,
        material_units_per_micro: state.material_units_per_micro,
        liquid_active: Enum.to_list(state.liquid_active)
      })

  # 事务正文唯一持有；区域索引只由成功提交、重放或压实的同一条目派生。
  def remember_entry(state, full) do
    state = retain_entry(state, full)
    # 每笔事务都是热提交的唤醒事件（R8-05）：记下改写的属性行供热行增量重判，休眠中的热模拟排一拍。
    state = VoxelRegion.World.Thermal.touch(state, Map.get(full, :property_states, []))
    schedule_checkpoint(state)
  end

  defp retain_entry(state, full) do
    # 实时落体帧与待施放记录只随本次广播，不进日志、检查点与回放尾。
    # 没有格条目的事务（热提交、镐击等纯属性变化）只留投影与订阅补发读的字段；正文在持久日志里（`entries_after`）。
    txn = if match?(%{entries: [], coarse: []}, full),
      do: Map.take(full, [:seq, :entries, :coarse]),
      else: Map.drop(full, [:liquid_falls, :casts, :operation])
    %{state | entries: Map.put(state.entries, txn.seq, txn),
      entry_regions: LogProjection.index(state.entry_regions, txn)}
  end

  @doc "只有尚未压实的后缀且没有进行中的任务时才安排下一轮维护。"
  def schedule_checkpoint(state) do
    # 单个完整检查点不再生长；只有新历史出现时安排一次维护。
    if map_size(state.entries) > 1 and state.checkpoint_timer == nil and state.checkpoint_job == nil,
      do: %{state | checkpoint_timer: :erlang.start_timer(60_000, self(), :checkpoint)},
      else: state
  end

  def replay_log(%{log: {backend, handle}} = state) do
    Enum.reduce(backend.replay(handle), state, fn txn, s ->
      s = replay_entry(s, txn) |> replay_damage(txn)
      remember_entry(%{s | seq: max(s.seq, txn.seq)}, txn)
    end)
  end

  def replay_entry(state, %{entries: entries, coarse: coarse}) do
    state = Enum.reduce(entries, state, &replay_entry(&2, &1))

    Enum.reduce(coarse, state, fn e, s ->
      Edits.put_overlay(s, e.level, e.cell, {e.material, e.skins})
    end)
  end

  def replay_entry(state, %{payload: bytes}) do
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
        ids = Payloads.live_instance_ids(refined, instances, state.macro_owners)

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

  def replay_entry(state, %{structure: grid, level: level, cell: cell}) do
    key = {level, cell}

    structure =
      if grid == <<>>,
        do: Map.delete(state.structure, key),
        else: Map.put(state.structure, key, grid)

    Enum.reduce(Payloads.region_keys([key]), %{state | structure: structure}, fn region, s ->
      %{Payloads.cache_delete(s, region) | snapshots: MapSet.put(s.snapshots, region)}
    end)
  end

  def replay_entry(state, entry) do
    state =
      Edits.put_overlay(
        state,
        0,
        entry.coord,
        {entry.material, MmoContracts.Voxel.Skins.uniform(entry.material)}
      )

    Enum.reduce(entry.coarse, state, fn e, s ->
      Edits.put_overlay(s, e.level, e.cell, {e.material, e.skins})
    end)
  end

  # 区域自身 core 里的稀疏编辑格（索引同时含邻区 ring 格）。
  def core_cells(state, {_, region} = key) do
    state.overlay_regions
    |> Map.get(key, MapSet.new())
    |> Enum.filter(&(region_of(&1) == region))
  end

  def rebase_region(state, p) do
    key = {p.level, p.region}

    # 检查点已包含这个 core 的全部真值；移除已吸收的稀疏编辑及其邻区索引。
    core_cells = core_cells(state, key)

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

    # 换基底只改变真值的表示（稀疏编辑并入基底），不改变任何区域物化出的字节：只丢弃本区域的缓存与源解码，
    # 其余区域（含以本区域为 ring 的邻区）缓存照旧有效。
    %{
      Payloads.cache_delete(state, key)
      | decoded: Map.delete(state.decoded, key),
        region_bases: Map.put(state.region_bases, key, p),
        snapshots: MapSet.put(state.snapshots, key),
        overlay: overlay,
        overlay_regions: regions
    }
  end

  def select_transaction(state, changed) do
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
            case Payloads.payload_bytes(s, level, region, cell_bytes - entry_overhead) do
              {:ok, bytes, _header, next} -> {bytes, next}
              {:not_smaller, next} -> {nil, next}
            end
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

  def compact_log(%{seq: 0} = state), do: state

  def compact_log(state) do
    checkpoint = state |> checkpoint_input() |> build_checkpoint()
    state |> finish_checkpoint(checkpoint) |> schedule_checkpoint()
  end

  @doc "冻结检查点所需的不可变值；不携带订阅、热域资源、在线任务或历史正文。"
  def checkpoint_input(state) do
    state
    |> Map.take([:seq, :cv, :source, :source_state, :region_bases, :overlay, :overlay_regions,
      :snapshots, :refined, :instances, :structure, :macro_owners, :attachments, :liquid_units,
      :damage, :epochs, :material_balances, :caster_energy, :material_supplies, :craft_ledger,
      :food_ledger, :food_receipts, :placed_by, :protection, :phase_inventory, :thermal,
      :attachment_serial, :attachment_owners, :material_units_per_micro, :liquid_active,
      :payloads, :decoded, :lru, :lru_ticks, :tick, :lru_bytes, :resident_bytes, :cache_limit,
      :cache_stats])
    |> Map.put(:retained_before, map_size(state.entries))
  end

  @doc "只计算冻结前缀的完整事务；派生缓存不返回给在线World，不写日志或发送退休通知。"
  def build_checkpoint(state) do
    started = System.monotonic_time(:microsecond)
    # 检查点覆盖完整前缀；当前 seq 对任意更旧游标都是完整补丁。
    # 已有完整区域会在下方写入当前 after-image，不再先编码同一 core 的逐格条目。
    sparse =
      for {{level, cell} = key, _} <- state.overlay,
          not MapSet.member?(state.snapshots, {level, region_of(cell)}),
          do: key

    {txn, state} = select_transaction(state, sparse)
    selected = System.monotonic_time(:microsecond)

    {extra, state} =
      Enum.map_reduce(state.snapshots, state, fn {level, region}, s ->
        {:ok, bytes, _, s} = Payloads.payload_bytes(s, level, region)
        {region_entry(s.seq, bytes), s}
      end)

    imaged = System.monotonic_time(:microsecond)

    txn =
      Map.merge(%{txn | entries: txn.entries ++ extra}, %{
        property_states: Map.values(state.damage),
        epochs: state.epochs,
        material_balances: state.material_balances,
        caster_energy: state.caster_energy,
        material_supplies: state.material_supplies,
        craft_ledger: state.craft_ledger,
        food_ledger: state.food_ledger,
        food_receipts: state.food_receipts,
        placed_by: state.placed_by,
        macro_owners: state.macro_owners,
        protection: state.protection.regions,
        phase_inventory: state.phase_inventory,
        thermal: state.thermal
      })

    %{transaction: attachment_metadata(state, txn), retained_before: state.retained_before, regions: length(extra),
      select_us: selected - started, image_us: imaged - selected}
  end

  @doc "World唯一持久出口：替换已算好的前缀，保留期间提交的后缀与当前真值。"
  def finish_checkpoint(state, %{transaction: txn} = checkpoint) do
    started = System.monotonic_time(:microsecond)
    {backend, handle} = state.log
    :ok = backend.checkpoint(handle, txn)
    persisted = System.monotonic_time(:microsecond)

    # 有并行后缀时保留当前canonical表示，绝不把冻结前缀覆盖到新overlay或缓存。
    entries_to_rebase = if state.seq == txn.seq, do: txn.entries, else: []
    # 上次检查点后 core 没有编辑的完整区域，基底就是它自己：跳过换基底，保留载荷缓存与解码。
    {state, rebased} =
      Enum.reduce(entries_to_rebase, {state, 0}, fn
        %{payload: bytes}, {s, n} ->
          {:ok, h} = Codec.decode_payload_header(bytes)

          if MapSet.member?(s.snapshots, {h.level, h.region}) and core_cells(s, {h.level, h.region}) == [] do
            {s, n}
          else
            {:ok, p} = Payload.decode(bytes)
            {rebase_region(s, p), n + 1}
          end

        _, acc ->
          acc
      end)

    if state.checkpoint_timer, do: Process.cancel_timer(state.checkpoint_timer)
    suffix = for {seq, entry} <- state.entries, seq > txn.seq, do: entry
    state = Enum.reduce([txn | suffix], %{state | entries: %{}, entry_regions: %{},
      checkpoint_timer: nil, checkpoints: state.checkpoints + 1}, &retain_entry(&2, &1))
    # 只退休已落盘前缀；当前World还可能已经向Replica发出更晚的后缀。
    Enum.each(Map.keys(state.replica_subs), &send(&1, {:canonical_replica_checkpoint, txn.seq}))
    now = System.monotonic_time(:microsecond)

    Logger.info(
      "voxel_checkpoint seq=#{txn.seq} current_seq=#{state.seq} retained_before=#{checkpoint.retained_before} regions=#{checkpoint.regions} rebased=#{rebased} " <>
        "select_us=#{checkpoint.select_us} image_us=#{checkpoint.image_us} persist_us=#{persisted - started} rebase_us=#{now - persisted}"
    )

    state
  end

  # no-op 不追加日志；只向发起连接确认当前游标，排在此连接已有的 World 消息之后。
  def acknowledge_noop(state, {pid, _tag}) do
    if Map.has_key?(state.subs, pid) do
      bytes =
        Codec.encode_transaction(%{seq: state.seq, entries: [], coarse: []})
        |> IO.iodata_to_binary()

      send(pid, {:voxel_log_transaction_payload, bytes})
    end
  end

  def region_entry(seq, bytes), do: %{seq: seq, payload: Codec.stamp_payload_seq(bytes, seq)}

  def replay_damage(state, txn) do
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
        food_receipts: Production.merge_food_receipts(state.food_receipts, Map.get(txn, :food_receipts, %{})),
        placed_by: Production.merge_placed(state.placed_by, Map.get(txn, :placed_by, %{})),
        protection: Protection.apply(state.protection, Map.get(txn, :protection, %{})),
        macro_owners: Production.merge_placed(state.macro_owners, Map.get(txn, :macro_owners, %{})),
        instances: Map.get(txn,:prefab_instances,state.instances),
        material_balances:
          Map.merge(state.material_balances, Map.get(txn, :material_balances, %{})),
        caster_energy: Map.merge(state.caster_energy, Map.get(txn, :caster_energy, %{}))
    }
  end
end
