defmodule GateServer.Npc.Memory do
  @moduledoc """
  全局系统功能：长期记忆条目（remember / recall / search_memory，形状见 `GateServer.Npc.Abilities`）与执行；
  只读写 NpcMemory，不持有进程缓存，世界状态仍须现查。
  """

  @key_limit 128
  @text_limit 1500
  # search_memory 一次最多返回的条数。
  @matches 5

  @doc "记忆条目（group :memory，顺序固定）；条目形状见 `GateServer.Npc.Abilities`，长度在 `execute/4` 校验。"
  def entries,
    do: [
      %{
        name: "remember",
        group: :memory,
        description:
          "按键保存或覆盖长期记忆：计划、经历与约定。key 1–#{@key_limit} 字，text 1–#{@text_limit} 字。" <>
            "最多保留最近写入的 #{DataService.NpcMemory.limits().notes} 条笔记，更早的会被淘汰；要长期保留的内容请合并进少数几个键。" <>
            "世界现状请重新查询。",
        done: "已写入数据库（data.key、data.body）。",
        params: [key: :string, text: :string],
        build: fn %{key: key, text: text}, _ -> %{verb: :remember, key: key, text: text} end
      },
      %{
        name: "recall",
        group: :memory,
        description: "按键读取自己的长期记忆（key 1–#{@key_limit} 字）；不存在时 data.missing 为 true。记忆不是世界真值。",
        done: "data.body 是该键当前的内容。",
        params: [key: :string],
        build: fn %{key: key}, _ -> %{verb: :recall, key: key} end
      },
      %{
        name: "search_memory",
        group: :memory,
        description:
          "搜索自己的笔记和经历，不必知道键（query 1–#{@text_limit} 字）。英文词/中文片段匹配，最多 #{@matches} 条；" <>
            "换关键词可继续查。历史记忆不是当前世界真值。",
        done: "data.matches 是命中的记忆（带时间）。",
        params: [query: :string],
        build: fn %{query: query}, _ -> %{verb: :search_memory, query: query} end
      }
    ]

  @doc "执行一条记忆命令（来自 Runtime）：长度或类型不合法回 `invalid_memory_arguments`、不写库；返回一个 Outcome。"
  def execute(memory, cid, position, %{id: id, verb: verb} = command) do
    result =
      if valid?(command),
        do: storage(fn -> perform(memory, cid, position, command) end),
        else: {:error, :invalid_memory_arguments}

    case result do
      {:ok, data} -> %{id: id, verb: verb, status: :done, reason: nil, data: data}
      {:error, reason} -> %{id: id, verb: verb, status: :rejected, reason: reason, data: nil}
    end
  end

  @doc "本角色最近的经历（带时间与地点）；数据库不可用时显式返回错误。"
  def recent(memory, cid, limit \\ 5) do
    storage(fn ->
      events =
        Enum.map(memory.recent(cid, limit), fn event ->
          %{
            text: event.text,
            position: Tuple.to_list(event.place),
            at: DateTime.to_iso8601(event.at)
          }
        end)

      {:ok, events}
    end)
  end

  @doc "每轮现读近期经历、近期笔记与相关记忆；不缓存、不把查询失败当空记忆。"
  def context(memory, cid, query) do
    with {:ok, events} <- recent(memory, cid) do
      case storage(fn ->
             notes = memory.recent_notes(cid, 5)
             related = memory.search(cid, query, 5)
             {:ok, Enum.map(Enum.uniq_by(related ++ notes, & &1.id), &dated/1)}
           end) do
        {:ok, records} ->
          %{
            experiences: events,
            memories: records,
            memory_query: query,
            memory_retrieval: :lexical_words_and_cjk_bigrams
          }

        {:error, reason} ->
          %{experiences: events, memory_error: reason}
      end
    else
      {:error, reason} -> %{memory_error: reason}
    end
  end

  defp dated(row), do: Map.update!(row, :at, &DateTime.to_iso8601/1)

  @doc "记录技能结束的事实经历；数据库不可用时显式返回错误。"
  def journal(memory, cid, text, position) do
    storage(fn ->
      case memory.journal(cid, text, position) do
        :ok -> {:ok, :recorded}
        {:error, reason} -> {:error, {:memory_unavailable, reason}}
      end
    end)
  end

  @doc "读取 Life 的单行持久 owner 状态；失败不冒充首次启动。"
  def life_load(memory, cid) do
    storage(fn ->
      case memory.get(cid, "life", "state") do
        {:error, reason} -> {:error, {:memory_unavailable, reason}}
        row -> {:ok, row}
      end
    end)
  end

  @doc "原子保存 canonical 心智、游标与 outbox；只由 Life owner 调用。"
  def life_save(memory, cid, row) do
    storage(fn ->
      case memory.put(cid, "life", "state", row) do
        :ok -> :ok
        {:error, reason} -> {:error, {:memory_unavailable, reason}}
      end
    end)
  end

  defp valid?(%{verb: :remember, key: key, text: text}),
    do: text?(key, @key_limit) and text?(text, @text_limit)

  defp valid?(%{verb: :recall, key: key}), do: text?(key, @key_limit)
  defp valid?(%{verb: :search_memory, query: query}), do: text?(query, @text_limit)
  defp valid?(_), do: false
  defp text?(text, limit), do: is_binary(text) and String.length(text) in 1..limit

  defp perform(memory, cid, position, %{verb: :remember, key: key, text: text}) do
    body = %{"text" => text, "position" => Tuple.to_list(position)}

    case memory.put(cid, "note", key, body) do
      :ok -> {:ok, %{key: key, body: body}}
      {:error, reason} -> {:error, {:memory_unavailable, reason}}
    end
  end

  defp perform(memory, cid, _position, %{verb: :recall, key: key}) do
    case memory.get(cid, "note", key) do
      nil -> {:ok, %{key: key, missing: true}}
      %{} = body -> {:ok, %{key: key, body: body}}
      {:error, reason} -> {:error, {:memory_unavailable, reason}}
    end
  end

  defp perform(memory, cid, _position, %{verb: :search_memory, query: query}),
    do:
      {:ok,
       %{
         query: query,
         method: :lexical_words_and_cjk_bigrams,
         matches: Enum.map(memory.search(cid, query, @matches), &dated/1)
       }}

  # 只转换数据库不可用；程序缺陷继续抛出，错误结果不暴露SQL或连接参数。
  defp storage(fun) do
    try do
      fun.()
    rescue
      exception in [DBConnection.ConnectionError, Postgrex.Error] ->
        {:error, {:memory_unavailable, exception.__struct__}}
    catch
      :exit, _ -> {:error, {:memory_unavailable, :process_exit}}
    end
  end
end
