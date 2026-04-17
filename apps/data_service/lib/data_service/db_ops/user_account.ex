defmodule DataService.DbOps.UserAccount do
  @moduledoc """
  `User.Account` table operations backed by PostgreSQL (Ecto).
  """

  import Ecto.Query, only: [from: 2]

  @spec check_duplicate_ecto(String.t(), String.t(), String.t()) ::
          :ok | {:duplicate, [:email | :phone | :username]}
  def check_duplicate_ecto(username, email, phone) do
    dups =
      if(exists_ecto?(:username, username), do: [:username], else: []) ++
        if(exists_ecto?(:email, email), do: [:email], else: []) ++
        if exists_ecto?(:phone, phone), do: [:phone], else: []

    case dups do
      [] -> :ok
      _ -> {:duplicate, dups}
    end
  end

  defp exists_ecto?(field, value) when not is_nil(value) and value != "" do
    query =
      from(a in DataService.Schema.Account,
        where: field(a, ^field) == ^value,
        select: 1,
        limit: 1
      )

    DataService.Repo.exists?(query)
  end

  defp exists_ecto?(_field, _value), do: false
end
