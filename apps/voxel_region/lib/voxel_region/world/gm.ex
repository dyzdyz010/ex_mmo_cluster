defmodule VoxelRegion.World.Gm do
  @moduledoc """
  只测试（Test-only）GM 施工工具，不进分发：一次清空、一次填满、一次灌满、原样搬移 prefab 实例。

  - **开关**：只有部署显式设 `VOXIM_GM_TOOLS=1`（`config :voxel_region, :gm_tools`，测试可用 World opt `:gm_tools`）
    时 World 才接受；分发配置不设，默认关闭，调用回 `{:error, :gm_disabled}`。不接 Gate，只经 harness rpc。
  - **跳过**：耐久与 HP、工具冷却、射程与视线、库存扣减与退料、受保护区域。
  - **保留**：每个操作是一笔正常 World 提交，复用玩家／作者编辑的同一条链路——`Edits.apply_batch`（填）、
    `Prefabs.prefab_reply`（清，含细化格与实例）、`Prefabs.place_tree`（搬移）、`Liquids.commit_liquid`（灌）——
    日志、检查点、广播、碰撞、液体唤醒与普通编辑相同；不另造状态路径、不直写数据库。
  - **审计与防重**：回执 `material_supplies[{0, {:gm, key}}] = %{seq, op, args, ...}` 随该笔事务进日志与检查点，
    同 key 只执行一次（重试返回原回执）；每次执行另打一行 `voxel_gm` 结构化日志。
  - **规模**：单次至多 #{4096} 个宏格（清／填的盒、灌的洪泛格），超出整笔拒绝 `:gm_too_large`，由调用方分批。

  坐标：canonical Y-up；`precision: :macro` 时盒为宏格闭区间，`:micro` 时为微格（1/8 m）闭区间。
  细化格的每个微格都属于某个 prefab 实例（VXR5 线格式要求 owner 是活实例），所以：微格清只清实例微格
  （须 `instances: true`）与被盒完整覆盖的宏格；微格填只填被盒完整覆盖的空气宏格，部分覆盖的宏格跳过（回执记数），
  需要真正的微格几何时发布 prefab 再放置。
  """
  require Logger
  import VoxelRegion.World.Canonical
  alias VoxelRegion.{Phase, Prefab}
  alias VoxelRegion.World.{Edits, Liquids, Payloads, Prefabs}

  @max_macros 4096
  @micro VoxelRegion.Spatial.micro_resolution()

  @doc "部署开关（Scene 侧 GM 瞬移也读它）。"
  def enabled?, do: Application.get_env(:voxel_region, :gm_tools, false) == true

  @doc "World 调用：key 防重后执行一个操作；返回 GenServer reply 三元组。"
  def run(%{gm_tools: false} = state, _key, _op, _args), do: {:reply, {:error, :gm_disabled}, state}

  def run(state, key, op, args) when is_binary(key) and byte_size(key) > 0 do
    receipt_key = {0, {:gm, key}}

    case Map.fetch(state.material_supplies, receipt_key) do
      {:ok, receipt} ->
        {:reply, {:ok, receipt}, state}

      :error ->
        receipt = %{seq: state.seq + 1, op: op, args: args}

        case operate(op, state, args, receipt_key, receipt) do
          {:ok, receipt, next} ->
            true = next.seq == receipt.seq
            Logger.info("voxel_gm key=#{inspect(key)} op=#{op} seq=#{receipt.seq} receipt=#{inspect(Map.delete(receipt, :args))} args=#{inspect(args)}")
            {:reply, {:ok, receipt}, next}

          {:error, reason} ->
            Logger.info("voxel_gm key=#{inspect(key)} op=#{op} rejected=#{inspect(reason)} args=#{inspect(args)}")
            {:reply, {:error, reason}, state}
        end
    end
  end

  def run(state, _key, _op, _args), do: {:reply, {:error, :invalid_gm_args}, state}

  @doc "清／填涉及的宏格（供 World 在调用前准备来源区域）；参数非法返回 []。"
  def macros(%{box: {{_, _, _} = lo, {_, _, _} = hi}} = args) do
    {lo, hi} = macro_box(lo, hi, Map.get(args, :precision, :macro))
    if Enum.all?(0..2, &(elem(lo, &1) <= elem(hi, &1))) and volume(lo, hi) <= @max_macros,
      do: for(x <- elem(lo, 0)..elem(hi, 0), y <- elem(lo, 1)..elem(hi, 1), z <- elem(lo, 2)..elem(hi, 2), do: {x, y, z}),
      else: []
  end

  def macros(_), do: []

  defp operate(:clear, state, %{box: {lo, hi}} = args, rkey, receipt) do
    precision = Map.get(args, :precision, :macro)
    instances? = Map.get(args, :instances, false)

    with {:ok, cells} <- box_macros(lo, hi, precision) do
      state = ensure(state, cells)
      {next, changed} =
        Enum.reduce(cells, {state, []}, fn cell, {s, changed} ->
          slots = Map.get(s.refined, cell, %{})
          kept = if instances?,
            do: Map.reject(slots, fn {slot, _} -> in_box?(Prefab.micro_coord(cell, slot), lo, hi, precision) end),
            else: slots
          {:ok, {material, _}, s} = cell_value(s, 0, cell)
          clear_macro? = slots == %{} and material != 0 and covered?(cell, lo, hi, precision) and
            (instances? or not Map.has_key?(s.macro_owners, cell))

          cond do
            kept != slots ->
              {put_refined(s, cell, kept), [cell | changed]}

            clear_macro? ->
              s = %{s | macro_owners: Map.delete(s.macro_owners, cell), placed_by: Map.delete(s.placed_by, cell),
                liquid_units: Map.delete(s.liquid_units, cell)}
              {Edits.put_overlay(s, 0, cell, {0, MmoContracts.Voxel.Skins.uniform(0)}), [cell | changed]}

            true ->
              {s, changed}
          end
        end)

      if changed == [] do
        {:error, :gm_noop}
      else
        receipt = Map.merge(receipt, %{cells: length(changed)})
        next = prune_instances(audit(next, rkey, receipt))
        reply(Prefabs.prefab_reply(state, next, Enum.reverse(changed), %{material_supplies: %{rkey => receipt}}), receipt)
      end
    end
  end

  defp operate(:fill, state, %{box: {lo, hi}, material: material} = args, rkey, receipt) do
    precision = Map.get(args, :precision, :macro)

    with true <- (is_integer(material) and material > 0 and Map.has_key?(state.properties.materials, material)) ||
                   {:error, :invalid_gm_args},
         {:ok, cells} <- box_macros(lo, hi, precision) do
      state = ensure(state, cells)
      {full, partial} = Enum.split_with(cells, &covered?(&1, lo, hi, precision))
      {targets, state} =
        Enum.reduce(full, {[], state}, fn cell, {acc, s} ->
          {:ok, {m, _}, s} = cell_value(s, 0, cell)
          {if(m == 0 and not Map.has_key?(s.refined, cell), do: [cell | acc], else: acc), s}
        end)
      finite? = Phase.liquid?(material) or phase_material?(state, material)

      cond do
        targets == [] -> {:error, :gm_noop}
        finite? and not Enum.all?(targets, &Liquids.liquid_inside?(&1, state.liquid_bounds)) -> {:error, :outside_liquid_bounds}
        true ->
          targets = Enum.reverse(targets)
          receipt = Map.merge(receipt, %{cells: length(targets), partial_skipped: length(partial)})
          {state, settlement} = if finite?, do: finite_fill(state, targets, material), else: {state, %{}}
          state = audit(state, rkey, receipt)
          settlement = Map.put(settlement, :material_supplies, %{rkey => receipt})
          with {:ok, next} <- Edits.apply_batch(state, Enum.map(targets, &{&1, material}), false, settlement),
            do: {:ok, receipt, next}
      end
    end
  end

  defp operate(:liquid_fill, state, %{seed: seed, level_y: level_y, material: material} = args, rkey, receipt),
    do: Liquids.gm_liquid_fill(state, material, seed, level_y, Map.get(args, :max_cells, @max_macros), rkey,
      Map.put(receipt, :material, material))

  defp operate(:move_instance, state, %{instance: id, anchor: anchor, orientation: orientation}, rkey, receipt) do
    with {:ok, instance} <- Prefabs.fetch_instance(state, id),
         true <- Map.get(instance, :parent_id, {0, 0}) == {0, 0} || {:error, :not_top_level},
         true <- orientation in 0..3 || {:error, :invalid_gm_args},
         {:ok, definition} <- Map.fetch(state.prefabs, instance.definition_id) |> found() do
      ids = Prefabs.subtree_ids(state, id)
      cells = Prefabs.subtree_cells(state, ids)
      receipt = Map.merge(receipt, %{instance: {state.seq + 1, 0}, from: instance.anchor, from_orientation: instance.orientation})
      next = audit(Prefabs.clear_subtree(state, ids, cells), rkey, receipt)
      # 同一笔：清旧树 + 按定义在新锚点放置；新位置占用由 place_tree 在当前权威里判，不扣料不退料。
      reply(Prefabs.place_tree(state, next, definition, anchor, orientation, {0, 0}, 0, cells, nil,
        %{material_supplies: %{rkey => receipt}}), receipt)
    end
  end

  defp operate(_op, _state, _args, _rkey, _receipt), do: {:error, :invalid_gm_args}

  defp found({:ok, v}), do: {:ok, v}
  defp found(:error), do: {:error, :definition_not_found}

  defp reply({:reply, {:ok, _seq}, next}, receipt), do: {:ok, receipt, next}
  defp reply({:reply, {:error, reason}, _}, _receipt), do: {:error, reason}

  defp audit(state, rkey, receipt), do: %{state | material_supplies: Map.put(state.material_supplies, rkey, receipt)}

  # 与 liquid_experiment 相同的作者初态：相态／液体材料满格数量与环境温度下的焓，计入 phase_authored 账。
  defp finite_fill(state, cells, material) do
    m = state.properties.materials[material]
    changes = Map.new(cells, &{&1, liquid_capacity(state)})
    values = if phase_material?(state, material),
      do: Map.new(cells, &{&1, {Phase.energy(%{material: material}, 1.0, m, ambient_at(state, &1)), liquid_capacity(state) * 1.0}}),
      else: %{}
    thermal = if state.thermal, do: Enum.reduce(values, state.thermal, fn {_, {energy, integrity}}, t ->
      t |> Map.update(:phase_authored_energy_j, energy, &(&1 + energy))
        |> Map.update(:phase_authored_units, round(integrity), &(&1 + round(integrity)))
    end)
    {%{state | thermal: thermal}, %{liquid_changes: changes, phase_values: values, liquid_material: material}}
  end

  # 清掉微格后失去全部格的实例与其附件随同一笔消失（与作者移除同一规则）。
  defp prune_instances(state) do
    live = Payloads.live_instance_ids(state) |> MapSet.new()
    dead = state.instances |> Map.keys() |> MapSet.new() |> MapSet.difference(live)
    owned = for {id, {owner, _}} <- state.attachment_owners, MapSet.member?(dead, owner), into: MapSet.new(), do: id
    %{state | instances: Map.drop(state.instances, MapSet.to_list(dead)),
      attachments: Map.reject(state.attachments, fn {_, {id, _}} -> MapSet.member?(owned, id) end),
      attachment_owners: Map.drop(state.attachment_owners, MapSet.to_list(owned))}
  end

  defp ensure(state, cells) do
    for key <- Enum.uniq(Enum.map(cells, &{0, region_of(&1)})), Edits.needs_source?(state, key),
      do: :ok = state.source.ensure(state.source_state, 0, elem(key, 1))
    state
  end

  defp box_macros(lo, hi, precision) do
    with true <- (valid_point?(lo) and valid_point?(hi) and precision in [:macro, :micro]) || {:error, :invalid_gm_args},
         {mlo, mhi} = macro_box(lo, hi, precision),
         true <- Enum.all?(0..2, &(elem(mlo, &1) <= elem(mhi, &1))) || {:error, :invalid_gm_args},
         true <- volume(mlo, mhi) <= @max_macros || {:error, :gm_too_large},
         cells = macros(%{box: {lo, hi}, precision: precision}),
         true <- Enum.all?(cells, &Edits.valid_edit_coord?/1) || {:error, :invalid_coordinate} do
      {:ok, cells}
    end
  end

  defp valid_point?({x, y, z}), do: is_integer(x) and is_integer(y) and is_integer(z)
  defp valid_point?(_), do: false

  defp macro_box(lo, hi, :macro), do: {lo, hi}
  defp macro_box(lo, hi, :micro), do: {map3(lo, &Integer.floor_div(&1, @micro)), map3(hi, &Integer.floor_div(&1, @micro))}
  defp macro_box(lo, hi, _), do: {lo, hi}

  defp map3({x, y, z}, f), do: {f.(x), f.(y), f.(z)}
  defp volume({x0, y0, z0}, {x1, y1, z1}), do: (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1)

  defp covered?(_cell, _lo, _hi, :macro), do: true
  defp covered?({x, y, z}, lo, hi, :micro),
    do: in_box?({x * @micro, y * @micro, z * @micro}, lo, hi, :micro) and
      in_box?({x * @micro + @micro - 1, y * @micro + @micro - 1, z * @micro + @micro - 1}, lo, hi, :micro)

  defp in_box?(_micro, _lo, _hi, :macro), do: true
  defp in_box?({x, y, z}, {x0, y0, z0}, {x1, y1, z1}, :micro),
    do: x >= x0 and x <= x1 and y >= y0 and y <= y1 and z >= z0 and z <= z1
end
