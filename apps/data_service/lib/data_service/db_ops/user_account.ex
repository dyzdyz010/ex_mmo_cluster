defmodule DataService.DbOps.UserAccount do
  @moduledoc """
  For `User.Account` table's Mnesia operations.
  """

  @doc """
  Check if given `username` is duplicated in the table.
  """
  @spec is_duplicate_username(String.t()) :: boolean
  def is_duplicate_username(username) do
    dups = Memento.transaction!(fn ->
      Memento.Query.select(Tables.User.Account, {:==, :username, username})
    end)
    case dups do
      [_|_] ->
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
    dups = Memento.transaction!(fn ->
      Memento.Query.select(Tables.User.Account, {:==, :email, email})
    end)
    case dups do
      [_|_] ->
        true
      _ ->
        false
    end
  end
end
