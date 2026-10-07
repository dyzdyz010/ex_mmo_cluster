defmodule MmoContracts.RelationTest do
  @moduledoc """
  只测试：Voxim Docs/Factions.md §3 五关解析。期望值按设计文档手算：
  硬规则 → 锁定 → 从具体到宽泛 → 反向只取敌对 → 中立，来源文字格式"甲 对 乙：关系（来源[，锁定]）"。
  """
  use ExUnit.Case, async: true
  alias MmoContracts.Relation

  @qinglan %{id: 1, name: "青岚国"}
  @beiyuan %{id: 2, name: "北原国"}
  @anvil %{id: 11, name: "铁砧公会"}
  @merchant %{id: 12, name: "青岚商会"}
  @frost %{id: 21, name: "霜狼公会"}

  defp war(to, locked), do: %{from: :nation, to: to, relation: :hostile, locked: locked, source: "国战"}

  defp member(name, guild, nation, standings),
    do: %{name: name, guild: guild, nation: nation, standings: standings}

  test "自己与同组织走硬规则，不看立场" do
    alan = member("阿岚", @anvil, @qinglan, [war(2, true)])
    xiaohe = member("小禾", @merchant, @qinglan, [war(2, true)])
    smith = member("铁匠", @anvil, @qinglan, [])

    assert Relation.resolve(1, alan, 1, alan) == {:self, "自己"}
    assert Relation.resolve(1, alan, 3, smith) == {:own, "同属铁砧公会"}
    assert Relation.resolve(1, alan, 2, xiaohe) == {:own, "同属青岚国"}
  end

  test "锁定的国战压过更具体的公会友好；不锁定时更具体的公会立场生效" do
    guild_friendly = %{from: :guild, to: 21, relation: :friendly, locked: false, source: "公会声明"}
    beichen = member("北辰", @frost, @beiyuan, [])

    locked = member("阿岚", @anvil, @qinglan, [guild_friendly, war(2, true)])
    assert Relation.resolve(1, locked, 2, beichen) == {:hostile, "青岚国 对 北原国：敌对（国战，锁定）"}

    open = member("阿岚", @anvil, @qinglan, [guild_friendly, war(2, false)])
    assert Relation.resolve(1, open, 2, beichen) == {:friendly, "铁砧公会 对 霜狼公会：友好（公会声明）"}
  end

  test "同一层里先查对方更具体的组织" do
    # 青岚国对霜狼公会敌对、对北原国友好：北辰在霜狼公会，先命中公会那条。
    standings = [
      %{from: :nation, to: 2, relation: :friendly, locked: false, source: "邦交"},
      %{from: :nation, to: 21, relation: :hostile, locked: false, source: "通缉组织"}
    ]

    alan = member("阿岚", nil, @qinglan, standings)
    beichen = member("北辰", @frost, @beiyuan, [])
    baihua = member("白桦", nil, @beiyuan, [])

    assert Relation.resolve(1, alan, 2, beichen) == {:hostile, "青岚国 对 霜狼公会：敌对（通缉组织）"}
    assert Relation.resolve(1, alan, 3, baihua) == {:friendly, "青岚国 对 北原国：友好（邦交）"}
  end

  test "我方没有立场时，对方的敌对反向生效；对方的友好不反向生效" do
    alan = member("阿岚", @anvil, @qinglan, [])
    hostile = member("北辰", @frost, @beiyuan, [war(1, false)])
    friendly = member("白桦", nil, @beiyuan, [%{from: :nation, to: 1, relation: :friendly, locked: false, source: "邦交"}])

    assert Relation.resolve(1, alan, 2, hostile) == {:hostile, "北原国 对 青岚国：敌对（国战）"}
    assert Relation.resolve(1, alan, 3, friendly) == {:neutral, "没有任何立场"}
  end

  test "自由人与无名档案：中立" do
    alan = member("阿岚", @anvil, @qinglan, [war(2, true)])
    assert Relation.resolve(1, alan, 9, Relation.blank()) == {:neutral, "没有任何立场"}
    assert Relation.resolve(9, Relation.blank(), 1, alan) == {:neutral, "没有任何立场"}
  end

  test "线上关系字节" do
    assert Enum.map([:neutral, :self, :own, :friendly, :hostile], &Relation.code/1) == [0, 1, 2, 3, 4]
  end
end
