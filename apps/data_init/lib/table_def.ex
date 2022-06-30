defmodule DataInit.TableDef do
  defmodule User.Account do
    use Memento.Table,
      attributes: [:id, :username, :password, :salt, :email, :phone],
      index: [:email, :username],
      type: :set
  end

  defmodule User.Character do
    use Memento.Table,
      attributes: [
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
      ],
      index: [:name],
      type: :set
  end

  defmodule User.AccountSession do
    use Memento.Table,
      attributes: [
        :id,
        :account_id,
        :code_id,
        :ip,
        :port,
        :connected_at,
        :closed_at,
        :created_at,
        :updated_at
      ],
      index: [:account, :character],
      type: :set
  end

  def user_table_list() do
    [User.Account, User.Character]
  end

  def tables() do
    [User.Account, User.Character]
  end
end
