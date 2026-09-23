defmodule VoxelRegion.Damage do
  @moduledoc "B1 immutable property lookup and exact canonical micro-grid ray traversal."

  @micro VoxelRegion.Spatial.micro_resolution()

  def load(path) do
    bytes = File.read!(path)
    data = Jason.decode!(bytes)
    true = data["schema_version"] in [1, 2]

    specification =
      if data["schema_version"] == 2 do
        a = Map.fetch!(data, "attachments")
        units = Map.fetch!(a, "material_units_per_micro")
        true = is_integer(units) and units > 0 and units * @micro * @micro * @micro <= 0xFFFFFFFF

        true =
          Enum.all?(
            ~w(face_thickness_m line_section_m2 line_display_width_m),
            &(is_number(a[&1]) and a[&1] > 0)
          )

        face = units * a["face_thickness_m"] * @micro
        edge = units * a["line_section_m2"] * @micro * @micro

        true =
          Enum.all?(
            [face, edge],
            &(&1 >= 1 and &1 == round(&1) and &1 * @micro * @micro <= 0xFFFFFFFF)
          )

        Map.merge(a, %{"face_units" => round(face), "edge_units" => round(edge)})
      end

    materials = Map.new(data["materials"], &{&1["material_id"], &1})
    tools = Map.new(data["tools"], &{&1["tool_id"], &1})
    tags = MapSet.new(data["tags"], & &1["id"])
    true = MapSet.member?(tags, "damage")

    true =
      map_size(materials) == length(data["materials"]) and
        map_size(tools) == length(data["tools"])

    true = Enum.all?(0..23, &Map.has_key?(materials, &1))

    true =
      Enum.all?(materials, fn {id, m} ->
        is_number(m["max_hp_per_macro"]) and (id == 0 or m["max_hp_per_macro"] > 0) and
          is_number(m["defense"]) and m["defense"] >= 0 and
          Enum.all?(m["tags"], &MapSet.member?(tags, &1)) and
          Enum.any?(m["responses"], &(&1["action"] == "damage")) and
          length(Enum.uniq_by(m["responses"], & &1["action"])) == length(m["responses"]) and
          Enum.all?(m["responses"], fn r ->
            MapSet.member?(tags, r["action"]) and
              is_number(r["multiplier"]) and r["multiplier"] >= 0
          end)
      end)

    # 可选：掉落表（销毁时按概率发放，取代整格回收）与放置用量（薄片类材料一格不足一整格量子）。
    true =
      Enum.all?(materials, fn {_, m} ->
        (is_nil(m["place_units"]) or (is_integer(m["place_units"]) and m["place_units"] > 0)) and
          Enum.all?(m["drops"] || [], fn d ->
            Map.has_key?(materials, d["material_id"]) and d["material_id"] != 0 and
              is_integer(d["units"]) and d["units"] > 0 and
              is_number(d["probability"]) and d["probability"] > 0 and d["probability"] <= 1
          end)
      end)

    true =
      Enum.all?(tools, fn {id, t} ->
        id in 1..65535 and t["power"] > 0 and
          t["range_macro"] > 0 and t["interval_seconds"] > 0 and MapSet.member?(tags, t["action"]) and
          (t["action"] in ~w(heat circuit.install circuit.toggle circuit.feed damage liquid.scoop liquid.pour phase.heat phase.cool) or
             String.starts_with?(t["action"], "damage.") or
             String.starts_with?(t["action"], "combustion."))
      end)

    true =
      Enum.all?(tools, fn {_, t} ->
        t["action"] != "heat" or
          (Map.has_key?(materials, t["fuel_material_id"]) and t["fuel_material_id"] != 0 and
             is_integer(t["fuel_units"]) and t["fuel_units"] > 0 and
             is_number(t["heat_energy_j"]) and t["heat_energy_j"] > 0 and
             is_number(t["heat_power_w"]) and t["heat_power_w"] > 0)
      end)

    # B1 已发布目录没有热字段；带热模型的材料必须完整提供有量纲参数。
    true =
      Enum.all?(materials, fn {_, m} ->
        not Map.has_key?(m, "electrical_conductivity") or
          (is_number(m["electrical_conductivity"]) and m["electrical_conductivity"] >= 0 and
             is_number(m["heat_capacity_per_macro"]) and m["heat_capacity_per_macro"] > 0)
      end)

    true =
      Enum.all?(tools, fn {_, t} ->
        case t["action"] do
          "circuit.install" ->
            t["circuit_kind"] in 1..5 and is_number(t["circuit_resistance_ohm"]) and
              t["circuit_resistance_ohm"] > 0 and
              is_number(t["circuit_voltage_v"]) and t["circuit_voltage_v"] >= 0 and
              (t["circuit_kind"] != 1 or t["circuit_voltage_v"] > 0) and
              is_number(t["circuit_light_fraction"]) and t["circuit_light_fraction"] >= 0 and
              t["circuit_light_fraction"] <= 1 and
              (t["circuit_kind"] == 3 or t["circuit_light_fraction"] == 0) and
              (t["circuit_kind"] != 5 or
                (is_number(t["circuit_cooling_cop"]) and t["circuit_cooling_cop"] > 0 and
                 is_number(t["circuit_min_kelvin"]) and t["circuit_min_kelvin"] > 0))

          "circuit.feed" ->
            Map.has_key?(materials, t["fuel_material_id"]) and t["fuel_material_id"] != 0 and
              is_integer(t["fuel_units"]) and t["fuel_units"] > 0 and
              is_number(t["circuit_energy_j"]) and t["circuit_energy_j"] > 0

          action when action in ["liquid.scoop", "liquid.pour"] ->
            is_integer(t["liquid_transfer_units"]) and t["liquid_transfer_units"] > 0 and
              t["liquid_transfer_units"] <= (if specification, do: specification["material_units_per_micro"], else: 1) * @micro * @micro * @micro

          action when action in ["combustion.ignite", "phase.heat"] ->
            Map.has_key?(materials, t["fuel_material_id"]) and t["fuel_material_id"] != 0 and
              is_integer(t["fuel_units"]) and t["fuel_units"] > 0 and
              is_number(t["heat_energy_j"]) and t["heat_energy_j"] > 0

          action when action in ["combustion.extinguish", "phase.cool"] ->
            Map.has_key?(materials, t["fuel_material_id"]) and t["fuel_material_id"] != 0 and
              is_integer(t["fuel_units"]) and t["fuel_units"] > 0 and
              is_number(t["cooling_energy_j"]) and t["cooling_energy_j"] > 0

          _ ->
            true
        end
      end)

    true =
      Enum.all?(materials, fn {_, m} ->
        fields = ~w(heat_capacity_per_macro thermal_conductivity heat_resistance_kelvin)

        not Enum.any?(fields, &Map.has_key?(m, &1)) or
          (Enum.all?(fields, &is_number(m[&1])) and m["heat_capacity_per_macro"] > 0 and
             m["thermal_conductivity"] >= 0 and m["heat_resistance_kelvin"] > 0)
      end)

    true =
      Enum.all?(materials, fn {_, m} ->
        Enum.all?(~w(ignition_kelvin fuel_energy_per_macro_j burn_power_per_macro_w), fn key ->
          not Map.has_key?(m, key) or (is_number(m[key]) and m[key] >= 0)
        end)
      end)

    for {id, m} <- materials, Map.has_key?(m, "phase_peer_material_id") do
      true = VoxelRegion.Phase.valid_pair?(id, m["phase_peer_material_id"])
      peer = Map.fetch!(materials,m["phase_peer_material_id"])
      true = peer["phase_peer_material_id"] == if(id==4,do: 20,else: id)
      for key <- ~w(phase_transition_kelvin latent_heat_per_macro_j) do
        true = is_number(m[key]) and m[key] > 0 and m[key] == peer[key]
      end
      true = is_number(m["heat_capacity_per_macro"]) and m["heat_capacity_per_macro"] > 0
    end

    # R8 单向转化：五个字段成组出现；源与产物都带热模型且不是相态材料，还原剂可燃（剩余量即剩余燃料比例）。
    for {id, m} <- materials,
        Enum.any?(Map.keys(m), &String.starts_with?(&1, "transform_")) do
      product = Map.fetch!(materials, m["transform_material_id"])
      reductant = Map.fetch!(materials, m["transform_reductant_material_id"])
      true = m["transform_material_id"] not in [0, id]
      true = Enum.all?([m, product], &(is_number(&1["heat_capacity_per_macro"]) and not VoxelRegion.Phase.enabled?(&1)))
      true = VoxelRegion.Combustion.combustible?(reductant)
      true = is_number(m["transform_kelvin"]) and m["transform_kelvin"] > 0
      true = is_number(m["transform_heat_per_macro_j"]) and m["transform_heat_per_macro_j"] >= 0
      true = is_number(m["transform_reductant_units_per_unit"]) and m["transform_reductant_units_per_unit"] > 0
    end

    liquid = data["liquid"]
    if liquid do
      capacity = (if specification, do: specification["material_units_per_micro"], else: 1) * @micro * @micro * @micro
      true = is_number(liquid["step_seconds"]) and liquid["step_seconds"] > 0
      threshold = Map.get(liquid,"side_threshold_units",0)
      true = is_integer(threshold) and threshold >= 0 and threshold <= capacity
      true = Enum.all?(~w(gravity_units_per_step side_units_per_step),
        &(is_integer(liquid[&1]) and liquid[&1] > 0 and liquid[&1] <= capacity))
    end
    %{
      liquid: liquid,
      digest: :crypto.hash(:sha256, bytes),
      materials: materials,
      tools: tools,
      attachments: specification
    }
  end

  @doc "既有库存的整数精度；旧 B1–B3 内容保持一单位一微格。"
  def material_units(%{attachments: %{"material_units_per_micro" => units}}), do: units
  def material_units(_), do: 1

  def volume(0), do: 1.0
  def volume(1), do: 1.0 / (@micro * @micro * @micro)
  def volume(2), do: 1.0
  def max_hp(material, granularity), do: material["max_hp_per_macro"] * volume(granularity)

  def amount(material, tool, granularity) do
    response =
      material["responses"]
      |> Enum.filter(fn r ->
        tool["action"] == r["action"] or String.starts_with?(tool["action"], r["action"] <> ".")
      end)
      |> Enum.max_by(&String.length(&1["action"]))

    max(0.0, tool["power"] - material["defense"]) * response["multiplier"] * volume(granularity)
  end

  @doc "GCRA：一个权威 tick 的相位借用，成功后按理论到达时间偿还；不累积空闲额度。"
  def admit_attack(previous, seq, now, interval, tolerance) do
    cond do
      previous != nil and seq <= previous.seq ->
        {:error, :replayed_attack}

      previous != nil and now < previous.next_us - tolerance ->
        {:error, :tool_cooldown}

      true ->
        next = if previous, do: max(now, previous.next_us), else: now
        {:ok, %{seq: seq, next_us: next + interval}}
    end
  end

  def key(%{granularity: 3, owner: {id, _}}), do: {3, id}
  def key(%{granularity: 2, owner: owner}), do: {2, owner}
  def key(t), do: {t.granularity, t.micro, t.incarnation, t.owner, t.material}

  def macro(%{micro: {x, y, z}}),
    do: {Integer.floor_div(x, @micro), Integer.floor_div(y, @micro), Integer.floor_div(z, @micro)}

  # Amanatides-Woo traversal at canonical 1/8 m, including the starting cell.
  def raycast(origin, direction, range, state, at) do
    cell = origin |> Tuple.to_list() |> Enum.map(&floor(&1 * @micro)) |> List.to_tuple()

    axes =
      for i <- 0..2 do
        d = elem(direction, i)
        step = if d < 0, do: -1, else: 1

        if d == 0.0 do
          {step, 1.0e100, 1.0e100}
        else
          boundary = (elem(cell, i) + if(step > 0, do: 1, else: 0)) / @micro
          {step, (boundary - elem(origin, i)) / d, abs(1.0 / @micro / d)}
        end
      end

    walk(cell, axes, range, state, at)
  end

  defp walk(cell, axes, range, state, at) do
    case at.(cell, state) do
      {nil, state} ->
        {_, distance, _} = Enum.min_by(axes, &elem(&1, 1))

        if distance > range do
          {:error, :no_target, state}
        else
          # Simultaneous boundary crossings do not fabricate an edge-only hit.
          {cell, axes} =
            axes
            |> Enum.with_index()
            |> Enum.map_reduce(cell, fn {{step, t, delta}, i}, cell ->
              if abs(t - distance) < 1.0e-10,
                do: {{step, t + delta, delta}, put_elem(cell, i, elem(cell, i) + step)},
                else: {{step, t, delta}, cell}
            end)
            |> then(fn {axes, cell} -> {cell, axes} end)

          walk(cell, axes, range, state, at)
        end

      {target, state} ->
        {:ok, target, state}
    end
  end
  @doc "实际 HP 损失同步扣除采回完整度基准；采回操作本身不免费修复。"
  def pick_baseline(target, hp) do
    case Map.fetch(target, :pick_baseline_hp) do
      {:ok, baseline} -> Map.put(target, :pick_baseline_hp, max(0.0, baseline - (target.hp - hp)))
      :error -> target
    end
  end

end
