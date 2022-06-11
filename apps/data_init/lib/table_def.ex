defmodule DataInit.TableDef do
  defmodule User.Account do
    use Memento.Table,
      attributes: [:id, :username, :password, :email, :phone],
      index: [:email, :username],
      type: :set
  end

  defmodule User.Character do
    use Memento.Table,
      attributes: [:id, :account, :name, :title, :base_attrs, :battle_attrs, :position, :hp, :sp, :mp],
      index: [:name],
      type: :set
  end

  def user_table_list() do
    [User.Account, User.Character]
  end

  def tables() do
    [User.Account, User.Character]
  end
end
