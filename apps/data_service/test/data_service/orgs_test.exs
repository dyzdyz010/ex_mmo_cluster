defmodule DataService.OrgsTest do
  @moduledoc """
  只测试：Voxim Docs/Factions.md §2.1 主链（每层最多一个、公会决定国家）与登录档案。DB-backed。
  """
  use ExUnit.Case, async: false

  alias DataService.{Orgs, Repo}
  alias DataService.Schema.{Character, Org, OrgStanding}

  setup_all do
    MmoTest.Database.start!()
    :ok
  end

  setup do
    Repo.update_all(Character, set: [guild_id: nil, nation_id: nil])
    Repo.delete_all(OrgStanding)
    Repo.delete_all(Org)
    Repo.delete_all(Character)
    :ok
  end

  defp player(id) do
    %Character{}
    |> Character.changeset(%{id: id, account: id, name: "char-#{id}", base_attrs: %{}, battle_attrs: %{}})
    |> Repo.insert!()
  end

  test "加入公会时国家随公会；直接入籍别国则离开原公会，入籍本国则保留" do
    {:ok, qinglan} = Orgs.ensure_nation("青岚国")
    {:ok, beiyuan} = Orgs.ensure_nation("北原国")
    {:ok, anvil} = Orgs.ensure_guild("铁砧公会", qinglan.id)
    player(1)

    {:ok, c} = Orgs.join(1, anvil.id)
    assert {c.guild_id, c.nation_id} == {anvil.id, qinglan.id}

    {:ok, c} = Orgs.join(1, qinglan.id)
    assert {c.guild_id, c.nation_id} == {anvil.id, qinglan.id}

    {:ok, c} = Orgs.join(1, beiyuan.id)
    assert {c.guild_id, c.nation_id} == {nil, beiyuan.id}

    {:ok, c} = Orgs.leave_guild(1)
    assert c.nation_id == beiyuan.id
  end

  test "同名再建得到同一个组织" do
    {:ok, a} = Orgs.ensure_nation("青岚国")
    {:ok, b} = Orgs.ensure_nation("青岚国")
    assert a.id == b.id
  end

  test "档案带名字、主链与主链组织对外的立场；无组织角色档案为空链" do
    {:ok, qinglan} = Orgs.ensure_nation("青岚国")
    {:ok, beiyuan} = Orgs.ensure_nation("北原国")
    {:ok, anvil} = Orgs.ensure_guild("铁砧公会", qinglan.id)
    {:ok, frost} = Orgs.ensure_guild("霜狼公会", beiyuan.id)
    {:ok, _} = Orgs.put_standing(qinglan.id, beiyuan.id, :hostile, true, "国战")
    {:ok, _} = Orgs.put_standing(anvil.id, frost.id, :friendly, false, "公会声明")
    # 别的组织的立场不进这名角色的档案。
    {:ok, _} = Orgs.put_standing(beiyuan.id, qinglan.id, :hostile, true, "国战")
    player(1)
    player(2)
    {:ok, _} = Orgs.join(1, anvil.id)

    profile = Orgs.profile(Repo.get!(Character, 1))
    assert profile.name == "char-1"
    assert profile.guild == %{id: anvil.id, name: "铁砧公会"}
    assert profile.nation == %{id: qinglan.id, name: "青岚国"}

    assert Enum.sort_by(profile.standings, & &1.from) == [
             %{from: :guild, to: frost.id, relation: :friendly, locked: false, source: "公会声明"},
             %{from: :nation, to: beiyuan.id, relation: :hostile, locked: true, source: "国战"}
           ]

    assert Orgs.profile(Repo.get!(Character, 2)) ==
             %{name: "char-2", guild: nil, nation: nil, standings: []}
  end

  test "覆盖写立场：同一对组织只有一条" do
    {:ok, qinglan} = Orgs.ensure_nation("青岚国")
    {:ok, beiyuan} = Orgs.ensure_nation("北原国")
    {:ok, _} = Orgs.put_standing(qinglan.id, beiyuan.id, :hostile, true, "国战")
    {:ok, _} = Orgs.put_standing(qinglan.id, beiyuan.id, :friendly, true, "盟约")

    assert [%OrgStanding{relation: "friendly", source: "盟约"}] = Repo.all(OrgStanding)
  end
end
