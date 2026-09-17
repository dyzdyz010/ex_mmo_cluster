defmodule VoxelRegion.PhaseMaterialTest do
  @moduledoc "只测试：第二相族和雪的参考焓、身份与广延量运输。"
  use ExUnit.Case, async: true
  alias VoxelRegion.Phase
  @moduletag :phase_coverage

  defp properties do
    Map.new([{4,21,273.15,334_000_000.0,1_930_000.0},
      {20,21,273.15,334_000_000.0,1_930_000.0},
      {21,20,273.15,334_000_000.0,4_180_000.0},
      {13,22,1268.15,10_150_000.0,31_900.0},
      {22,13,1268.15,10_150_000.0,31_900.0}],fn {id,peer,t,l,c}->
      {id,%{"phase_peer_material_id"=>peer,"phase_transition_kelvin"=>t,
        "latent_heat_per_macro_j"=>l,"heat_capacity_per_macro"=>c}}
    end)
  end

  test "雪融水再冻成冰，玄武岩由有限加热生成熔岩并释放同一焓" do
    p=properties()
    assert Phase.material(4,334_000_000.0,1.0,p)==21
    assert Phase.material(21,0.0,1.0,p)==20
    basalt=Phase.energy(%{material: 13},1.0,p[13],293.15)
    assert_in_delta basalt,-31_102_500.0,1.0e-6
    lava=p[13]["latent_heat_per_macro_j"]
    assert_in_delta lava-basalt,41_252_500.0,1.0e-6
    assert Phase.material(13,lava,1.0,p)==22
    assert_in_delta Phase.temperature(22,lava,1.0,p),1268.15,1.0e-6
    assert Phase.material(22,0.0,1.0,p)==13
    assert_in_delta Phase.temperature(13,basalt,1.0,p),293.15,1.0e-6
  end

  test "熔岩移动携带有限热和损伤，再凝固不补完整度" do
    p=properties()
    values=Phase.transport(%{a: {10_150_000.0,80.0}},%{a: 100},[{:a,:b,25}])
    assert values==%{a: {7_612_500.0,60.0},b: {2_537_500.0,20.0}}
    assert Phase.material(22,0.0,0.25,p)==13
    assert elem(values.b,1)/25==0.8
  end
end
