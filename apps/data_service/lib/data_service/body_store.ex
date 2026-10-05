defmodule DataService.BodyStore do
  @moduledoc """
  Global system：按角色保存 Scene 身体 owner 生成的完整快照字节。

  身体、生命代次与分世界食物游标由 Scene 一起编码；本模块不解释身体规则，不读取旧 HP 字段。
  `claim/3` 原子取得当前会话的写入权并读回原快照，`save/4` 只接纳该代次的写入。
  同代次重复 claim 幂等；较旧代次明确拒绝。数据库错误直接暴露，不把存储失败当首次出生。

  代次来自现行 Claims 分配器。旧 owner 必须在正常重登交接前完成最后一次保存；
  移交中的被动目标只能在激活时 claim，不能在准备阶段撤销源的写入权。
  同 owner 的保存由 Player 邮箱同步排序，不引入第二套状态修订号。

  依据 PostgreSQL 的原子 `ON CONFLICT DO UPDATE ... WHERE ... RETURNING`：
  https://www.postgresql.org/docs/current/sql-insert.html#SQL-ON-CONFLICT
  未满足 WHERE 的行不返回，正好表示陈旧 owner。`opts[:repo]` 用于独立数据库测试。
  """

  use MmoContracts.StateClassed, class: :durable_authoritative

  alias DataService.Repo
  alias Ecto.Adapters.SQL

  @doc "取得会话写入权并读回快照；nil 仅表示该角色尚未保存过身体。"
  @spec claim(integer(), non_neg_integer(), keyword()) ::
          {:ok, binary() | nil} | {:error, :stale_owner}
  def claim(cid, owner_epoch, opts \\ []) do
    sql = """
    INSERT INTO character_bodies AS current (cid, owner_epoch)
    VALUES ($1, $2)
    ON CONFLICT (cid) DO UPDATE SET owner_epoch = EXCLUDED.owner_epoch
    WHERE current.owner_epoch <= EXCLUDED.owner_epoch
    RETURNING snapshot
    """

    case SQL.query!(repo(opts), sql, [cid, owner_epoch]).rows do
      [[snapshot]] -> {:ok, snapshot}
      [] -> {:error, :stale_owner}
    end
  end

  @doc "原子替换当前 owner 的完整快照；未 claim 或旧会话写入均明确拒绝。"
  @spec save(integer(), non_neg_integer(), binary(), keyword()) :: :ok | {:error, :stale_owner}
  def save(cid, owner_epoch, snapshot, opts \\ []) when is_binary(snapshot) do
    sql = """
    UPDATE character_bodies SET snapshot = $3
    WHERE cid = $1 AND owner_epoch = $2
    """

    case SQL.query!(repo(opts), sql, [cid, owner_epoch, snapshot]).num_rows do
      1 -> :ok
      0 -> {:error, :stale_owner}
    end
  end

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)
end
