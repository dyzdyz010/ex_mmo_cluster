defmodule VoxelRegion.World.Canonical do
  @moduledoc """
  全局系统功能：`VoxelRegion.World` 状态上的 canonical 读取与材料判定。

  只读 World 的权威状态（overlay、区域基底、refined、稀疏属性记录、有限数量与目录）；读取 baseline 时
  返回带解码缓存的新 state，从不写真值。World 与热模拟（`VoxelRegion.World.Thermal`）共用这一份读取语义。
  """
  alias VoxelRegion.{Attachments, Damage, Phase, Prefab}
  alias MmoContracts.Voxel.Payload

  @micro VoxelRegion.Spatial.micro_resolution()

  @doc "持有给定部件身份微格的 refined 宏格。"
  def micro_owner_cells(state,ids) do
    for {cell,slots} <- state.refined,
      Enum.any?(slots,fn {_,{_,owner}} -> MapSet.member?(ids,owner) end),do: cell
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

  @doc "附件整件最大 HP，按实例槽的材料量折算。"
  def attachment_max_hp(state, target),
    do:
      state.properties.materials[target.material]["max_hp_per_macro"] *
        Attachments.units(attachment_slots(state, target.incarnation), state.properties) /
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
