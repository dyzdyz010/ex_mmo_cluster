defmodule DataService.Schema.Org do
  @moduledoc "全局系统功能：国家或公会（Voxim Docs/Factions.md §2）。公会最多挂在一个国家下。"
  use Ecto.Schema
  use MmoContracts.StateClassed, class: :durable_authoritative
  import Ecto.Changeset

  schema "orgs" do
    field(:kind, :string)
    field(:name, :string)
    field(:nation_id, :id)

    timestamps()
  end

  def changeset(org, attrs) do
    org
    |> cast(attrs, [:kind, :name, :nation_id])
    |> validate_required([:kind, :name])
    |> validate_inclusion(:kind, ["nation", "guild"])
    |> check_constraint(:nation_id, name: :nation_has_no_nation)
    |> unique_constraint(:name)
  end
end

defmodule DataService.Schema.OrgStanding do
  @moduledoc "全局系统功能：组织对组织的立场；锁定条目（战争、盟约）下级不能覆盖（Factions.md §3）。"
  use Ecto.Schema
  use MmoContracts.StateClassed, class: :durable_authoritative
  import Ecto.Changeset

  @primary_key false
  schema "org_standings" do
    field(:from_org_id, :id, primary_key: true)
    field(:to_org_id, :id, primary_key: true)
    field(:relation, :string)
    field(:locked, :boolean, default: false)
    field(:source, :string)

    timestamps()
  end

  def changeset(standing, attrs) do
    standing
    |> cast(attrs, [:from_org_id, :to_org_id, :relation, :locked, :source])
    |> validate_required([:from_org_id, :to_org_id, :relation, :source])
    |> validate_inclusion(:relation, ["friendly", "neutral", "hostile"])
  end
end
