defmodule VoxelRegion.World.Canonical do
  @moduledoc """
  全局系统功能：`VoxelRegion.World` 状态上的 canonical 读取与材料判定。

  只读 World 的权威状态（overlay、区域基底、refined、稀疏属性记录、有限数量与目录）；读取 baseline 时
  返回带解码缓存的新 state，从不写真值。World 与热模拟（`VoxelRegion.World.Thermal`）共用这一份读取语义。
  """
  alias VoxelRegion.{Attachments, Damage, Phase, Prefab}
  alias MmoContracts.Voxel.Payload

  @micro VoxelRegion.Spatial.micro_resolution()

  @doc "持有给定部件身份微格的 refined 宏格，按全量遍历 `state.refined` 的次序。"
  def micro_owner_cells(state,ids), do: for({cell, _} <- owner_refined(state, ids), do: cell)

  @doc "含这些部件身份微格的 `{cell, slots}`（部件索引），次序同全量遍历 `state.refined`。"
  def owner_refined(state, ids),
    do: in_refined_order(state,
      Enum.reduce(ids, MapSet.new(), &MapSet.union(&2, Map.get(state.refined_owners, &1, MapSet.new()))))

  # ---- refined 的派生索引（可由 refined 重建，不持久化、不是第二真值）
  #
  # refined_owners：部件身份 => 含其微格的宏格集合；refined_regions：L0 区域 => 区域内的 refined 子表（宏格 => 槽，
  # 与 refined 共享同一槽值）。两者只由 put_refined/3 与 index_refined/1 写，随 refined 的每次写入同步更新，让按部件或
  # 按区域的读取只碰相关的格，不再随世界的细化格总数线性扫描；区域子表随写入换新，提交前后按区域比较即得改动格。

  @doc "按 refined 整表重建派生索引；在线与重放都由 put_refined/3 增量维护，这里供核对增量结果（单测、等价对照）。"
  def index_refined(state) do
    {owners, regions} =
      Enum.reduce(state.refined, {%{}, %{}}, fn {cell, slots}, {owners, regions} ->
        {index_owners(owners, cell, slot_owners(slots), MapSet.new()), put_region_cell(regions, region_of(cell), cell, slots)}
      end)

    Map.merge(state, %{refined_owners: owners, refined_regions: regions, refined_encoded: %{}})
  end

  @doc "写一个宏格的细化槽（空 map 即删除），同步维护派生索引。"
  def put_refined(state, cell, slots) do
    old = slot_owners(Map.get(state.refined, cell, %{}))
    new = slot_owners(slots)
    refined = if map_size(slots) == 0, do: Map.delete(state.refined, cell), else: Map.put(state.refined, cell, slots)

    %{state | refined: refined,
      refined_owners: state.refined_owners |> index_owners(cell, MapSet.difference(new, old), MapSet.new())
        |> index_owners(cell, MapSet.new(), MapSet.difference(old, new)),
      refined_regions: put_region_cell(state.refined_regions, region_of(cell), cell, slots),
      refined_encoded: Map.delete(state.refined_encoded, cell)}
  end

  # ---- liquid_units 的派生索引（可由 liquid_units 重建，不持久化、不是第二真值）
  #
  # liquid_regions：L0 区域 => 该区「宏格 => 数量」子表。只由 put_liquid/2 与 index_liquid/1 写；
  # 区域载荷与区域换基底只碰相关区域的数量记录，不随世界的有限数量格总数线性扫描。

  @doc "按 liquid_units 整表重建派生索引：单测核对增量结果。"
  def index_liquid(state),
    do: put_liquid(Map.merge(state, %{liquid_units: %{}, liquid_regions: %{}}), state.liquid_units)

  @doc "写数量变化 `{cell, quantity}`（0 即删除，与 `Liquid.apply_changes/2` 同义），同步维护派生索引。"
  def put_liquid(state, changes) do
    Enum.reduce(changes, state, fn {cell, quantity}, s ->
      region = region_of(cell)

      if quantity == 0 do
        %{s | liquid_units: Map.delete(s.liquid_units, cell),
          liquid_regions: put_region_cell(s.liquid_regions, region, cell, %{})}
      else
        %{s | liquid_units: Map.put(s.liquid_units, cell, quantity),
          liquid_regions: Map.update(s.liquid_regions, region, %{cell => quantity}, &Map.put(&1, cell, quantity))}
      end
    end)
  end

  @doc "这些 L0 区域内的 `{宏格, 数量}`。"
  def liquid_in_regions(state, regions),
    do: regions |> Enum.uniq() |> Enum.flat_map(&Map.to_list(Map.get(state.liquid_regions, &1, %{})))

  # ---- macro_owners 的派生索引（可由 macro_owners 重建，不持久化、不是第二真值）
  #
  # macro_owner_regions：L0 区域 => 该区「宏格 => 归属」子表；macro_owner_cells：归属 => 宏格集合。
  # 只由 put_macro_owner/3 与 index_macro_owners/1 写；树冠投影、区域载荷与存活实例只碰相关区域或归属者，
  # 不随世界的归属宏格总数线性扫描。

  @doc "按 macro_owners 整表重建派生索引：载入后与单测核对增量结果。"
  def index_macro_owners(state) do
    Enum.reduce(state.macro_owners, Map.merge(state, %{macro_owners: %{}, macro_owner_regions: %{}, macro_owner_cells: %{}}),
      fn {cell, owner}, s -> put_macro_owner(s, cell, owner) end)
  end

  @doc "写一个宏格的归属（nil 即删除），同步维护派生索引。"
  def put_macro_owner(state, cell, owner) do
    old = Map.get(state.macro_owners, cell)
    region = region_of(cell)
    cells = state.macro_owner_cells |> index_cell_if(old, cell, false) |> index_cell_if(owner, cell, true)

    if owner == nil do
      %{state | macro_owners: Map.delete(state.macro_owners, cell),
        macro_owner_regions: put_region_cell(state.macro_owner_regions, region, cell, %{}), macro_owner_cells: cells}
    else
      %{state | macro_owners: Map.put(state.macro_owners, cell, owner),
        macro_owner_regions: Map.update(state.macro_owner_regions, region, %{cell => owner}, &Map.put(&1, cell, owner)),
        macro_owner_cells: cells}
    end
  end

  @doc "这些 L0 区域内的 `{宏格, 归属}`。"
  def macro_owners_in_regions(state, regions),
    do: regions |> Enum.uniq() |> Enum.flat_map(&Map.to_list(Map.get(state.macro_owner_regions, &1, %{})))

  defp index_cell_if(index, nil, _cell, _add?), do: index
  defp index_cell_if(index, owner, cell, add?), do: index_cell(index, owner, cell, add?)

  # ---- attachments 的派生索引（可由 attachments 重建，不持久化、不是第二真值）
  #
  # attachment_regions：L0 区域 => 锚点在该区的 %{附件槽 => 值}（`Attachments.region/1`，与区域换基底同一归属）。
  # 子表随值一起存：未写的区域子表与提交前是同一个值，比较提交前后只碰写过的区域，改值也看得见。
  # 只由 put_attachments/2、drop_attachments/2 与 index_attachments/1 写，随 attachments 的每次写入同步更新，
  # 让按格／按区域找附件只碰相关区域，不随世界附件总数线性扫描（M1：单格编辑每笔曾多次整表展开全部附件）。

  @doc "按 attachments 整表重建派生索引：载入、整体替换附件表（目录迁移、GM、维护入口）后调用，单测核对增量结果。"
  def index_attachments(state),
    do: Map.put(state, :attachment_regions,
      Enum.reduce(state.attachments, %{}, fn {slot, value}, index -> put_region_cell(index, Attachments.region(slot), slot, value) end))

  @doc "写入（新增或改值）附件槽，同步维护派生索引。"
  def put_attachments(state, entries) do
    %{state | attachments: Map.merge(state.attachments, entries),
      attachment_regions: Enum.reduce(entries, state.attachment_regions,
        fn {slot, value}, index -> put_region_cell(index, Attachments.region(slot), slot, value) end)}
  end

  @doc "删除附件槽，同步维护派生索引。"
  def drop_attachments(state, slots) do
    %{state | attachments: Map.drop(state.attachments, slots),
      attachment_regions: Enum.reduce(slots, state.attachment_regions, fn slot, index ->
        if Map.has_key?(state.attachments, slot), do: drop_region_cell(index, Attachments.region(slot), slot), else: index
      end)}
  end

  @doc "锚点在这些 L0 区域内的附件槽，按槽排序（与小表的整表遍历次序相同，大表时为确定次序）。"
  def attachments_in_regions(state, regions),
    do: regions |> Enum.uniq() |> Enum.flat_map(&Map.keys(Map.get(state.attachment_regions, &1, %{}))) |> Enum.sort()

  @doc """
  锚点可能投到这些 L1 父格上的附件 `{slot, value}`（按槽排序），供 `Attachments.l1_faces/2` 只看相关区域：
  面槽归父格 p 时锚点宏格在 2p..2p+2（另一侧支撑按锚点 −1 微格归属，多出 +2）。
  """
  def attachments_near_parents(state, parents) do
    regions = for {x, y, z} <- parents, dx <- 0..2, dy <- 0..2, dz <- 0..2, do: region_of({2 * x + dx, 2 * y + dy, 2 * z + dz})
    for slot <- attachments_in_regions(state, regions), do: {slot, Map.fetch!(state.attachments, slot)}
  end

  @doc "锚点在 L0 区域 core 及一宏格 ring 内可能出现的附件（本区与 26 邻区），供 `Attachments.extract/2` 只看相关区域。"
  def attachments_around_region(state, {rx, ry, rz}) do
    regions = for x <- (rx - 1)..(rx + 1), y <- (ry - 1)..(ry + 1), z <- (rz - 1)..(rz + 1), do: {x, y, z}
    Map.take(state.attachments, attachments_in_regions(state, regions))
  end

  @doc "before 有、state 里被删或改了值的附件 `{槽, 提交前值}`（按槽排序）：只比较索引里子表不同的区域。"
  def changed_attachments(before, state) do
    for {region, slots} <- before.attachment_regions, (now = Map.get(state.attachment_regions, region, %{})) != slots,
        {slot, value} <- slots, Map.get(now, slot) != value do
      {slot, value}
    end
    |> Enum.sort()
  end

  @doc "before 有而 state 没有的附件槽（按槽排序）。"
  def dropped_attachments(before, state),
    do: for({slot, _} <- changed_attachments(before, state), not Map.has_key?(state.attachments, slot), do: slot)

  @doc "这些 L0 区域内的 refined 宏格。"
  def refined_in_regions(state, regions),
    do: Enum.reduce(regions, MapSet.new(), &MapSet.union(&2, MapSet.new(Map.keys(Map.get(state.refined_regions, &1, %{})))))

  @doc "提交前后槽不同的 refined 宏格：只在区域子表不同的区域里逐格比较（未写的区域子表与提交前是同一个值）。"
  def changed_refined_cells(before, state) do
    regions = Enum.uniq(Map.keys(before.refined_regions) ++ Map.keys(state.refined_regions))

    for region <- regions, (old = Map.get(before.refined_regions, region, %{})) != (new = Map.get(state.refined_regions, region, %{})),
        cell <- Enum.uniq(Map.keys(old) ++ Map.keys(new)), Map.get(old, cell) != Map.get(new, cell),
        do: cell
  end

  defp put_region_cell(index, region, cell, slots) when map_size(slots) == 0, do: drop_region_cell(index, region, cell)
  defp put_region_cell(index, region, cell, value), do: Map.update(index, region, %{cell => value}, &Map.put(&1, cell, value))

  defp drop_region_cell(index, region, cell) do
    case Map.fetch(index, region) do
      {:ok, cells} ->
        cells = Map.delete(cells, cell)
        if map_size(cells) == 0, do: Map.delete(index, region), else: Map.put(index, region, cells)

      :error ->
        index
    end
  end


  @doc """
  refined 中这些宏格的 `{cell, slots}`，按全量遍历 `state.refined` 的次序：按部件累加（浮点 HP 求和、代表格、
  观察格列表）与逐格扫描整表的结果逐项相同。只走宏格层（不展开槽），代价随 refined 宏格数而非槽数。
  （实测子 map 的遍历次序与整表的相对次序并不总一致，所以不另建子 map 遍历。）
  """
  def in_refined_order(state, cells),
    do: for({cell, slots} <- state.refined, MapSet.member?(cells, cell), do: {cell, slots})

  defp slot_owners(slots), do: for({_, {_, owner}} <- slots, into: MapSet.new(), do: owner)

  defp index_owners(index, cell, added, removed) do
    index = Enum.reduce(added, index, fn owner, index -> index_cell(index, owner, cell, true) end)
    Enum.reduce(removed, index, fn owner, index -> index_cell(index, owner, cell, false) end)
  end

  defp index_cell(index, key, cell, true), do: Map.update(index, key, MapSet.new([cell]), &MapSet.put(&1, cell))

  defp index_cell(index, key, cell, false) do
    case Map.fetch(index, key) do
      {:ok, cells} ->
        cells = MapSet.delete(cells, cell)
        if MapSet.size(cells) == 0, do: Map.delete(index, key), else: Map.put(index, key, cells)

      :error ->
        index
    end
  end

  @doc "区域基底或 baseline source 的已解码载荷；读 source 时把解码结果缓存进 state。"
  def decoded(state, level, region) do
    key = {level, region}

    case Map.fetch(state.region_bases, key) do
      {:ok, payload} -> {:ok, payload, state}
      :error -> decoded_source(state, key)
    end
  end

  @doc "baseline source 的已解码载荷（带解码缓存）。"
  def decoded_source(state, {level, region} = key) do
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

  @doc "某级 canonical 格的 `{material, skins}`：overlay 优先，其次区域基底与 baseline。"
  def cell_value(state, level, cell) do
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

  @doc "格所在的 64³ region 坐标。"
  def region_of({x, y, z}), do: {floor_div(x, 64), floor_div(y, 64), floor_div(z, 64)}

  @doc "向负无穷取整的整数除法。"
  def floor_div(a, b), do: div(a - rem(rem(a, b) + b, b), b)

  @doc "微格坐标处的实占用目标（refined 微格或整宏格）；空气与有限数量之上的空位为 nil。"
  def target_at(micro, state) do
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

  @doc """
  提交前（before）这些宏格上实占目标（`target_at/2`）的 damage 行：未细分格的宏格行，refined 格逐槽的微格热节点行（granularity 1）
  与部件行（granularity 2，只取代表坐标落在这些格里的）。damage 无过期行——每行的键都等于其坐标上实占目标的键
  （`test/support/damage_invariant.exs`）——时，与整表筛出代表坐标落在这些格里的 0／1／2 行相同，代价只随这些格的槽数。
  读提交前的格值时借用本笔（state）已解码的源基线（不可变），不在 World 里重读；区域基底仍只用提交前的（换基底会并入编辑）。
  """
  def damage_rows_in(before, state, cells) do
    {keys, _} =
      Enum.reduce(cells, {MapSet.new(), %{before | decoded: Map.merge(state.decoded, before.decoded)}}, fn cell, {keys, at} ->
        case Map.fetch(before.refined, cell) do
          {:ok, slots} ->
            {for({slot, {material, {birth, _} = owner}} <- slots, key <- [{1, Prefab.micro_coord(cell, slot), birth, owner, material}, {2, owner}],
               into: keys, do: key), at}

          :error ->
            case target_at(cell |> Tuple.to_list() |> Enum.map(&(&1 * @micro)) |> List.to_tuple(), at) do
              {nil, at} -> {keys, at}
              {target, at} -> {MapSet.put(keys, Damage.key(target)), at}
            end
        end
      end)

    for key <- Enum.sort(keys), {:ok, row} <- [Map.fetch(before.damage, key)], MapSet.member?(cells, Damage.macro(row)), do: row
  end

  @doc "目标当前的属性记录：已有稀疏记录合并目标身份，否则按目录、环境与实占用派生默认记录。"
  def property_state(state, target, component_hp \\ nil) do
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
                if is_nil(component_hp), do: attachment_max_hp(state, target), else: component_hp

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

  @doc "部件全部微格的最大 HP 之和。"
  def component_max_hp(state, owner) do
    for cell <- micro_owner_cells(state, MapSet.new([owner])),
        {_, {material, id}} <- Map.fetch!(state.refined, cell),
        id == owner,
        reduce: 0.0 do
      hp -> hp + Damage.max_hp(Map.fetch!(state.properties.materials, material), 1)
    end
  end

  @doc "同一附件实例占用的全部槽。"
  def attachment_slots(state, id), do: for({slot, {^id, _}} <- state.attachments, do: slot)

  @doc "附件整件最大 HP，按实例槽的材料量折算；slots 缺省为该实例当前全部槽。"
  def attachment_max_hp(state, target, slots \\ nil),
    do:
      state.properties.materials[target.material]["max_hp_per_macro"] *
        Attachments.units(slots || attachment_slots(state, target.incarnation), state.properties) /
        (@micro * @micro * @micro * state.material_units_per_micro)

  @doc "两个目标是否为同一实占用身份（坐标、实例、归属、材质）。"
  def same_target?(a, b),
    do:
      Enum.all?(
        [:micro, :incarnation, :owner, :material],
        &(Map.fetch!(a, &1) == Map.fetch!(b, &1))
      )

  # 脚下宏格：position 是胶囊中心，feet = 中心下移半高；+0.5 容忍贴地 skin（同 NPC Body 的脚格约定）。
  # 施法留热与走火只能作为未细分宏格的有限热源落地；脚下不是这样的格（腾空、细分构件、空气）时拒绝施放。
  @doc "角色脚下的未细分热宏格；脚下不是这样的格时 `{:error, :no_footing, state}`。"
  def foot_target(state, actor) do
    {fx, fy, fz} = actor.feet
    {x, y, z} = {floor(fx), floor(fy + 0.5) - 1, floor(fz)}

    case target_at({x * @micro + 4, y * @micro, z * @micro + 4}, state) do
      {%{granularity: 0} = foot, state} ->
        if heat_node?(state, foot), do: {:ok, foot, state}, else: {:error, :no_footing, state}

      {_, state} ->
        {:error, :no_footing, state}
    end
  end

  @doc "目录材质是否有热容量。"
  def heat_node?(state, target),
    do: is_number(state.properties.materials[target.material]["heat_capacity_per_macro"])

  @doc "燃烧与燃料计算用的目标体积（宏格按有限数量折算）。"
  def combustion_volume(state, %{granularity: 4} = target),
    do: VoxelRegion.ThermalAttachments.volume(Attachments.slot(target), state.properties)

  def combustion_volume(state, target), do: Damage.volume(target.granularity) * finite_volume(state, target)

  @doc "材质是否启用相态。"
  def phase_material?(s,m), do: s.properties != nil and Phase.enabled?(s.properties.materials[m])

  @doc "目标是否为相态宏格。"
  def phase_target?(s,t), do: t.granularity == 0 and phase_material?(s,t.material)

  # 格所在气候区的环境温度：未记录格的默认温度、相变天然温度、静止判据与显热参考（VoxelRegion.Climate.air_k/2）。
  @doc "宏格所在气候区的空气温度。"
  def ambient_at(s, cell), do: VoxelRegion.Climate.air_k(s.thermal.config, cell)

  # R8-07 散体：目录 loose_threshold_units 即可倾倒；格有数量记录（liquid_units 条目）才是散体，天然地形与建造格静止。
  @doc "材质是否为可倾倒散体。"
  def loose_material?(s,m), do: s.properties != nil and Map.has_key?(Map.get(s.properties.materials,m,%{}),"loose_threshold_units")

  @doc "目标是否为带数量记录的散体宏格。"
  def loose_cell?(s,t), do: t.granularity == 0 and loose_material?(s,t.material) and Map.has_key?(s.liquid_units,Damage.macro(t))

  # 数量记录决定实占用高度（射线、热几何按填充高度截断）的材料。
  @doc "材质的实占用高度是否由数量记录决定。"
  def finite_material?(s,m), do: phase_material?(s,m) or loose_material?(s,m)

  # 有限宏格：相态宏格与有数量记录的散体；其能量、完整度、燃料随数量搬运。
  @doc "目标是否为有限宏格（相态宏格或带数量记录的散体）。"
  def finite_target?(s,t), do: phase_target?(s,t) or loose_cell?(s,t)

  # 唯一的有限体积：宏格有数量记录时为 q / 单格容量，其余（无记录的满宏格、微格、附件）为 1；
  # 用于最大 HP、热采样、燃烧燃料与功率、转化体积和回收。数量按宏格存储（与液体相同），refined 宏格不带数量。
  @doc "目标的有限体积比例（有数量记录的宏格为 q / 单格容量，其余为 1）。"
  def finite_volume(s,%{granularity: 0}=t),
    do: Map.get(s.liquid_units,Damage.macro(t),liquid_capacity(s))/liquid_capacity(s)

  def finite_volume(_s,_t), do: 1.0

  @doc "单个宏格的数量容量。"
  def liquid_capacity(state), do: state.material_units_per_micro * @micro * @micro * @micro
end
