defmodule VoxelRegion.ThermalBatchTest do
  @moduledoc "只测试：真实 World 热提交、纯 NIF 守恒与事件边界；World样本经作者及工具入口建立。"
  use ExUnit.Case, async: false
  alias VoxelRegion.{World, Damage, Phase, ThermalNative, ThermalAttachments}
  alias VoxelRegion.TestSupport.{Source, Log, Actor}

  defp world(ambient) do
    root =
      Path.join(
        System.tmp_dir!(),
        "thermal_batch_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    materials =
      for id <- 0..23 do
        base = %{
          material_id: id,
          max_hp_per_macro: if(id == 0, do: 0.0, else: 100.0),
          defense: 2.0,
          tags: [],
          responses: [%{action: "damage", multiplier: 1.0}]
        }

        cond do
          id == 19 ->
            Map.merge(base, %{
              heat_capacity_per_macro: 100.0,
              thermal_conductivity: 1.0,
              heat_resistance_kelvin: 1000.0,
              ignition_kelvin: 300.0,
              fuel_energy_per_macro_j: 1_000_000.0,
              burn_power_per_macro_w: 100.0
            })

          id in [20, 21] ->
            Map.merge(base, %{
              phase_peer_material_id: if(id == 20, do: 21, else: 20),
              phase_transition_kelvin: 273.15,
              latent_heat_per_macro_j: 1000.0,
              heat_capacity_per_macro: 100.0,
              thermal_conductivity: 1.0,
              heat_resistance_kelvin: 1000.0
            })

          true ->
            base
        end
      end

    catalog = Path.join(root, "catalog.json")

    File.write!(
      catalog,
      Jason.encode!(%{
        schema_version: 2,
        tags: [%{id: "damage"}],
        materials: materials,
        definitions: [],
        tools: [
          %{
            id: "pick",
            tool_id: 1,
            action: "damage",
            power: 200.0,
            range_macro: 6.0,
            interval_seconds: 0.1
          }
        ],
        attachments: %{
          material_units_per_micro: 4096,
          face_thickness_m: 1 / 512,
          line_section_m2: 1 / (512 * 512),
          line_display_width_m: 0.0075
        },
        liquid: %{step_seconds: 3600, gravity_units_per_step: 4096, side_units_per_step: 4096}
      })
    )

    environment = Path.join(root, "environment.json")

    File.write!(
      environment,
      Jason.encode!(%{
        ambient_kelvin: ambient,
        environment_w_per_m2_k: 0.0,
        tolerance_kelvin: 0.00001,
        emissivity: 0.0,
        view_range_cells: 8
      })
    )

    w =
      start_supervised!(
        {World,
         [
           source: Source,
           log: Log,
           root: root,
           observer: self(),
           name: nil,
           property_catalog_path: catalog,
           thermal_environment_path: environment,
           production_materials: [19, 20, 21],
           liquid_bounds: {{-1, -1, -1}, {3, 2, 2}}
         ]}
      )

    %{w: w, root: root}
  end

  defp tick(w) do
    send(w, :thermal_commit)
    VoxelRegion.TestSupport.observe(w,[1001],{{-1,-1,-1},{1,1,1}})
  end

  # 只测试白盒：下面具名缓存/NIF 接触图回归需要工作集，不用于普通燃料/属性行为观察。
  defp cache_tick(w) do
    send(w,:thermal_commit)
    :sys.get_state(w)
  end

  defp heat(c, cell, energy, power) do
    path = Path.join(c.root, "heat.json")

    File.write!(
      path,
      Jason.encode!(%{
        classification: "Test-only",
        source_macro: Tuple.to_list(cell),
        ambient_kelvin: 293.15,
        environment_w_per_m2_k: 0.1,
        tolerance_kelvin: 0.00001,
        emissivity: 0.0,
        view_range_cells: 8,
        power_w: power,
        energy_j: energy
      })
    )

    assert :ok = World.thermal_experiment(c.w, path)
  end

  defp latent_world do
    c = world(273.15)
    sample = Path.join(c.root, "ice.json")

    File.write!(
      sample,
      Jason.encode!(%{classification: "Test-only", deposits: [%{macro: [0, 0, 0], material: 20}]})
    )

    assert {:ok, _} = World.liquid_experiment(c.w, sample)
    heat(c, {0, 0, 0}, 1.0, 2.0)
    state = tick(c.w)
    row = Enum.find(Map.values(state.damage), &(&1.granularity == 0 and &1.micro == {0, 0, 0}))
    assert row.material == 20 and row.phase_energy_j > 0 and row.phase_energy_j < 1000.0
    {c, state, row}
  end

  defp attachment_world(material) do
    c = world(293.15)
    assert {:ok, _} = World.apply_edit(c.w, {-6, 1, -4}, 19)
    assert :ok = VoxelRegion.TestSupport.mine_authored(c.w, 1001)
    assert {:ok, _} = World.apply_edit(c.w, {0, 0, 0}, material)

    actor = %{
      cid: 1001,
      gate: self(),
      identity: :thermal_attachment,
      refresh: &Actor.tool_context/2,
      eye: {2.0, 0.0625, 0.0625},
      tick_us: 16_667
    }

    player = start_supervised!({Actor, actor})

    request = %{
      request_id: 1,
      client_intent_seq: 1,
      logical_scene_id: 1,
      action: 0,
      kind: 0,
      axis: 0,
      size: 1,
      anchor: {8, 0, 0},
      id: 0,
      material: 19,
      tool_id: 1
    }

    assert {:ok, _} = World.attachment_intent(c.w, Map.put(actor, :player, player), request)
    {c, {0, 0, {8, 0, 0}}}
  end

  @tag :latent_batch
  test "潜热区无其他事件的半秒 World 批至多两次进入 NIF" do
    {c, before, row} = latent_world()
    mfa = {ThermalNative, :advance, 7}
    :erlang.trace_pattern(mfa, true, [:call_count])

    try do
      next = tick(c.w)
      {:call_count, calls} = :erlang.trace_info(mfa, :call_count)
      assert calls in 1..2
      current = Map.fetch!(next.damage, Damage.key(row))
      assert current.temperature_kelvin == 273.15 and current.material == 20

      assert_in_delta current.phase_energy_j - row.phase_energy_j,
                      next.thermal.environment_j - before.thermal.environment_j,
                      1.0e-9

      assert next.thermal.supplied_j == before.thermal.supplied_j
    after
      :erlang.trace_pattern(mfa, false, [:call_count])
    end
  end

  test "热前沿只扩张空气时复用实体接触图，真实采回后重新派生" do
    {c, _, _} = latent_world()
    warm = cache_tick(c.w)
    # 只改变可重建的候选缓存，不改占用、温度、焓或热源。
    :sys.replace_state(c.w, fn s ->
      put_in(s.thermal_work.hot, MapSet.put(s.thermal_work.hot, {0, 0, 2}))
    end)

    mfa = {ThermalAttachments, :add, 5}
    :erlang.trace_pattern(mfa, true, [:call_count])

    try do
      next = cache_tick(c.w)
      {:call_count, calls} = :erlang.trace_info(mfa, :call_count)
      assert calls == 0
      assert next.thermal_work.ordered == warm.thermal_work.ordered
      assert :ok = VoxelRegion.TestSupport.mine_authored(c.w, 1002, {0, 0, 0})
      empty = cache_tick(c.w)
      assert empty.damage == %{}
      assert Enum.all?(Map.values(empty.thermal_work.geometry), &(&1 == []))
    after
      :erlang.trace_pattern(mfa, false, [:call_count])
    end
  end

  @tag :empty_geometry_batch
  test "附件空气侧合法空几何不把半秒 World 批拆成十次 NIF 调用" do
    {c, slot} = attachment_world(19)
    heat(c, {0, 0, 0}, 100.0, 200.0)
    before = cache_tick(c.w)
    assert before.thermal.sources == %{}
    mfa = {ThermalNative, :advance, 7}
    :erlang.trace_pattern(mfa, true, [:call_count])

    try do
      next = cache_tick(c.w)
      {:call_count, calls} = :erlang.trace_info(mfa, :call_count)
      assert calls in 1..2
      assert Map.fetch!(next.thermal_work.geometry, {1, 0, 0}) == []

      assert Enum.any?(next.thermal_work.ordered, fn {key, _} ->
               key == ThermalAttachments.key(slot)
             end)

      # 对正常派生的实际节点，比较旧十个 50ms 步与整批结果；不构造第二份 World。
      ordered = next.thermal_work.ordered

      input =
        Enum.map(ordered, fn {_, n} ->
          t = Map.fetch!(before.damage, Damage.key(n.target))

          {t.temperature_kelvin, t.hp, t.max_hp, n.capacity, 1.0, 1000.0, n.exposed_faces * 1.0,
           0.0, 0.0, true}
        end)

      {reference, environment} =
        Enum.reduce(1..10, {input, 0.0}, fn _, {nodes, air} ->
          {0.05, result, 0.0, delta} =
            ThermalNative.advance(
              nodes,
              next.thermal_work.indexed_edges,
              293.15,
              0.1,
              0.00001,
              0.05, {[], []}
            )

          nodes =
            Enum.zip_with(nodes, result, fn n, {t, hp, left} ->
              n |> put_elem(0, t) |> put_elem(1, hp) |> put_elem(8, left)
            end)

          {nodes, air + delta}
        end)

      for {{_, n}, expected} <- Enum.zip(ordered, reference) do
        actual = Map.fetch!(next.damage, Damage.key(n.target))
        assert_in_delta actual.temperature_kelvin, elem(expected, 0), 1.0e-10
        assert actual.hp == elem(expected, 1)
      end

      assert next.thermal.supplied_j == before.thermal.supplied_j

      assert_in_delta next.thermal.environment_j - before.thermal.environment_j,
                      environment,
                      1.0e-9
    after
      :erlang.trace_pattern(mfa, false, [:call_count])
    end
  end

  test "无热容量宿主变化仍刷新保留附件的暴露面" do
    {c, slot} = attachment_world(1)
    assert {:ok, _} = World.apply_edit(c.w, {1, 0, 0}, 19)
    heat(c, {1, 0, 0}, 100.0, 200.0)
    cache_tick(c.w)
    assert {:ok, _} = World.apply_edit(c.w, {1, 0, 0}, 1)
    warm = cache_tick(c.w)
    key = ThermalAttachments.key(slot)
    before = Map.new(warm.thermal_work.ordered)[key].exposed_faces
    assert Map.fetch!(warm.thermal_work.geometry, {0, 0, 0}) == []
    assert Map.fetch!(warm.thermal_work.geometry, {1, 0, 0}) == []
    assert {:ok, _} = World.apply_edit(c.w, {1, 0, 0}, 0)
    next = cache_tick(c.w)
    after_area = Map.new(next.thermal_work.ordered)[key].exposed_faces
    assert_in_delta after_area - before, 1 / 64, 1.0e-12
  end

  test "潜热焓推进与邻接木材点燃在同一 World 批内结算" do
    {c, _, ice} = latent_world()
    assert {:ok, _} = World.apply_edit(c.w, {1, 0, 0}, 19)
    heat(c, {1, 0, 0}, 2000.0, 4000.0)
    next = tick(c.w)
    wood = Enum.find(Map.values(next.damage), &(&1.granularity == 0 and &1.micro == {8, 0, 0}))
    assert wood.burning
    assert next.damage[Damage.key(ice)].phase_energy_j > ice.phase_energy_j
    assert next.damage[Damage.key(ice)].temperature_kelvin == 273.15
  end

  test "内核融冻双向输出按相态契约保留温度焓和材质规则" do
    properties =
      Map.new([20, 21], fn m ->
        {m,
         %{
           "phase_peer_material_id" => if(m == 20, do: 21, else: 20),
           "phase_transition_kelvin" => 273.15,
           "latent_heat_per_macro_j" => 1000.0,
           "heat_capacity_per_macro" => 100.0
         }}
      end)

    for {material, energy, ambient, expected_material} <- [
          {20, -5000.0, 293.15, 20},
          {20, -200.0, 293.15, 20},
          {20, 100.0, 293.15, 20},
          {20, 900.0, 293.15, 21},
          {21, 2000.0, 253.15, 21},
          {21, 1100.0, 253.15, 21},
          {21, 900.0, 253.15, 21},
          {21, 100.0, 253.15, 20}
        ] do
      t = Phase.temperature(material, energy, 1.0, properties)
      node = {t, 100.0, 100.0, 100.0, 1.0, 1000.0, 6.0, 0.0, 0.0, true}
      phase = {energy, 1.0, 273.15, 1000.0, 100.0, Phase.liquid?(material)}

      {_, [{temperature, hp, _, enthalpy}], _, _} =
        ThermalNative.advance([{node, {nil, phase, false}}], [], ambient, 10.0, 0.01, 0.5, {[], []})

      current = Phase.material(material, enthalpy, 1.0, properties)
      assert current == expected_material

      # NIF 在相变事件处交还旧材质的温度；World 接着按返回焓切换材质并重标温度。
      assert temperature == Phase.temperature(material, enthalpy, 1.0, properties)
      assert hp == 100.0
    end
  end

  test "半秒批与旧十次分段的每节点温度 HP 余能及总热账相等" do
    nodes = [
      {400.0, 100.0, 100.0, 1.0, 1.0, 310.0, 1.0, 20.0, 4.0, true},
      {300.0, 80.0, 100.0, 2.0, 1.0, 310.0, 1.0, -5.0, 2.0, true}
    ]

    contacts = [{0, 1, 0.2}]

    {done, result, supplied, environment} =
      ThermalNative.advance(nodes, contacts, 293.15, 15.0, 0.01, 0.5, {[], []})

    # 旧入口每次都只收到 50ms，稳定步不能用整批时长重新均分。
    {reference, old_supplied, old_environment} =
      Enum.reduce(1..10, {nodes, 0.0, 0.0}, fn _, {input, q, air} ->
        {step, output, dq, da} =
          ThermalNative.advance(input, contacts, 293.15, 15.0, 0.01, 0.05, {[], []})

        assert_in_delta step, 0.05, 1.0e-12

        input =
          Enum.zip_with(input, output, fn n, {t, hp, remaining} ->
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
      {done, result, _, _} = ThermalNative.advance([{node, control}], [], 293.15, 0.0, 0.01, 0.5, {[], []})
      {old_done, old_result, _, _} = ThermalNative.advance([node], [], 293.15, 0.0, 0.01, 0.05, {[], []})
      assert done == old_done
      assert result == old_result
    end

    dying = put_elem(node, 1, 0.001)

    assert {0.05, [{400.0, 0.0, 0.0}], 0.0, 0.0} =
             ThermalNative.advance([{dying, {nil, nil, false}}], [], 293.15, 0.0, 0.01, 0.5, {[], []})
  end

  test "未到点燃或损伤阈值的共享节点不打断批次" do
    node = {300.0, 100.0, 100.0, 1000.0, 1.0, 310.0, 0.0, 0.0, 0.0, true}

    {done, _, _, _} =
      ThermalNative.advance([{node, {400.0, nil, true}}], [], 293.15, 0.0, 0.01, 0.5, {[], []})

    assert_in_delta done, 0.5, 1.0e-12
  end

  test "首次相变几何的焓回写激活新前沿时当段交还 World" do
    # 未有属性行的固体节点沿 Phase.energy 的环境默认值初始化，首次回写会钳到相变温度。
    node = {293.15, 100.0, 100.0, 100.0, 1.0, 1000.0, 0.0, 0.0, 0.0, false}
    phase = {2000.0, 1.0, 273.15, 1000.0, 100.0, false}

    assert {0.05, [{273.15, 100.0, 0.0, 2000.0}], 0.0, 0.0} =
             ThermalNative.advance([{node, {nil, phase, false}}], [], 293.15, 0.0, 0.01, 0.5, {[], []})
  end

  test "融冻显热、潜热与完成事件按有限源解析热量守恒" do
    for {liquid, energy, power} <- [
          {false, -500.0, 10.0},
          {false, -1.0, 10.0},
          {false, 50.0, 10.0},
          {false, 98.0, 10.0},
          {true, 110.0, -10.0},
          {true, 101.0, -10.0},
          {true, 50.0, -10.0},
          {true, 2.0, -10.0}
        ] do
      material = if liquid, do: 21, else: 20

      properties = %{
        material => %{
          "heat_capacity_per_macro" => 10.0,
          "phase_transition_kelvin" => 273.15,
          "latent_heat_per_macro_j" => 200.0
        }
      }

      temperature = VoxelRegion.Phase.temperature(material, energy, 0.5, properties)
      node = {temperature, 100.0, 100.0, 5.0, 1.0, 1000.0, 0.0, power, 5.0, true}

      # 只测试：无接触/环境，半秒有限供热为P×t；固/液身份由World在事件后替换。
      expected_q = power * 0.5
      expected_energy = energy + expected_q
      expected_temperature =
        if liquid,
          do: 273.15 + max(0.0, expected_energy - 100.0) / 5.0,
          else: 273.15 + min(0.0, expected_energy) / 5.0

      {actual, actual_energy, q, air, calls} = phase_batch(node, energy, liquid, 0.5, 0.0, 0.0, 0)

      for {a, b} <- [
            {elem(actual, 0), expected_temperature},
            {elem(actual, 1), 100.0},
            {elem(actual, 8), 0.0},
            {actual_energy, expected_energy},
            {q, expected_q},
            {air, 0.0}
          ] do
        assert_in_delta a, b, max(abs(b), 1.0) * 1.0e-12
      end

      assert elem(actual, 0) ==
               VoxelRegion.Phase.temperature(material, actual_energy, 0.5, properties)

      assert calls == if(energy in [98.0, 2.0], do: 2, else: 1)
    end
  end

  defp phase_batch(node, energy, _liquid, remaining, q, air, calls) when remaining < 1.0e-12,
    do: {node, energy, q, air, calls}

  defp phase_batch(node, energy, liquid, remaining, q, air, calls) do
    phase = {energy, 0.5, 273.15, 100.0, 10.0, liquid}

    {done, [{t, hp, left, next_energy}], dq, da} =
      ThermalNative.advance([{node, {nil, phase, false}}], [], 293.15, 0.0, 0.01, remaining, {[], []})

    next = node |> put_elem(0, t) |> put_elem(1, hp) |> put_elem(8, left)
    phase_batch(next, next_energy, liquid, remaining - done, q + dq, air + da, calls + 1)
  end
end
