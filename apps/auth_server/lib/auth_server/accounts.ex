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
end
