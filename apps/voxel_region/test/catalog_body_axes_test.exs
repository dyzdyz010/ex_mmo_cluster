defmodule VoxelRegion.CatalogBodyAxesTest do
  # 只测试：身体闭环 H1 给花草加可食轴 food，工具战斗给镐加伤身参数 body_impact。两者只在进食（World 生产意图 action 5）
  # 与命中（Scene ToolAction）时从目录现读，格行上不存与之相关的量，所以在线参数升级应接受“加上”与“调整”，其余守卫不变。
  # 真实案例：青岚世界停在 4b2c6abe，升到 249f2442 时这两项曾被拒为 property_version_in_use。
  use ExUnit.Case, async: true
  alias VoxelRegion.{Damage, ParameterEvolution}

  @fixtures Path.expand("fixtures/combustion", __DIR__)
  @playable Path.expand("../../../../Voxim/Content/Voxel/Properties/Playable/Published", __DIR__)
  @before_food "7b69b79f1786756e857fb8cc0c855e911ce1d015ca2a5efdb25fc76f2a52b45e"
  @qinglan "4b2c6abeaec3818e2203a0b95e3ee03f1cf1aed6bf796c5f33ab41001eb641ed"
  @current "249f2442c082edaf95cb0610b60661d5539a72caa5ca0b4fd594632c84eb4839"
  @dandelion 36
  @pick 1

  test "food and body_impact can be added and tuned online; other guards stay" do
    base = Damage.load(Path.join(@fixtures, @before_food <> ".json"))
    refute Map.has_key?(base.materials[@dandelion], "food")
    refute Map.has_key?(base.tools[@pick], "body_impact")

    fed =
      put_in(base.materials[@dandelion]["food"], %{"protein_g" => 1.08, "energy_j" => 75_362.4})

    armed =
      put_in(fed.tools[@pick]["body_impact"], %{"depth" => 0.2, "protein_g" => 2, "heal_s" => 100})

    assert ParameterEvolution.compatible?(base, armed)

    assert ParameterEvolution.compatible?(
             armed,
             put_in(armed.materials[@dandelion]["food"]["energy_j"], 80_000.0)
           )

    assert ParameterEvolution.compatible?(
             armed,
             put_in(armed.tools[@pick]["body_impact"]["heal_s"], 120)
           )

    # 其余字段的守卫不变：非相态材料的 HP、工具射程都不能在线改。
    refute ParameterEvolution.compatible?(
             armed,
             put_in(armed.materials[@dandelion]["max_hp_per_macro"], 1)
           )

    refute ParameterEvolution.compatible?(armed, put_in(armed.tools[@pick]["range_macro"], 99))
  end

  test "the Qinglan world catalog upgrades to the current playable catalog" do
    old = Damage.load(Path.join(@playable, @qinglan <> ".json"))
    new = Damage.load(Path.join(@playable, @current <> ".json"))
    assert Base.encode16(new.digest, case: :lower) == @current
    assert ParameterEvolution.compatible?(old, new)
  end
end
