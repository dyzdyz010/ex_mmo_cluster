defmodule DataService.DbOps.UserAccount do
  @moduledoc """
  For `User.Account` table's Mnesia operations.
  """

  alias DataInit.TableDef, as: Tables

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
end
