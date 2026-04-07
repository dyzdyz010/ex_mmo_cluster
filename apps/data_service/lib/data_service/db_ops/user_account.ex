defmodule DataService.DbOps.UserAccount do
  @moduledoc """
  For `User.Account` table operations (Mnesia and Ecto).
  """

  alias DataInit.TableDef, as: Tables
  import Ecto.Query, only: [from: 2]

  @spec check_duplicate(String.t(), String.t(), String.t()) ::
          :ok | {:duplicate, [:email | :phone | :username]}
  def check_duplicate(username, email, phone) do
    is_duplicate_list =
      if is_duplicate_username(username) do
        [:username]
      else
        []
      end ++
        if is_duplicate_email(email) do
          [:email]
        else
          []
        end ++
        if is_duplicate_phone(phone) do
          [:phone]
        else
          []
        end

    case is_duplicate_list do
      [] -> :ok
      _ -> {:duplicate, is_duplicate_list}
    end
  end

  @doc """
  Check if given `username` is duplicated in the table.
  """
  @spec is_duplicate_username(String.t()) :: boolean
  def is_duplicate_username(username) do
    dups =
      Memento.transaction!(fn ->
        Memento.Query.select(Tables.User.Account, {:==, :username, username})
      end)

    case dups do
      [_ | _] ->
        true

      _ ->
        false
    end
  end

  @doc """
  Check if given `username` is duplicated in the table.
  """
  @spec is_duplicate_email(String.t()) :: boolean
  def is_duplicate_email(email) do
    dups =
      Memento.transaction!(fn ->
        Memento.Query.select(Tables.User.Account, {:==, :email, email})
      end)

    case dups do
      [_ | _] ->
        true

      _ ->
        false
    end
  end

  @doc """
  Check if given `username` is duplicated in the table.
  """
  @spec is_duplicate_phone(String.t()) :: boolean
  def is_duplicate_phone(phone) do
    dups =
      Memento.transaction!(fn ->
        Memento.Query.select(Tables.User.Account, {:==, :phone, phone})
      end)

    case dups do
      [_ | _] ->
        true

      _ ->
        false
    end
  end

  # ── Ecto-based duplicate checks ──

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
