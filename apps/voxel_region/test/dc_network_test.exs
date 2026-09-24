defmodule VoxelRegion.DCNetworkTest do
  use ExUnit.Case,async: true
  @moduletag :b5
  alias VoxelRegion.DCNetwork
  defp edge(a,b,r,emf \\ 0.0),do: %{a: a,b: b,r: r,emf: emf}

  test "串并联 KCL 与输入功率等于全部 I²R" do
    edges=[edge(:p,:n,1.0,12.0),edge(:p,:x,1.0),edge(:x,:n,6.0),edge(:x,:n,3.0)]
    result=DCNetwork.solve(edges)
    [source,wire,a,b]=result.currents
    assert_in_delta source,-3.0,1.0e-10
    assert_in_delta wire,3.0,1.0e-10
    assert_in_delta a,1.0,1.0e-10
    assert_in_delta b,2.0,1.0e-10
    assert_in_delta -source*12,Enum.zip(edges,result.currents) |> Enum.reduce(0.0,fn {e,i},s->s+i*i*e.r end),1.0e-9
  end
  test "开路、有限内阻短路；多个电源：并联环流、串联相加、独立回路各自求解" do
    assert hd(DCNetwork.solve([edge(1,0,1.0,12.0)]).currents)==0.0
    [i,j]=DCNetwork.solve([edge(1,0,1.0,12.0),edge(1,0,0.001)]).currents
    assert_in_delta i,-12/1.001,1.0e-9
    assert_in_delta j,-i,1.0e-9
    # 12 V 与 6 V 各 1 Ω 并联：节点电压 9 V，环流 (12 − 6)/2 = 3 A；独立回路 12 V/1 Ω 接 2 Ω：V = 8 V，4 A。
    r=DCNetwork.solve([edge(1,0,1.0,12.0),edge(1,0,1.0,6.0),edge(3,2,1.0,12.0),edge(3,2,2.0)])
    [a,b,c,_]=r.currents
    assert_in_delta a,-3.0,1.0e-12
    assert_in_delta b,3.0,1.0e-12
    assert_in_delta c,-4.0,1.0e-12
    assert_in_delta r.volts[1]-r.volts[0],9.0,1.0e-12
    # 两个 12 V/1 Ω 串联接 4 Ω：I = 24/(1 + 1 + 4) = 4 A，中点 8 V、顶端 16 V。
    s=DCNetwork.solve([edge(1,0,1.0,12.0),edge(2,1,1.0,12.0),edge(2,0,4.0)])
    assert_in_delta Enum.at(s.currents,2),4.0,1.0e-12
    assert_in_delta s.volts[2]-s.volts[0],16.0,1.0e-12
  end
  test "树（全部是桥）带电动势：电流严格为 0，端电压逐段等于电动势之和" do
    t=DCNetwork.solve([edge(0,1,1.0,5.0),edge(1,2,1.0,7.0),edge(2,3,3.0)])
    assert t.currents==[0.0,0.0,0.0]
    assert t.volts[0]-t.volts[1]==5.0 and t.volts[1]-t.volts[2]==7.0 and t.volts[2]==t.volts[3]
  end
  test "源支路是桥（开关断开的回路）：严格开路，一端挂着大电导网格也不留舍入电流" do
    # 源一端接一张 20×20、每边 1.8e-5 Ω 的网格（开关断开后的铜面），另一端悬空：精确解每条支路 0 A。
    mesh=for x<-0..19,y<-0..19,{dx,dy}<-[{1,0},{0,1}],x+dx<=19 and y+dy<=19,do: edge({x,y},{x+dx,y+dy},1.766e-5)
    edges=[edge({0,0},:dangling,1.0,24.0)|mesh]
    result=DCNetwork.solve(edges)
    assert Enum.all?(result.currents,&(&1==0.0))
    assert result.volts[{0,0}]-result.volts[:dangling]==24.0
    # 对照：网格另一角经 2 Ω 接回悬空端，回路闭合后源电流 = 24 / (1 + 2 + 网格)。
    closed=DCNetwork.solve(edges++[edge({19,19},:dangling,2.0)])
    assert_in_delta hd(closed.currents),-24/3,24/3*1.0e-3
  end
end
