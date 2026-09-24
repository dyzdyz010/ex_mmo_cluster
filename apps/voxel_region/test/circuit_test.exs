defmodule VoxelRegion.CircuitTest do
  use ExUnit.Case,async: true
  @moduletag :b5
  alias VoxelRegion.{Circuit,Attachments}

  # 只测试：一个 12 V / 1 Ω 源（微面设备 id 1，端口 (0,8,511)→(1,8,511)）后面串一段开关线（材料 41，闭合）
  # 与一段负载线（材料 40，σ 取使一段线恰为 12 Ω、λ 0.2），经 x = 3 的竖线、z = 512 的三段铜线与 x = 0 的竖线回到源。
  # 线段 r = (1/8 m)/(σ·截面)：铜与闭合开关各 0.125 × 512² / 5.8e7 Ω，负载 12 Ω。
  @section 1/(512*512)
  @load_sigma 0.125/(12.0*@section)
  defp fixture do
    tools=%{3=>%{"circuit_resistance_ohm"=>1.0,"circuit_voltage_v"=>12.0,"circuit_light_fraction"=>0.0}}
    catalog=%{tools: tools,materials: %{16=>%{"electrical_conductivity"=>58.0e6},11=>%{},
        41=>%{"electrical_conductivity"=>58.0e6,"circuit_switch"=>true},
        40=>%{"electrical_conductivity"=>@load_sigma,"luminous_fraction"=>0.2}},
      attachments: %{"line_section_m2"=>@section,"face_thickness_m"=>1/512}}
    slots=%{{0,1,{0,8,511}}=>{1,16},{1,0,{1,8,511}}=>{2,41},{1,0,{2,8,511}}=>{3,40}}
    slots=Enum.reduce([{2,{0,8,511}},{2,{3,8,511}}]++for(x<-0..2,do: {0,{x,8,512}}),slots,fn {a,p},s->Map.put(s,{1,a,p},{10,16}) end)
    source=Attachments.identity({0,1,{0,8,511}},{1,16})
    c=%{tool_id: 3,kind: 1,anchor: {0,8,511},size: 1,closed: true,fault: 0,remaining_j: 6.0,voltage_v: 0.0,current_a: 0.0,power_w: 0.0}
    switch=Attachments.identity({1,0,{1,8,511}},{2,41})
    damage=%{{3,1}=>Map.merge(source,%{flags: 0,circuit: c}),{3,2}=>Map.merge(switch,%{flags: 0,closed: true})}
    {slots,damage,catalog}
  end
  defp copper,do: 0.125/(58.0e6*@section)
  defp load_key,do: VoxelRegion.ThermalAttachments.key({1,0,{2,8,511}})
  # 只测试：本组夹具为空气或单个宏格导体，没有实体之间的接触边。
  defp plan(slots,damage,catalog,at,duration) do
    input=Circuit.prepare(slots,damage,catalog,duration)
    hosts=Map.new(Circuit.points(input),fn point ->
      targets=Enum.map(Circuit.near_points(point),fn p -> elem(at.(p,nil),0) end)
      {point,Circuit.conductors(targets,catalog,damage)}
    end)
    Circuit.plan(input,hosts,[])
  end

  defp air(_p,s),do: {nil,s}

  test "电路准备和求解只消费目录设备与导体摘要，不接收或返回世界" do
    {slots, damage, catalog} = fixture()
    input = Circuit.prepare(slots, damage, catalog, 0.5)
    hosts = Map.new(Circuit.points(input), &{&1, []})
    plan = Circuit.plan(input, hosts, [])
    refute Map.has_key?(input, :state)
    refute Map.has_key?(plan, :state)
    assert plan.outputs[1].remaining_j < 6.0
    assert plan.powers[load_key()] > 0.0
  end

  test "体积导体邻面保留微面面积，绝缘与空气不进入导体图" do
    {_slots,damage,catalog}=fixture()
    macro=%{micro: {8,0,0},granularity: 0,material: 16,owner: {0,0},incarnation: 1}
    micro=%{micro: {0,0,0},granularity: 2,material: 16,owner: {7,1},incarnation: 7}
    samples=[macro,macro,micro,nil,%{macro | material: 11}]
    contacts=Circuit.solid_contacts(samples,catalog,damage)
    assert contacts[{0,{8,0,0}}]=={macro,2/64}
    assert contacts[{1,{0,0,0}}]=={%{micro | granularity: 1},1/64}
    assert map_size(contacts)==2
    assert length(Circuit.solid_points(macro))==384
    assert length(Circuit.solid_points(micro))==6
  end

  @tag :phase_coverage
  test "矿石目录失导保留电源余能，普通加工铜替换返回线恢复" do
    {slots,damage,catalog}=fixture()
    catalog=put_in(catalog.materials[24],catalog.materials[16])
    catalog=put_in(catalog.materials[16]["electrical_conductivity"],0.0)
    stopped=plan(slots,damage,catalog,&air/2,0.5)
    assert stopped.outputs[1].remaining_j==6.0
    assert stopped.outputs[1].power_w==0.0
    refute Map.has_key?(stopped.powers,load_key())
    replaced=Map.new(slots,fn
      {{1,_,_}=slot,{id,16}}->{slot,{id,24}}
      item->item
    end)
    running=plan(replaced,damage,catalog,&air/2,0.1)
    assert running.outputs[1].remaining_j<6.0
    assert running.powers[load_key()]>0.0
    assert damage[{3,1}].material==16
  end

  test "跨区线端点串联与光热电能同口径，有限能源截断步长" do
    {slots,damage,catalog}=fixture()
    result=plan(slots,damage,catalog,&air/2,1.0)
    expected=12/(1+12+6*copper())
    assert_in_delta result.outputs[1].current_a,expected,1.0e-8
    assert result.duration<1.0
    assert_in_delta result.outputs[1].remaining_j,0.0,1.0e-10
    assert_in_delta result.supplied_j,6.0,1.0e-9
    # 负载线 λ 0.2：它的 I²R 里 0.2 成为光、其余进热节点；热 + 光 = 供能。
    assert_in_delta result.light_j,0.2*expected*expected*12*result.duration,1.0e-9
    assert_in_delta Enum.sum(Map.values(result.powers))*result.duration+result.light_j,6.0,1.0e-8
    assert result.powers[{4,{3,{0,8,512}}}]>0
  end

  test "开关材料断开（行上 closed 为假，或根本没有行）、断线、近邻绝缘与破损设备都不通电" do
    {slots,damage,catalog}=fixture()
    for d<-[put_in(damage[{3,2}].closed,false),Map.delete(damage,{3,2})] do
      r=plan(slots,d,catalog,&air/2,0.5)
      assert r.outputs[1].current_a==0.0
      assert_in_delta r.outputs[1].remaining_j,6.0,1.0e-9
    end
    for s<-[Map.delete(slots,{1,0,{1,8,512}}),Map.put(slots,{1,0,{1,8,512}},{10,11})] do
      r=plan(s,damage,catalog,&air/2,0.5)
      refute Map.has_key?(r.powers,load_key())
      assert_in_delta r.outputs[1].remaining_j,6.0,1.0e-9
    end
    broken=put_in(damage[{3,1}].circuit.size,8)
    r=plan(slots,broken,catalog,&air/2,0.5)
    assert r.outputs[1].fault==1
    assert r.outputs[1].power_w==0.0
  end

  test "开关材料的格：闭合时按目录电导率进入导体图与接触，断开或无行时绝缘；小块按 granularity 1 热身份的行" do
    {_slots,damage,catalog}=fixture()
    cell=%{micro: {16,0,0},granularity: 0,material: 41,owner: {0,0},incarnation: 3}
    micro=%{micro: {5,6,7},granularity: 2,material: 41,owner: {9,2},incarnation: 9}
    closed=fn t->Map.put(damage,VoxelRegion.Damage.key(t),Map.put(t,:closed,true)) end
    assert Circuit.conductors([cell,micro],catalog,damage)==[]
    assert Circuit.solid_contacts([cell,micro],catalog,damage)==%{}
    assert Circuit.conductors([cell],catalog,closed.(cell))==[cell]
    assert Circuit.sigma(catalog,closed.(cell),cell)==58.0e6
    thermal=%{micro | granularity: 1}
    assert Circuit.conductors([micro],catalog,closed.(thermal))==[thermal]
    # 构件行（granularity 2）不是微格的开合真值。
    assert Circuit.conductors([micro],catalog,closed.(micro))==[]
    assert Circuit.sigma(catalog,closed.(cell),%{cell | material: 16})==58.0e6
  end
  test "体积导体桥接断线；绝缘宿主不能桥接" do
    {slots,damage,catalog}=fixture()
    slots=Map.delete(slots,{1,0,{1,8,512}})
    sample=fn {x,y,z},s->
      t=if x in 0..7 and y in 0..7 and z in 512..519,
        do: %{micro: {0,0,512},granularity: 0,material: 16,owner: {0,0},incarnation: 1}
      {t,s}
    end
    r=plan(slots,damage,catalog,sample,0.1)
    assert r.powers[load_key()]>1.0
    assert r.powers[{0,{0,0,512}}]>0
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
      input = Circuit.prepare(%{slot => {1, 24}}, damage, catalog, 0.5)
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
