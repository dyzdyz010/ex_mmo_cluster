defmodule DataService.Schema.Character do
  use Ecto.Schema
  # PERS-5:durable_authoritative(角色)。见 MmoContracts.StateRegistry。
  use MmoContracts.StateClassed, class: :durable_authoritative
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :id, autogenerate: false}
  schema "characters" do
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
    |> validate_required([:id, :account, :name])
    |> unique_constraint(:name)
  end
end
