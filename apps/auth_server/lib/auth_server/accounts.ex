defmodule AuthServer.Accounts do
  alias DataInit.TableDef, as: Tables

  def create_account(fields) do
    account = %Tables.User.Account{
      username: fields.username,
      password: fields.password,
      email: fields.email,
      phone: fields.phone
    }
    {:ok, account}
  end

  def find_by_username(username) do
    account = Tables.User.Account.find_by(username: username)

    {:ok, account}
  end
end
