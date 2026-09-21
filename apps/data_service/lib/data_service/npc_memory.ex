defmodule DataService.NpcMemory do
  @moduledoc """
  全局系统功能：NPC 的长期记忆，按永久 cid 存在 `npc_memories` 表里，不依赖任何模型的上下文，进程重启、换决策后端都在。

  只存世界里查不到的东西；世界状态永远现查（记忆不是第二真值）。两类：
    * 工作记忆 `put/4` / `get/3` / `delete/3`：`{cid, kind, key}` 唯一、可覆盖（例：当前蓝图）；
    * 经历 `journal/3` / `recent/2`：只追加，一条一句英文短句 + 发生地点，给调度模型和规划者当背景。

  与 `DataService.CharacterStore` 同范式：直接走 `DataService.Repo` 的模块函数。`body` 是纯 JSON 数据（字符串键）。
  """
  import Ecto.Query, only: [from: 2]
  alias DataService.Repo

  @table "npc_memories"

  def put(cid, kind, key, %{} = body) when is_integer(cid) and is_binary(kind) and is_binary(key) do
    row = %{cid: cid, kind: kind, key: key, body: body, inserted_at: DateTime.utc_now()}

    Repo.insert_all(@table, [row],
      on_conflict: {:replace, [:body, :inserted_at]},
      conflict_target: {:unsafe_fragment, "(cid, kind, key) WHERE key IS NOT NULL"}
    )

    :ok
  end

  def get(cid, kind, key),
    do: Repo.one(from m in @table, where: m.cid == ^cid and m.kind == ^kind and m.key == ^key, select: m.body)

  def delete(cid, kind, key) do
    Repo.delete_all(from m in @table, where: m.cid == ^cid and m.kind == ^kind and m.key == ^key)
    :ok
  end

  def journal(cid, text, {x, y, z}) when is_integer(cid) and is_binary(text) do
    row = %{cid: cid, kind: "event", body: %{"text" => text}, x: x / 1, y: y / 1, z: z / 1, inserted_at: DateTime.utc_now()}
    Repo.insert_all(@table, [row])
    :ok
  end

  @doc "最近的经历，新在前：`[%{text:, place: {x, y, z}, at: DateTime}]`。"
  def recent(cid, limit) do
    Repo.all(
      from m in @table,
        where: m.cid == ^cid and m.kind == "event",
        order_by: [desc: m.inserted_at, desc: m.id],
        limit: ^limit,
        select: %{text: fragment("?->>'text'", m.body), place: {m.x, m.y, m.z}, at: type(m.inserted_at, :utc_datetime_usec)}
    )
  end
end
