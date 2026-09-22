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

  @doc "近期笔记；与经历分开，避免新笔记被事件淹没。"
  def recent_notes(cid, limit) do
    Repo.all(from m in @table, where: m.cid == ^cid and m.kind == "note",
      order_by: [desc: m.inserted_at, desc: m.id], limit: ^limit,
      select: %{id: m.id, kind: m.kind, key: m.key, body: m.body,
        at: type(m.inserted_at, :utc_datetime_usec)})
    |> Enum.map(&Map.put(&1, :position, &1.body["position"]))
  end

  @doc "按 cid 检索笔记/经历；英文词与中文相邻字片段匹配，命中数优先，同分新在前。不是向量语义检索。"
  def search(cid, query, limit) do
    terms = Regex.scan(~r/[\p{Han}]+|[\p{L}\p{N}_]+/u, String.downcase(query))
      |> List.flatten()
      |> Enum.flat_map(fn word ->
        if Regex.match?(~r/^\p{Han}{2,}$/u, word),
          do: word |> String.graphemes() |> Enum.chunk_every(2, 1, :discard) |> Enum.map(&Enum.join/1),
          else: [word]
      end)
      |> Enum.reject(&(&1 == "_")) |> Enum.uniq() |> Enum.take(32)
    fragments = Enum.filter(terms, &Regex.match?(~r/\p{Han}/u, &1))

    result = Ecto.Adapters.SQL.query!(Repo, """
      SELECT m.id, m.kind, m.key, m.body, m.inserted_at, m.x, m.y, m.z, hit.score
      FROM npc_memories m
      CROSS JOIN LATERAL (
        SELECT count(*) AS score FROM unnest($2::text[]) AS term
        WHERE term = ANY(regexp_split_to_array(lower(coalesce(m.key, '') || ' ' || coalesce(m.body->>'text', '')), '[^[:alnum:]_]+'))
          OR (term = ANY($4::text[]) AND strpos(coalesce(m.key, '') || ' ' || coalesce(m.body->>'text', ''), term) > 0)
      ) hit
      WHERE m.cid = $1 AND m.kind IN ('note', 'event') AND hit.score > 0
      ORDER BY hit.score DESC, m.inserted_at DESC, m.id DESC LIMIT $3
      """, [cid, terms, limit, fragments])
    Enum.map(result.rows, fn [id, kind, key, body, at, x, y, z, score] ->
      %{id: id, kind: kind, key: key, body: body, at: DateTime.from_naive!(at, "Etc/UTC"),
        position: if(kind == "event", do: [x,y,z], else: body["position"]), score: score}
    end)
  end
end
