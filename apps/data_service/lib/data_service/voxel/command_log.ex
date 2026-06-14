defmodule DataService.Voxel.CommandLog do
  @moduledoc """
  Durable command replay-protection(梯队1 step1.5,AUTH-4 / SEC-4)。

  `record_once/3` 以**单条原子** `INSERT ... ON CONFLICT (command_id) DO NOTHING RETURNING` 判定:

    * 首次见到该 `command_id` → 插入 → `:fresh`
    * 已存在(重复命令)→ 不插入 → `:duplicate`

  在世界写入事务内调用即与写入同事务,得到 exactly-once:重复 `command_id` 不重复产生 durable 副作用。
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

  @doc "清空命令日志(test-only hatch)。"
  @spec reset(keyword()) :: :ok
  def reset(opts \\ []) do
    Ecto.Adapters.SQL.query!(repo(opts), "DELETE FROM voxel_command_log", [])
    :ok
  end

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)
end
