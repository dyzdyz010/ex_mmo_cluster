defmodule VoxelRegion.ThermalNativeTest do
  use ExUnit.Case, async: true
  alias VoxelRegion.{Thermal, ThermalNative}

  test "批量与逐步导热、有限供能、过热损伤和能量账一致" do
    cells=[{63,0,0},{64,0,0},{65,1,0}]
    material=%{"heat_capacity_per_macro"=>1000.0,"thermal_conductivity"=>100.0}
    nodes=Map.new(Enum.zip(cells,[400.0,350.0,300.0]),fn {cell,t}->
      {cell,%{temperature: t,material: material,exposed_faces: 5}} end)
    sources=%{hd(cells)=>%{remaining_j: 50.0,power_w: 120.0}}
    config=%{"ambient_kelvin"=>293.15,"environment_w_per_m2_k"=>10.0}
    input=for cell<-cells do
      n=nodes[cell]; s=Map.get(sources,cell,%{power_w: 0.0,remaining_j: 0.0})
      {n.temperature,100.0,100.0,1000.0,100.0,310.0,5.0,s.power_w,s.remaining_j,true}
    end
    {10,result,supplied,environment}=ThermalNative.batch(input,[{0,1}],293.15,10.0,0.01,0.05,10)
    {expected,left,hps,energy}=Enum.reduce(1..10,{nodes,sources,Map.new(cells,&{&1,100.0}),%{supplied_j: 0.0,environment_j: 0.0}},fn _,{n,s,h,e}->
      {temps,s,q}=Thermal.step(n,s,config,0.05)
      h=Map.new(h,fn {cell,hp}->{cell,max(0.0,hp-100.0*0.05*max(0.0,temps[cell]/310.0-1.0))} end)
      n=Map.new(n,fn {cell,row}->{cell,%{row|temperature: temps[cell]}} end)
      {n,s,h,%{supplied_j: e.supplied_j+q.supplied_j,environment_j: e.environment_j+q.environment_j}}
    end)
    for {cell,{t,hp,remaining}}<-Enum.zip(cells,result) do
      assert_in_delta t,expected[cell].temperature,1.0e-10
      assert_in_delta hp,hps[cell],1.0e-10
      assert_in_delta remaining,Map.get(left,cell,%{remaining_j: 0.0}).remaining_j,1.0e-10
    end
    assert_in_delta supplied,energy.supplied_j,1.0e-10
    assert_in_delta environment,energy.environment_j,1.0e-8
  end

  test "热前沿在变化的第一步交还 World，不等十步批次结束" do
    hot={400.0,100.0,100.0,1000.0,100.0,1000.0,5.0,0.0,0.0,true}
    cold={293.15,100.0,100.0,1000.0,100.0,1000.0,5.0,0.0,0.0,false}
    assert {1,[_,{t,_,_}],_,_}=ThermalNative.batch([hot,cold],[{0,1}],293.15,0.0,0.01,0.05,10)
    assert t>293.16
  end

  test "原生边界拒绝非法索引" do
    assert_raise ArgumentError,fn -> ThermalNative.batch([], [{0,1}],293.15,0.0,0.01,0.05,10) end
  end

  test "源耗尽且温差低于阈值时立即交还 World 收缩活动范围" do
    node={293.15,100.0,100.0,1000.0,100.0,310.0,6.0,10.0,0.001,true}
    assert {1,[{t,100.0,0.0}],supplied,0.0}=ThermalNative.batch([node],[],293.15,0.0,0.01,0.05,10)
    assert_in_delta t,293.150001,1.0e-10
    assert supplied==0.001
  end
end
