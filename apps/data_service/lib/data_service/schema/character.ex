defmodule DataService.Schema.Character do
  use Ecto.Schema
  # PERS-5:durable_authoritative(角色)。见 MmoContracts.StateRegistry。
  use MmoContracts.StateClassed, class: :durable_authoritative
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :id, autogenerate: false}
  schema "characters" do
    # "player" | "npc"。NPC 没有账号，鉴权按账号匹配角色，所以玩家无法以 NPC 的 cid 登录。
    field(:kind, :string, default: "player")
    field(:account, :integer)
    field(:name, :string)
    field(:title, :string)
    field(:base_attrs, :map)
    field(:battle_attrs, :map)
    field(:position, :map)
    field(:hp, :integer)
    field(:sp, :integer)
    field(:mp, :integer)
    # 主链（Voxim Docs/Factions.md §2.1）：每层最多一个组织，写入只走 DataService.Orgs。
    field(:guild_id, :id)
    field(:nation_id, :id)
    # 登录时由 GateServer.Session.Auth.join/2 用 DataService.Orgs.profile/1 填入，随 Scene.join 进入实体值；不落库。
    field(:profile, :map, virtual: true)

    timestamps()
  end

  def changeset(character, attrs) do
    character
    |> cast(attrs, [
      :id,
      :kind,
      :account,
      :name,
      :title,
      :base_attrs,
      :battle_attrs,
      :position,
      :hp,
      :sp,
      :mp
    ])
    |> validate_required([:id, :name])
    |> validate_inclusion(:kind, ["player", "npc"])
    |> then(
      &if(get_field(&1, :kind) == "player", do: validate_required(&1, [:account]), else: &1)
    )
    |> check_constraint(:account, name: :npc_has_no_account)
    |> unique_constraint(:name)
  end
end
