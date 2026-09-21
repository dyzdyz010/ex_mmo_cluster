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
    |> then(&if(get_field(&1, :kind) == "player", do: validate_required(&1, [:account]), else: &1))
    |> check_constraint(:account, name: :npc_has_no_account)
    |> unique_constraint(:name)
  end
end
