defmodule VoxelRegion.ThermalBatchTest do
  @moduledoc "只测试：整批等价于旧 50ms 分段，事件保留 World 的结算边界。"
  use ExUnit.Case, async: false
  alias VoxelRegion.ThermalNative

  defp latent_world do
    root = Path.join(System.tmp_dir!(), "latent_batch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    materials = for id <- 0..23 do
      base = %{material_id: id, max_hp_per_macro: if(id == 0, do: 0.0, else: 100.0),
        defense: 2.0, tags: [], responses: [%{action: "damage", multiplier: 1.0}]}
      if id == 19 do
        Map.merge(base, %{heat_capacity_per_macro: 100.0, thermal_conductivity: 1.0,
          heat_resistance_kelvin: 1000.0, ignition_kelvin: 300.0,
          fuel_energy_per_macro_j: 1_000_000.0, burn_power_per_macro_w: 100.0})
      else
      if id in [20, 21], do: Map.merge(base, %{phase_peer_material_id: if(id == 20, do: 21, else: 20),
        phase_transition_kelvin: 273.15, latent_heat_per_macro_j: 1000.0,
        heat_capacity_per_macro: 100.0, thermal_conductivity: 1.0, heat_resistance_kelvin: 1000.0}), else: base
      end
    end
    catalog = Path.join(root, "catalog.json")
    File.write!(catalog, Jason.encode!(%{schema_version: 1, tags: [%{id: "damage"}], materials: materials,
      tools: [], definitions: []}))
    environment = Path.join(root, "environment.json")
    File.write!(environment, Jason.encode!(%{ambient_kelvin: 293.15, environment_w_per_m2_k: 0.0,
      tolerance_kelvin: 0.01}))
    w = start_supervised!({VoxelRegion.World, [source: VoxelRegion.DamageWorldTest.Source,
      log: VoxelRegion.DamageWorldTest.Log, root: root, observer: self(), name: nil,
      property_catalog_path: catalog, thermal_environment_path: environment]})
    :sys.suspend(w)
    s = :sys.get_state(w)
    # 只测试：固定一个完整体积、潜热已吸收一半的冰节点；无外部热源和冷板。
    row = %{micro: {0, 0, 0}, granularity: 0, owner: {0, 0}, incarnation: 1, material: 20,
      seq: s.seq, request_id: 0, hp: 100.0, max_hp: 100.0, defense: 2.0, digest: s.properties.digest,
      flags: 0, temperature_kelvin: 273.15, phase_energy_j: 500.0}
    s = %{s | damage: %{VoxelRegion.Damage.key(row) => row},
      overlay: Map.put(s.overlay, {0, {0, 0, 0}}, {20, 1}), epochs: %{{0, 0, 0} => 1},
      liquid_units: %{{0, 0, 0} => s.material_units_per_micro * 512},
      thermal: %{s.thermal | active: true},
      thermal_work: %{s.thermal_work | hot: MapSet.new([{0, 0, 0}])}}
    {w, s, row}
  end

  @tag :latent_batch
  test "潜热区无其他事件的半秒 World 批至多两次进入 NIF" do
    {w, s, row} = latent_world()
    mfa = {ThermalNative, :advance, 6}
    :erlang.trace_pattern(mfa, true, [:call_count])
    try do
      {:noreply, next} = VoxelRegion.World.handle_info(:thermal_commit, s)
      {:call_count, calls} = :erlang.trace_info(mfa, :call_count)
      IO.puts("LATENT_BATCH calls=#{calls}")
      assert calls <= 2
      assert next.damage[VoxelRegion.Damage.key(row)].phase_energy_j == 500.0
    after
      :erlang.trace_pattern(mfa, false, [:call_count])
      :sys.resume(w)
    end
  end

  test "热前沿只扩张空气时复用实体接触图，编辑后重新派生" do
    {w, s, _row} = latent_world()
    {:noreply, warm} = VoxelRegion.World.handle_info(:thermal_commit, s)
    expanded = put_in(warm.thermal_work.hot, MapSet.put(warm.thermal_work.hot, {0, 0, 2}))
    mfa = {VoxelRegion.ThermalAttachments, :add, 7}
    :erlang.trace_pattern(mfa, true, [:call_count])
    try do
      {:noreply, next} = VoxelRegion.World.handle_info(:thermal_commit, expanded)
      {:call_count, calls} = :erlang.trace_info(mfa, :call_count)
      assert calls == 0
      assert next.thermal_work.ordered == warm.thermal_work.ordered
      # 模拟既有编辑失效入口：占用变为空气，同时丢弃该格几何。
      edited = %{expanded | overlay: Map.put(expanded.overlay, {0, {0, 0, 0}}, {0, 2}),
        damage: %{}, thermal_work: %{expanded.thermal_work |
          geometry: Map.delete(expanded.thermal_work.geometry, {0, 0, 0})}}
      {:noreply, empty} = VoxelRegion.World.handle_info(:thermal_commit, edited)
      assert empty.thermal_work.ordered == []
    after
      :erlang.trace_pattern(mfa, false, [:call_count])
      :sys.resume(w)
    end
  end

  @tag :empty_geometry_batch
  test "附件空气侧合法空几何不把半秒 World 批拆成十次 NIF 调用" do
    {w, initial, row} = latent_world()
    slot = {0, 0, {8, 0, 0}}
    host = row |> Map.merge(%{material: 19, temperature_kelvin: 280.0}) |> Map.delete(:phase_energy_j)
    face = host |> Map.merge(VoxelRegion.Attachments.identity(slot, {2, 19}))
      |> Map.merge(%{granularity: 4, temperature_kelvin: 285.0})
    specification = %{"material_units_per_micro" => 4096, "face_units" => 64, "edge_units" => 1,
      "face_thickness_m" => 1 / 512, "line_section_m2" => 1 / (512 * 512)}
    s = %{initial | properties: Map.put(initial.properties, :attachments, specification),
      damage: Map.new([host, face], &{VoxelRegion.Damage.key(&1), &1}),
      overlay: Map.put(initial.overlay, {0, {0, 0, 0}}, {19, 1}), attachments: %{slot => {2, 19}},
      thermal_work: %{initial.thermal_work | hot: MapSet.new(VoxelRegion.Attachments.macros([slot]))}}
    mfa = {ThermalNative, :advance, 6}
    :erlang.trace_pattern(mfa, true, [:call_count])
    try do
      {:noreply, next} = VoxelRegion.World.handle_info(:thermal_commit, s)
      {:call_count, calls} = :erlang.trace_info(mfa, :call_count)
      IO.puts("EMPTY_GEOMETRY_BATCH calls=#{calls}")
      assert Map.fetch!(next.thermal_work.geometry, {1, 0, 0}) == []
      assert Enum.any?(next.thermal_work.ordered, fn {key, _} -> key == VoxelRegion.ThermalAttachments.key(slot) end)
      # 旧路径每次只传 50ms；直接复用真实派生的节点与接触，逐节点精确比较传热结果。
      ordered = next.thermal_work.ordered
      input = Enum.map(ordered, fn {_, n} ->
        t = Map.fetch!(s.damage, VoxelRegion.Damage.key(n.target))
        {t.temperature_kelvin, t.hp, t.max_hp, n.capacity, 1.0, 1000.0,
          n.exposed_faces * 1.0, 0.0, 0.0, true}
      end)
      reference = Enum.reduce(1..10, input, fn _, nodes ->
        {0.05, result, 0.0, 0.0} = ThermalNative.advance(nodes,
          next.thermal_work.indexed_edges, 293.15, 0.0, 0.01, 0.05)
        Enum.zip_with(nodes, result, fn n, {t, hp, left} ->
          n |> put_elem(0, t) |> put_elem(1, hp) |> put_elem(8, left)
        end)
      end)
      for {{_, n}, expected} <- Enum.zip(ordered, reference) do
        actual = Map.fetch!(next.damage, VoxelRegion.Damage.key(n.target))
        assert actual.temperature_kelvin == elem(expected, 0)
        assert actual.hp == elem(expected, 1)
      end
      assert next.damage[VoxelRegion.Damage.key(host)].temperature_kelvin > 280.0
      assert next.thermal.supplied_j == s.thermal.supplied_j
      assert next.thermal.environment_j == s.thermal.environment_j
      assert calls <= 2
    after
      :erlang.trace_pattern(mfa, false, [:call_count])
      :sys.resume(w)
    end
  end

  test "无热容量宿主变化仍刷新保留附件的暴露面" do
    {w, initial, row} = latent_world()
    slot = {0, 0, {8, 0, 0}}
    face = row |> Map.merge(VoxelRegion.Attachments.identity(slot, {2, 19}))
      |> Map.merge(%{granularity: 4, temperature_kelvin: 285.0}) |> Map.delete(:phase_energy_j)
    specification = %{"material_units_per_micro" => 4096, "face_units" => 64, "edge_units" => 1,
      "face_thickness_m" => 1 / 512, "line_section_m2" => 1 / (512 * 512)}
    s = %{initial | properties: Map.put(initial.properties, :attachments, specification),
      damage: %{VoxelRegion.Damage.key(face) => face},
      overlay: initial.overlay |> Map.put({0, {0, 0, 0}}, {1, 1}) |> Map.put({0, {1, 0, 0}}, {1, 2}),
      attachments: %{slot => {2, 19}},
      thermal_work: %{initial.thermal_work | hot: MapSet.new([{0, 0, 0}, {1, 0, 0}])}}
    {:noreply, warm} = VoxelRegion.World.handle_info(:thermal_commit, s)
    key = VoxelRegion.ThermalAttachments.key(slot)
    before = Map.new(warm.thermal_work.ordered)[key].exposed_faces
    # 一侧宿主移除，另一侧继续支撑；两格热节点均为空，仍须重新裁剪暴露面。
    edited = %{warm | overlay: Map.put(warm.overlay, {0, {1, 0, 0}}, {0, 3}),
      thermal_work: %{warm.thermal_work | geometry: Map.delete(warm.thermal_work.geometry, {1, 0, 0})}}
    {:noreply, next} = VoxelRegion.World.handle_info(:thermal_commit, edited)
    after_area = Map.new(next.thermal_work.ordered)[key].exposed_faces
    assert_in_delta after_area - before, 1 / 64, 1.0e-12
    :sys.resume(w)
  end

  test "潜热焓推进与邻接木材点燃在同一 World 批内结算" do
    {w, s, ice} = latent_world()
    wood = ice |> Map.merge(%{micro: {8, 0, 0}, incarnation: 2, material: 19, temperature_kelvin: 299.0})
      |> Map.delete(:phase_energy_j)
    s = %{s | damage: Map.put(s.damage, VoxelRegion.Damage.key(wood), wood),
      overlay: Map.put(s.overlay, {0, {1, 0, 0}}, {19, 2}), epochs: Map.put(s.epochs, {1, 0, 0}, 2),
      thermal: %{s.thermal | sources: %{{1, 0, 0} => %{target: wood, power_w: 4000.0, remaining_j: 2000.0}}},
      thermal_work: %{s.thermal_work | hot: MapSet.new([{0, 0, 0}, {1, 0, 0}])}}
    {:noreply, next} = VoxelRegion.World.handle_info(:thermal_commit, s)
    assert next.damage[VoxelRegion.Damage.key(wood)].burning
    assert next.damage[VoxelRegion.Damage.key(ice)].phase_energy_j > 500.0
    assert next.damage[VoxelRegion.Damage.key(ice)].temperature_kelvin == 273.15
    :sys.resume(w)
  end

  test "World 融冻双向的显热 潜热进入 停留及完成保留温度焓和材质规则" do
    {w, initial, row} = latent_world()
    for {material, energy, ambient, expected_material} <- [
          {20, -5000.0, 293.15, 20}, {20, -200.0, 293.15, 20},
          {20, 100.0, 293.15, 20}, {20, 900.0, 293.15, 21},
          {21, 2000.0, 253.15, 21}, {21, 1100.0, 253.15, 21},
          {21, 900.0, 253.15, 21}, {21, 100.0, 253.15, 20}] do
      t = VoxelRegion.Phase.temperature(material, energy, 1.0, initial.properties.materials)
      row = %{row | material: material, phase_energy_j: energy, temperature_kelvin: t}
      config = initial.thermal.config |> Map.put("ambient_kelvin", ambient)
        |> Map.put("environment_w_per_m2_k", 10.0)
      s = %{initial | log: {VoxelRegion.DamageWorldTest.ThermalProbeLog, nil},
        overlay: Map.put(initial.overlay, {0, {0, 0, 0}}, {material, 1}),
        damage: %{VoxelRegion.Damage.key(row) => row}, thermal: %{initial.thermal | config: config}}
      {:noreply, next} = VoxelRegion.World.handle_info(:thermal_commit, s)
      current = Enum.find(Map.values(next.damage), &(&1.micro == {0, 0, 0} and &1.flags == 0))
      assert current.material == expected_material
      assert current.temperature_kelvin == VoxelRegion.Phase.temperature(
        current.material, current.phase_energy_j, 1.0, next.properties.materials)
      assert current.hp == 100.0
    end
    :sys.resume(w)
  end

  test "半秒批与旧十次分段的每节点温度 HP 余能及总热账相等" do
    nodes = [
      {400.0, 100.0, 100.0, 1.0, 1.0, 310.0, 1.0, 20.0, 4.0, true},
      {300.0, 80.0, 100.0, 2.0, 1.0, 310.0, 1.0, -5.0, 2.0, true}
    ]
    contacts = [{0, 1, 0.2}]
    {done, result, supplied, environment} =
      ThermalNative.advance(nodes, contacts, 293.15, 15.0, 0.01, 0.5)

    # 旧入口每次都只收到 50ms，稳定步不能用整批时长重新均分。
    {reference, old_supplied, old_environment} =
      Enum.reduce(1..10, {nodes, 0.0, 0.0}, fn _, {input, q, air} ->
        {step, output, dq, da} =
          ThermalNative.advance(input, contacts, 293.15, 15.0, 0.01, 0.05)
        assert_in_delta step, 0.05, 1.0e-12
        input = Enum.zip_with(input, output, fn n, {t, hp, remaining} ->
          n |> put_elem(0, t) |> put_elem(1, hp) |> put_elem(8, remaining)
        end)
        {input, q + dq, air + da}
      end)

    assert_in_delta done, 0.5, 1.0e-12
    for {n, {t, hp, remaining}} <- Enum.zip(reference, result) do
      for {a, b} <- [{elem(n, 0), t}, {elem(n, 1), hp}, {elem(n, 8), remaining}] do
        assert_in_delta a, b, max(abs(a), 1.0) * 1.0e-12
      end
    end
    assert_in_delta supplied, old_supplied, max(abs(old_supplied), 1.0) * 1.0e-12
    assert_in_delta environment, old_environment, abs(old_environment) * 1.0e-12
  end

  test "点燃 共享HP损伤和归零事件在原段末交还 World" do
    node = {400.0, 100.0, 100.0, 1000.0, 1.0, 310.0, 0.0, 0.0, 0.0, true}
    for control <- [{399.0, nil, false}, {nil, nil, true}] do
      {done, result, _, _} = ThermalNative.advance([{node, control}], [], 293.15, 0.0, 0.01, 0.5)
      {old_done, old_result, _, _} = ThermalNative.advance([node], [], 293.15, 0.0, 0.01, 0.05)
      assert done == old_done
      assert result == old_result
    end
    dying = put_elem(node, 1, 0.001)
    assert {0.05, [{400.0, 0.0, 0.0}], 0.0, 0.0} =
      ThermalNative.advance([{dying, {nil, nil, false}}], [], 293.15, 0.0, 0.01, 0.5)
  end

  test "未到点燃或损伤阈值的共享节点不打断批次" do
    node = {300.0, 100.0, 100.0, 1000.0, 1.0, 310.0, 0.0, 0.0, 0.0, true}
    {done, _, _, _} = ThermalNative.advance([{node, {400.0, nil, true}}], [], 293.15, 0.0, 0.01, 0.5)
    assert_in_delta done, 0.5, 1.0e-12
  end

  test "首次相变几何的焓回写激活新前沿时当段交还 World" do
    # 未有属性行的固体节点沿 Phase.energy 的环境默认值初始化，首次回写会钳到相变温度。
    node = {293.15, 100.0, 100.0, 100.0, 1.0, 1000.0, 0.0, 0.0, 0.0, false}
    phase = {2000.0, 1.0, 273.15, 1000.0, 100.0, false}
    assert {0.05, [{273.15, 100.0, 0.0, 2000.0}], 0.0, 0.0} =
      ThermalNative.advance([{node, {nil, phase, false}}], [], 293.15, 0.0, 0.01, 0.5)
  end

  test "融冻显热 进入潜热 停留和完成均与 World 旧逐段焓回写等价" do
    for {liquid, energy, power} <- [
          {false, -500.0, 10.0}, {false, -1.0, 10.0}, {false, 50.0, 10.0}, {false, 98.0, 10.0},
          {true, 110.0, -10.0}, {true, 101.0, -10.0}, {true, 50.0, -10.0}, {true, 2.0, -10.0}] do
      material = if liquid, do: 21, else: 20
      properties = %{material => %{"heat_capacity_per_macro" => 10.0,
        "phase_transition_kelvin" => 273.15, "latent_heat_per_macro_j" => 200.0}}
      temperature = VoxelRegion.Phase.temperature(material, energy, 0.5, properties)
      node = {temperature, 100.0, 100.0, 5.0, 1.0, 1000.0, 0.0, power, 5.0, true}
      {expected, expected_energy, expected_q, expected_air} =
        Enum.reduce(1..10, {node, energy, 0.0, 0.0}, fn _, {n, e, q, air} ->
          {_, [{raw, hp, left}], dq, da} = ThermalNative.advance([n], [], 293.15, 0.0, 0.01, 0.05)
          e = e + 10.0 * 0.5 * (raw - elem(n, 0))
          t = VoxelRegion.Phase.temperature(material, e, 0.5, properties)
          {n |> put_elem(0, t) |> put_elem(1, hp) |> put_elem(8, left), e, q + dq, air + da}
        end)
      {actual, actual_energy, q, air, calls} = phase_batch(node, energy, liquid, 0.5, 0.0, 0.0, 0)
      for {a, b} <- [{elem(actual, 0), elem(expected, 0)}, {elem(actual, 1), elem(expected, 1)},
                     {elem(actual, 8), elem(expected, 8)}, {actual_energy, expected_energy},
                     {q, expected_q}, {air, expected_air}] do
        assert_in_delta a, b, max(abs(b), 1.0) * 1.0e-12
      end
      assert elem(actual, 0) == VoxelRegion.Phase.temperature(material, actual_energy, 0.5, properties)
      assert calls == if(energy in [98.0, 2.0], do: 2, else: 1)
    end
  end

  defp phase_batch(node, energy, _liquid, remaining, q, air, calls) when remaining < 1.0e-12,
    do: {node, energy, q, air, calls}
  defp phase_batch(node, energy, liquid, remaining, q, air, calls) do
    phase = {energy, 0.5, 273.15, 100.0, 10.0, liquid}
    {done, [{t, hp, left, next_energy}], dq, da} =
      ThermalNative.advance([{node, {nil, phase, false}}], [], 293.15, 0.0, 0.01, remaining)
    next = node |> put_elem(0, t) |> put_elem(1, hp) |> put_elem(8, left)
    phase_batch(next, next_energy, liquid, remaining - done, q + dq, air + da, calls + 1)
  end
end
