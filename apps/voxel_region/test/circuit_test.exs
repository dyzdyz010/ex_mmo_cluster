defmodule VoxelRegion.CircuitTest do
  use ExUnit.Case,async: true
  @moduletag :b5
  alias VoxelRegion.{Circuit,Attachments}

  defp fixture do
    tools=for {id,kind,r,v,light}<-[{3,1,1.0,12.0,0.0},{4,2,0.01,0.0,0.0},{5,3,12.0,0.0,0.2}],into: %{},
      do: {id,%{"circuit_resistance_ohm"=>r,"circuit_voltage_v"=>v,"circuit_light_fraction"=>light}}
    catalog=%{tools: tools,materials: %{16=>%{"electrical_conductivity"=>58.0e6},11=>%{}},
      attachments: %{"line_section_m2"=>1/(512*512),"face_thickness_m"=>1/512}}
    slots=Map.new(for x<-0..2,do: {{0,1,{x,8,511}},{x+1,16}})
    slots=Enum.reduce([{2,{0,8,511}},{2,{3,8,511}}]++for(x<-0..2,do: {0,{x,8,512}}),slots,fn {a,p},s->Map.put(s,{1,a,p},{10,16}) end)
    damage=for x<-0..2,into: %{} do
      target=Attachments.identity({0,1,{x,8,511}},{x+1,16})
      c=%{tool_id: x+3,kind: x+1,anchor: {x,8,511},size: 1,closed: true,fault: 0,
        remaining_j: if(x==0,do: 6.0,else: 0.0),voltage_v: 0.0,current_a: 0.0,power_w: 0.0}
      {{3,x+1},Map.merge(target,%{flags: 0,circuit: c})}
    end
    {slots,damage,catalog}
  end
  # 只测试：本组夹具为空气或单个宏格导体，没有实体之间的接触边。
  defp plan(slots,damage,catalog,state,at,duration) do
    ambient=if state,do: state.thermal.config["ambient_kelvin"]
    input=Circuit.prepare(slots,damage,catalog,ambient,duration)
    hosts=Map.new(Circuit.points(input),fn point ->
      targets=Enum.map(Circuit.near_points(point),fn p -> elem(at.(p,state),0) end)
      {point,Circuit.conductors(targets,catalog)}
    end)
    Circuit.plan(input,hosts,[])
  end

  defp air(_p,s),do: {nil,s}

  test "电路准备和求解只消费目录设备与导体摘要，不接收或返回世界" do
    {slots, damage, catalog} = fixture()
    input = Circuit.prepare(slots, damage, catalog, nil, 0.5)
    hosts = Map.new(Circuit.points(input), &{&1, []})
    plan = Circuit.plan(input, hosts, [])
    refute Map.has_key?(input, :state)
    refute Map.has_key?(plan, :state)
    assert plan.outputs[1].remaining_j < 6.0
    assert plan.outputs[3].power_w > 0.0
  end

  test "体积导体邻面保留微面面积，绝缘与空气不进入导体图" do
    {_slots,_damage,catalog}=fixture()
    macro=%{micro: {8,0,0},granularity: 0,material: 16,owner: {0,0},incarnation: 1}
    micro=%{micro: {0,0,0},granularity: 2,material: 16,owner: {7,1},incarnation: 7}
    samples=[macro,macro,micro,nil,%{macro | material: 11}]
    contacts=Circuit.solid_contacts(samples,catalog)
    assert contacts[{0,{8,0,0}}]=={macro,2/64}
    assert contacts[{1,{0,0,0}}]=={%{micro | granularity: 1},1/64}
    assert map_size(contacts)==2
    assert length(Circuit.solid_points(macro))==384
    assert length(Circuit.solid_points(micro))==6
  end

  @tag :phase_coverage
  test "矿石目录失导保留设备余能，普通加工铜替换返回线恢复" do
    {slots,damage,catalog}=fixture()
    catalog=put_in(catalog.materials[24],catalog.materials[16])
    catalog=put_in(catalog.materials[16]["electrical_conductivity"],0.0)
    stopped=plan(slots,damage,catalog,nil,&air/2,0.5)
    assert stopped.outputs[1].remaining_j==6.0
    assert stopped.outputs[1].power_w==0.0
    assert stopped.outputs[3].power_w==0.0
    replaced=Map.new(slots,fn
      {{1,_,_}=slot,{id,16}}->{slot,{id,24}}
      item->item
    end)
    running=plan(replaced,damage,catalog,nil,&air/2,0.1)
    assert running.outputs[1].remaining_j<6.0
    assert running.outputs[3].power_w>0.0
    assert damage[{3,1}].material==16
  end

  test "跨区线端点串联与光热电能同口径，有限能源截断步长" do
    {slots,damage,catalog}=fixture()
    result=plan(slots,damage,catalog,nil,&air/2,1.0)
    expected=12/(1+0.01+12+5*0.125/(58.0e6/(512*512)))
    assert_in_delta result.outputs[1].current_a,expected,1.0e-8
    assert result.duration<1.0
    assert_in_delta result.outputs[1].remaining_j,0.0,1.0e-10
    assert_in_delta result.supplied_j,6.0,1.0e-9
    assert_in_delta Enum.sum(Map.values(result.powers))*result.duration+result.light_j,6.0,1.0e-8
    assert result.powers[{4,{3,{0,8,512}}}]>0
  end
  test "开关、断线、近邻绝缘与破损设备不通电" do
    {slots,damage,catalog}=fixture()
    opened=put_in(damage[{3,2}].circuit.closed,false)
    for {s,d}<- [{slots,opened},{Map.delete(slots,{1,0,{1,8,512}}),damage},
                 {Map.put(slots,{1,0,{1,8,512}},{10,11}),damage}] do
      r=plan(s,d,catalog,nil,&air/2,0.5)
      assert_in_delta r.outputs[3].power_w,0.0,1.0e-9
      assert_in_delta r.outputs[1].remaining_j,6.0,1.0e-9
    end
    broken=put_in(damage[{3,3}].circuit.size,8)
    r=plan(slots,broken,catalog,nil,&air/2,0.5)
    assert r.outputs[3].fault==1
    assert r.outputs[3].power_w==0.0
  end
  test "体积导体桥接断线；绝缘宿主不能桥接" do
    {slots,damage,catalog}=fixture()
    slots=Map.delete(slots,{1,0,{1,8,512}})
    sample=fn {x,y,z},s->
      t=if x in 0..7 and y in 0..7 and z in 512..519,
        do: %{micro: {0,0,512},granularity: 0,material: 16,owner: {0,0},incarnation: 1}
      {t,s}
    end
    r=plan(slots,damage,catalog,nil,sample,0.1)
    assert r.outputs[3].power_w>1.0
    assert r.powers[{0,{0,0,512}}]>0
  end

  test "有限电源驱动冷板，吸热与热端排放闭合；最低温度与断电停止" do
    {slots,damage,catalog}=fixture()
    catalog=put_in(catalog.tools[5],%{"circuit_resistance_ohm"=>12.0,"circuit_voltage_v"=>0.0,
      "circuit_light_fraction"=>0.0,"circuit_cooling_cop"=>2.0,"circuit_min_kelvin"=>250.0})
    catalog=put_in(catalog.materials[16]["heat_capacity_per_macro"],3.45e6)
    catalog=put_in(catalog.attachments["material_units_per_micro"],4096)
    catalog=put_in(catalog.attachments["face_units"],64)
    damage=put_in(damage[{3,3}].circuit.kind,5)
    state=%{thermal: %{config: %{"ambient_kelvin"=>293.15}}}
    r=plan(slots,damage,catalog,state,&air/2,0.5)
    assert r.duration==0.05
    assert r.powers[{4,{1,{2,8,511}}}]<0
    assert r.outputs[1].remaining_j<6.0
    assert_in_delta r.cooling_j,2*r.outputs[3].power_w*r.duration,1.0e-9
    assert_in_delta r.rejected_j,r.cooling_j+r.outputs[3].power_w*r.duration,1.0e-9
    assert_in_delta Enum.sum(Map.values(r.powers))*r.duration+r.rejected_j,r.supplied_j,1.0e-8
    t=Attachments.identity({0,1,{2,8,511}},{3,16}) |> Map.put(:granularity,4)
    cold=Map.put(damage,VoxelRegion.Damage.key(t),Map.put(t,:temperature_kelvin,250.0))
    for d<-[cold,put_in(damage[{3,1}].circuit.remaining_j,0.0),put_in(damage[{3,2}].circuit.closed,false)] do
      stopped=plan(slots,d,catalog,state,&air/2,0.5)
      assert stopped.cooling_j==0.0
      assert stopped.supplied_j==0.0
      assert stopped.duration==0.5
    end
    warm=Map.put(damage,VoxelRegion.Damage.key(t),Map.put(t,:temperature_kelvin,250.001))
    limited=plan(slots,warm,catalog,state,&air/2,0.5)
    capacity=catalog.materials[16]["heat_capacity_per_macro"]*VoxelRegion.ThermalAttachments.volume({0,1,{2,8,511}},catalog)
    assert limited.cooling_j<=capacity*0.001+1.0e-9
    assert_in_delta Enum.sum(Map.values(limited.powers))*limited.duration+limited.rejected_j,limited.supplied_j,1.0e-8
  end

  describe "电阻发光材料（R8-04）" do
    # 只测试：一个 24 V / 1 Ω 源（微面设备，两端口宿主各是一个铜微格），铜微格 — n 个电阻合金微格 — 铜微格串成一条线。
    # 目录值与发布目录同口径：铜 σ 5.8e7，合金 σ 4、λ 0.2；线截面 = 发布值。期望逐项按 r = d/(σ·A)（接触边两侧各半格）手算。
    @section 3.814697265625e-06
    @micro_area 1 / 64
    defp resistive_fixture(n) do
      catalog = %{tools: %{3 => %{"circuit_resistance_ohm" => 1.0, "circuit_voltage_v" => 24.0, "circuit_light_fraction" => 0.0}},
        materials: %{24 => %{"electrical_conductivity" => 5.8e7}, 40 => %{"electrical_conductivity" => 4.0, "luminous_fraction" => 0.2}},
        attachments: %{"line_section_m2" => @section, "face_thickness_m" => 1 / 512}}
      target = fn x, material -> %{micro: {x, 0, 0}, granularity: 1, material: material, owner: {9, 0}, incarnation: 100 + x} end
      cells = [target.(0, 24)] ++ for(x <- 1..n, do: target.(x, 40)) ++ [target.(n + 1, 24)]
      slot = {0, 1, {0, 8, 0}}
      c = %{tool_id: 3, kind: 1, anchor: {0, 8, 0}, size: 1, closed: true, fault: 0, remaining_j: 1.0e9,
        voltage_v: 0.0, current_a: 0.0, power_w: 0.0}
      damage = %{{3, 1} => Map.merge(Attachments.identity(slot, {1, 24}), %{flags: 0, circuit: c})}
      input = Circuit.prepare(%{slot => {1, 24}}, damage, catalog, nil, 0.5)
      [a, b] = Circuit.points(input)
      hosts = %{a => [hd(cells)], b => [List.last(cells)]}
      contacts = for [p, q] <- Enum.chunk_every(cells, 2, 1, :discard), do: {p, q, @micro_area}
      {Circuit.plan(input, hosts, contacts), cells, catalog}
    end

    # 手算：铜宿主半格 (1/8)/2/(σ_Cu·截面)；铜—合金接触 ((1/8)/σ_Cu + (1/8)/σ)/2/A；合金—合金 (1/8)/σ·2/2/A = 2 Ω。
    defp copper_host, do: 0.125 / 2 / (5.8e7 * @section)
    defp copper_alloy, do: (0.125 / 5.8e7 + 0.125 / 4) / 2 / @micro_area
    defp chain(n), do: 1.0 + 2 * copper_host() + 2 * copper_alloy() + (n - 1) * 2.0

    test "单格灯丝：接触边按电阻份额分热，灯丝得到自身两条接触边 I²R 的 ≥ 1 − 1e-6，铜几乎为 0" do
      {plan, [cu, fil, _], _} = resistive_fixture(1)
      i = 24.0 / chain(1)
      assert_in_delta plan.outputs[1].current_a, i, 1.0e-9
      edge_joule = 2 * i * i * copper_alloy()
      {_, w, a} = plan.electric[{1, fil.micro}]
      assert w >= (1 - 1.0e-6) * edge_joule and w <= edge_joule
      assert_in_delta a, i, 1.0e-9
      # 灯丝 λ = 0.2：热节点只得 0.8。铜只得到端口落点的宿主边与接触边里自己那半格的份额，没有光。
      assert_in_delta plan.powers[{1, fil.micro}], 0.8 * w, 1.0e-9
      assert_in_delta plan.powers[{1, cu.micro}], i * i * (copper_host() + 0.125 / 5.8e7 / 2 / @micro_area), 1.0e-12
      refute Map.has_key?(plan.electric, {1, cu.micro})
    end

    test "n 格灯丝串联：I = V /(r_源 + 2n + 铜)，光 = λ × 灯丝焦耳，热 + 光 = 供能" do
      for n <- [1, 2, 5] do
        {plan, cells, _} = resistive_fixture(n)
        i = 24.0 / chain(n)
        assert_in_delta plan.outputs[1].current_a, i, 1.0e-9
        filament = for c <- cells, c.material == 40, do: elem(plan.electric[{1, c.micro}], 1)
        assert length(filament) == n
        assert_in_delta plan.light_j, 0.2 * Enum.sum(filament) * plan.duration, 1.0e-9
        assert_in_delta Enum.sum(Map.values(plan.powers)) * plan.duration + plan.light_j, plan.supplied_j, 1.0e-6
        assert_in_delta plan.supplied_j, 24.0 * i * plan.duration, 1.0e-6
      end
    end
  end
end
