defmodule VoxelRegion.InventoryCatalogTest do
  # 只测试：Voxim 背包（Voxim/Docs/Inventory.md，2026-09-26）给属性目录加了密度轴 density_kg_m3 与顶层 carry 块（负重上限，只预留、
  # 不生效）。服务端不读这两项：重量只在客户端派生显示，类别是客户端显示数据。这里核对服务端照常加载新目录，并且在线参数升级
  # 接受“加上密度”与“调整密度”（密度不是格行上的状态），其余字段的守卫不变。
  use ExUnit.Case, async: true
  alias VoxelRegion.{Damage, ParameterEvolution}

  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @food "ea9f1ce556c34a195659d02c2cea9cb280690f7456c32ec5f8281b4d61bd1455"
  @backpack "14e17c68527c0b54ef93faaef9a74f23e334a5b6128a48dea1282238d555b937"
  @stone 11
  @dandelion 36

  test "backpack catalog loads and its density axis can be added and tuned online" do
    old = Damage.load(Path.join(@fixtures, @food <> ".json"))
    new = Damage.load(Path.join(@fixtures, @backpack <> ".json"))
    assert Base.encode16(new.digest, case: :lower) == @backpack
    # 手算（设计稿真实密度表）：石 2650 kg/m³；蒲公英一株 40 g 占 1/8 m³ → 0.32 kg/m³。
    assert new.materials[@stone]["density_kg_m3"] == 2650
    assert new.materials[@dandelion]["density_kg_m3"] == 0.32
    refute Map.has_key?(old.materials[@stone], "density_kg_m3")
    assert ParameterEvolution.compatible?(old, new)
    assert ParameterEvolution.compatible?(new, put_in(new.materials[@stone]["density_kg_m3"], 2700))
    # 其余字段的守卫不变：HP 不能在线改（不是相态材料）。
    refute ParameterEvolution.compatible?(new, put_in(new.materials[@stone]["max_hp_per_macro"], 1))
  end
end
