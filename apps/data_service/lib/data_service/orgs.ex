defmodule DataService.Orgs do
  @moduledoc """
  全局系统功能：组织、成员与立场的持久真值（Voxim Docs/Factions.md §2、§3）。

  `profile/1` 在登录时把角色的主链与所属组织的立场组装成 `MmoContracts.Relation` 档案，随实体值传播；
  立场在会话期间不刷新（P1 只有登录前写入的作者数据，运行时变更与补发见 Factions §10）。
  其余函数是写入入口：P1 由 Test-only 作者脚本调用，P4 的玩家公会操作复用同一组函数。
  """

  import Ecto.Query, only: [from: 2]

  alias DataService.Repo
  alias DataService.Schema.{Character, Org, OrgStanding}

  @doc "按名字取或建国家。"
  def ensure_nation(name), do: ensure(%{kind: "nation", name: name})

  @doc "按名字取或建公会；`nation_id` 为 nil 表示不属于任何国家。"
  def ensure_guild(name, nation_id), do: ensure(%{kind: "guild", name: name, nation_id: nation_id})

  defp ensure(attrs) do
    case Repo.get_by(Org, name: attrs.name) do
      nil -> %Org{} |> Org.changeset(attrs) |> Repo.insert()
      org -> {:ok, org}
    end
  end

  @doc "写入（覆盖）`from` 对 `to` 的立场。"
  def put_standing(from_id, to_id, relation, locked, source) do
    %OrgStanding{}
    |> OrgStanding.changeset(%{
      from_org_id: from_id,
      to_org_id: to_id,
      relation: Atom.to_string(relation),
      locked: locked,
      source: source
    })
    |> Repo.insert(
      on_conflict: {:replace, [:relation, :locked, :source, :updated_at]},
      conflict_target: [:from_org_id, :to_org_id]
    )
  end

  @doc """
  把角色放进组织。加入公会时国家随公会（无国家的公会则清空国家）；直接入籍国家时，
  若原公会不属于该国则离开公会。主链每层最多一个（Factions §2.1）。
  """
  def join(cid, org_id) do
    org = Repo.get!(Org, org_id)
    character = Repo.get!(Character, cid)

    chain =
      case org.kind do
        "guild" ->
          %{guild_id: org.id, nation_id: org.nation_id}

        "nation" ->
          guild = character.guild_id && Repo.get!(Org, character.guild_id)
          keep = guild != nil and guild.nation_id == org.id
          %{guild_id: if(keep, do: guild.id), nation_id: org.id}
      end

    character |> Ecto.Changeset.change(chain) |> Repo.update()
  end

  @doc "离开公会；国籍保留。"
  def leave_guild(cid) do
    Repo.get!(Character, cid) |> Ecto.Changeset.change(guild_id: nil) |> Repo.update()
  end

  @doc "`MmoContracts.Relation` 档案：名字、主链与主链上组织对外的立场。"
  def profile(%Character{} = character) do
    ids = Enum.reject([character.guild_id, character.nation_id], &is_nil/1)
    orgs = Repo.all(from(o in Org, where: o.id in ^ids)) |> Map.new(&{&1.id, &1})
    standings = Repo.all(from(s in OrgStanding, where: s.from_org_id in ^ids))

    %{
      name: character.name,
      guild: org_ref(orgs[character.guild_id]),
      nation: org_ref(orgs[character.nation_id]),
      standings:
        for s <- standings do
          %{
            from: if(s.from_org_id == character.guild_id, do: :guild, else: :nation),
            to: s.to_org_id,
            relation: String.to_existing_atom(s.relation),
            locked: s.locked,
            source: s.source
          }
        end
    }
  end

  defp org_ref(nil), do: nil
  defp org_ref(%Org{id: id, name: name}), do: %{id: id, name: name}
end
