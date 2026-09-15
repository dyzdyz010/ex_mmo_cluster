defmodule VoxelRegion.ThermalTest do
  use ExUnit.Case, async: true
  alias VoxelRegion.Thermal

  defp node_at(t), do: %{temperature: t,exposed_faces: 5,material: %{"heat_capacity_per_macro"=>1000.0,"thermal_conductivity"=>100.0}}
  defp config(h), do: %{"ambient_kelvin"=>293.15,"environment_w_per_m2_k"=>h}

  test "contact crosses chunk and region; corner neighbor remains isolated" do
    a={63,0,0}; b={64,0,0}; c={65,1,0}
    nodes=%{a=>node_at(400.0),b=>node_at(300.0),c=>node_at(300.0)}
    assert Thermal.contacts(nodes)==[{a,b}]
    {next,_,q}=Thermal.step(nodes,%{},config(0.0),0.1)
    assert next[a]==399.0
    assert next[b]==301.0
    assert next[c]==300.0
    assert q==%{supplied_j: 0.0,environment_j: 0.0}
  end

  test "finite source and ambient exchange close the energy ledger" do
    a={0,0,0}
    nodes=%{a=>node_at(300.0)}
    sources=%{a=>%{remaining_j: 50.0,power_w: 1000.0}}
    {next,sources,q}=Thermal.step(nodes,sources,config(10.0),0.1)
    assert sources[a].remaining_j==0.0
    assert q.supplied_j==50.0
    assert_in_delta (next[a]-300.0)*1000.0,q.supplied_j+q.environment_j,1.0e-8
  end

  test "50 and 25 ms steps remain bounded and converge to the two-node solution" do
    a={15,0,0}; b={16,0,0}
    solve=fn dt ->
      Enum.reduce(1..round(10/dt),%{a=>node_at(400.0),b=>node_at(300.0)},fn _,nodes ->
        {next,_,_}=Thermal.step(nodes,%{},config(0.0),dt)
        assert next[a]>=next[b] and next[a]<=400.0 and next[b]>=300.0
        assert_in_delta next[a]+next[b],700.0,1.0e-9
        Map.new(nodes,fn {cell,n}->{cell,%{n | temperature: next[cell]}} end)
      end)[a].temperature
    end
    coarse=solve.(0.05); fine=solve.(0.025)
    exact=350.0+50.0*:math.exp(-2.0)
    assert abs(fine-exact)<abs(coarse-exact)
    assert_in_delta coarse,fine,0.04
  end
end
