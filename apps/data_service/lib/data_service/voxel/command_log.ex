defmodule DataService.Voxel.CommandLog do
  @moduledoc """
  Durable command replay-protection(梯队1 step1.5,AUTH-4 / SEC-4)。

  两种命令形态,两种幂等机制:

  **A. 原子单步命令(单方块编辑)—— `record_once/3`**:
  以**单条原子** `INSERT ... ON CONFLICT (command_id) DO NOTHING RETURNING` 判定 `:fresh`/`:duplicate`。
  在世界写入事务内调用即与写入**同事务**,得到 exactly-once:重复 `command_id` 不重复产生 durable 副作用。
  插入行 `status` 走列默认 `'committed'`(命令落库即完成)。

  **B. 多步 / 跨节点命令(prefab 跨 chunk 事务)—— `claim/3` + `confirm/3` / `release/2`**:
  durable 写跨多节点多 chunk,无单一事务可包裹。用 idempotency-key:`claim` 原子认领
  (`status='pending'`)→ 执行工作 → 成功 `confirm`(`'committed'` + 缓存结果)/ 失败 `release`(DELETE)。
  `release` 保证失败命令不堵塞合法重试(exactly-once,而非 at-most-once)。崩溃残留的 pending 由后续
  清理 sweeper 回收(backlog),期间 duplicate `claim` 得 `:in_flight` 被拒——安全(不产重复资产)。

  Postgres 主键唯一约束 + ON CONFLICT 提供线性化判定(并发重复只有一个得到 `:fresh`)。
  stateless module,直走 `DataService.Repo`(`opts[:repo]` 可覆盖)。状态分类见
  `MmoContracts.StateRegistry`(durable_authoritative)。
  """

  # PERS-5:durable_authoritative(命令幂等日志)。见 MmoContracts.StateRegistry。
  use MmoContracts.StateClassed, class: :durable_authoritative

  alias DataService.Repo

  @doc """
  幂等登记 `command_id`。返回 `:fresh`(首次,应执行副作用)或 `:duplicate`(重复,应跳过)。
  """
  @spec record_once(String.t(), non_neg_integer(), keyword()) :: :fresh | :duplicate
  def record_once(command_id, logical_scene_id, opts \\ [])
      when is_binary(command_id) and is_integer(logical_scene_id) do
    result_code = Keyword.get(opts, :result_code)

    sql = """
    INSERT INTO voxel_command_log (command_id, logical_scene_id, result_code, inserted_at, updated_at)
    VALUES ($1, $2, $3, now(), now())
    ON CONFLICT (command_id) DO NOTHING
    RETURNING command_id
    """

    case Ecto.Adapters.SQL.query!(repo(opts), sql, [command_id, logical_scene_id, result_code]) do
      %{rows: [[_]]} -> :fresh
      %{rows: []} -> :duplicate
    end
  end

  @doc "该 command_id 是否已登记过。"
  @spec seen?(String.t(), keyword()) :: boolean()
  def seen?(command_id, opts \\ []) when is_binary(command_id) do
    sql = "SELECT 1 FROM voxel_command_log WHERE command_id = $1"

    case Ecto.Adapters.SQL.query!(repo(opts), sql, [command_id]) do
      %{rows: [[_]]} -> true
      %{rows: []} -> false
    end
  end

  @typedoc """
  `claim/3` 结果:
    * `:fresh` —— 首次见到,调用方应执行工作,成功后 `confirm/4`、失败后 `release/2`。
    * `{:duplicate, result}` —— 该命令已 committed,`result`(可能为 nil)是缓存结果摘要,
      调用方应据此重建等价成功响应,**不重复执行副作用**。
    * `:in_flight` —— 该命令仍 pending(同连接顺序处理通常不会撞;视为崩溃残留),调用方
      应返回可重试错误。stale pending 由后续清理 sweeper 回收(backlog)。
  """
  @type claim_result :: :fresh | {:duplicate, String.t() | nil} | :in_flight

  @doc """
  幂等键认领(prefab 等多步/跨节点命令,AUTH-4 idempotency key)。

  单条原子 `INSERT ... ON CONFLICT DO UPDATE`(no-op SET 锁住既有行)+ `xmax = 0` 判定是否
  本次插入:`xmax = 0` ⇒ 新插入(`:fresh`),否则命中既有行(按 `status` 返回 duplicate / in_flight)。
  插入行 `status='pending'`,需 `confirm`/`release` 收尾。
  """
  @spec claim(String.t(), non_neg_integer(), keyword()) :: claim_result()
  def claim(command_id, logical_scene_id, opts \\ [])
      when is_binary(command_id) and is_integer(logical_scene_id) do
    sql = """
    INSERT INTO voxel_command_log (command_id, logical_scene_id, status, inserted_at, updated_at)
    VALUES ($1, $2, 'pending', now(), now())
    ON CONFLICT (command_id) DO UPDATE SET command_id = voxel_command_log.command_id
    RETURNING (xmax = 0) AS inserted, status, result_code
    """

    case Ecto.Adapters.SQL.query!(repo(opts), sql, [command_id, logical_scene_id]) do
      %{rows: [[true, _status, _result]]} -> :fresh
      %{rows: [[false, "committed", result]]} -> {:duplicate, result}
      %{rows: [[false, "pending", _result]]} -> :in_flight
    end
  end

  @doc """
  确认幂等键命令已完成:`status='committed'` + 缓存 `result`(供 duplicate 重建 ack)。
  必须在 `claim/3` 返回 `:fresh` 且工作成功后调用。
  """
  @spec confirm(String.t(), String.t() | nil, keyword()) :: :ok
  def confirm(command_id, result, opts \\ []) when is_binary(command_id) do
    sql = """
    UPDATE voxel_command_log
       SET status = 'committed', result_code = $2, updated_at = now()
     WHERE command_id = $1
    """

    Ecto.Adapters.SQL.query!(repo(opts), sql, [command_id, result])
    :ok
  end

  @doc """
  释放幂等键(DELETE):`claim/3` 返回 `:fresh` 后工作失败时调用,使合法重试不被堵塞
  (exactly-once,而非 at-most-once)。
  """
  @spec release(String.t(), keyword()) :: :ok
  def release(command_id, opts \\ []) when is_binary(command_id) do
    Ecto.Adapters.SQL.query!(
      repo(opts),
      "DELETE FROM voxel_command_log WHERE command_id = $1",
      [command_id]
    )

    :ok
  end

  @doc "清空命令日志(test-only hatch)。"
  @spec reset(keyword()) :: :ok
  def reset(opts \\ []) do
    Ecto.Adapters.SQL.query!(repo(opts), "DELETE FROM voxel_command_log", [])
    :ok
  end

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)
end
