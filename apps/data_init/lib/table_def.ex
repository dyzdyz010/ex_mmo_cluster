defmodule DataInit.TableDef do
  defmodule User.Account do
    use Memento.Table,
      attributes: [:id, :username, :password, :character_list, :email, :phone],
      index: [:id, :email, :username],
      type: :ordered_set,
      autoincrement: true
  end

  defmodule User.Character do
    use Memento.Table,
      attributes: [:id, :name, :title, :base_attrs, :battle_attrs, :position, :hp, :sp, :mp],
      index: [:id, :name],
      type: :ordered_set,
      autoincrement: true
  end

  def user_table_list() do
    [User.Account, User.Character]
  end
end
