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
  defp air(_p,s),do: {nil,s}

  @tag :phase_coverage
  test "矿石目录失导保留设备余能，普通加工铜替换返回线恢复" do
    {slots,damage,catalog}=fixture()
    catalog=put_in(catalog.materials[24],catalog.materials[16])
    catalog=put_in(catalog.materials[16]["electrical_conductivity"],0.0)
    stopped=Circuit.plan(slots,damage,catalog,nil,&air/2,0.5)
    assert stopped.outputs[1].remaining_j==6.0
    assert stopped.outputs[1].power_w==0.0
    assert stopped.outputs[3].power_w==0.0
    replaced=Map.new(slots,fn
      {{1,_,_}=slot,{id,16}}->{slot,{id,24}}
      item->item
    end)
    running=Circuit.plan(replaced,damage,catalog,nil,&air/2,0.1)
    assert running.outputs[1].remaining_j<6.0
    assert running.outputs[3].power_w>0.0
    assert damage[{3,1}].material==16
  end

  test "跨区线端点串联与光热电能同口径，有限能源截断步长" do
    {slots,damage,catalog}=fixture()
    result=Circuit.plan(slots,damage,catalog,nil,&air/2,1.0)
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
      r=Circuit.plan(s,d,catalog,nil,&air/2,0.5)
      assert_in_delta r.outputs[3].power_w,0.0,1.0e-9
      assert_in_delta r.outputs[1].remaining_j,6.0,1.0e-9
    end
    broken=put_in(damage[{3,3}].circuit.size,8)
    r=Circuit.plan(slots,broken,catalog,nil,&air/2,0.5)
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
    r=Circuit.plan(slots,damage,catalog,nil,sample,0.1)
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
    r=Circuit.plan(slots,damage,catalog,state,&air/2,0.5)
    assert r.duration==0.05
    assert r.powers[{4,{1,{2,8,511}}}]<0
    assert r.outputs[1].remaining_j<6.0
    assert_in_delta r.cooling_j,2*r.outputs[3].power_w*r.duration,1.0e-9
    assert_in_delta r.rejected_j,r.cooling_j+r.outputs[3].power_w*r.duration,1.0e-9
    assert_in_delta Enum.sum(Map.values(r.powers))*r.duration+r.rejected_j,r.supplied_j,1.0e-8
    t=Attachments.identity({0,1,{2,8,511}},{3,16}) |> Map.put(:granularity,4)
    cold=Map.put(damage,VoxelRegion.Damage.key(t),Map.put(t,:temperature_kelvin,250.0))
    for d<-[cold,put_in(damage[{3,1}].circuit.remaining_j,0.0),put_in(damage[{3,2}].circuit.closed,false)] do
      stopped=Circuit.plan(slots,d,catalog,state,&air/2,0.5)
      assert stopped.cooling_j==0.0
      assert stopped.supplied_j==0.0
      assert stopped.duration==0.5
    end
    warm=Map.put(damage,VoxelRegion.Damage.key(t),Map.put(t,:temperature_kelvin,250.001))
    limited=Circuit.plan(slots,warm,catalog,state,&air/2,0.5)
    capacity=catalog.materials[16]["heat_capacity_per_macro"]*VoxelRegion.ThermalAttachments.volume({0,1,{2,8,511}},catalog)
    assert limited.cooling_j<=capacity*0.001+1.0e-9
    assert_in_delta Enum.sum(Map.values(limited.powers))*limited.duration+limited.rejected_j,limited.supplied_j,1.0e-8
  end
end
