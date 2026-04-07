defmodule DataService.Schema.Account do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  schema "accounts" do
    field :username, :string
    field :password, :string
    field :salt, :string
    field :email, :string
    field :phone, :string

    timestamps()
  end

  def changeset(account, attrs) do
    account
    |> cast(attrs, [:id, :username, :password, :salt, :email, :phone])
    |> validate_required([:id, :username, :password, :salt])
    |> unique_constraint(:username)
    |> unique_constraint(:email)
  end
end
