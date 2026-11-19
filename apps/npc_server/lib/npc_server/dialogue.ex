defmodule NpcServer.Dialogue do
  @moduledoc """
  NPC 对话能力与已接收 Speech 的纯投影。权威接纳、文本约束和听众裁决只在 SceneServer.Dialogue。
  Runtime 拥有最近 24 句；Life 保存带来源的主观经历，原话不作为已验证世界事实。
  统一形态的说话候选（主动开口 `speak_to:<cid>` 与对话回合里的回复）由 `NpcServer.Offers` 的 `speak_to/2`、`reply/2` 生成。
  """
  alias NpcServer.Life.State

  @history 24

  @doc "说话能力；范围和频率直接引用 Scene 的唯一规则。"
  def entries do
    limits = SceneServer.Dialogue.limits()

    [
      %{
        name: "say",
        group: :dialogue,
        done: "Scene 已接纳并向当时附近听众排入可靠出口；不表示对方理解、答应或已记住。",
        description:
          "向同 Scene #{limits.range_m} 米内公开说话；target_id 指定叫谁，null/0 表示附近。" <>
            "回复时抄 heard 的 conversation_id；null/0 新开话题。text 最多 #{limits.max_chars} 字符、#{limits.max_bytes} 字节，" <>
            "至少间隔 #{limits.interval_ms / 1000} 秒。自主新开话题间隔至少 #{limits.npc_topic_interval_ms / 1000} 秒；" <>
            "同一会话没有玩家再次发言时最多 #{limits.npc_turn_limit} 句NPC发言，空闲 #{limits.idle_ms / 1000} 秒失效。" <>
            "台词由你自己决定；可以用 wait 或继续工作保持沉默。" <>
            "reason=delivery_unknown 表示未收到接纳结果，可能已经说出；先看 heard 与上下文，不得盲目重发。",
        params: [
          text: :string,
          target_id: {:nullable, :integer},
          conversation_id: {:nullable, :integer}
        ],
        build: fn args, _ ->
          %{
            verb: :say,
            text: args.text,
            target_id: args.target_id || 0,
            conversation_id: args.conversation_id || 0
          }
        end
      }
    ]
  end

  @doc "按权威接收顺序追加，只保留最近 24 句；不受技能开始和结束影响。"
  def append(heard, message), do: Enum.take(heard ++ [message], -@history)

  @doc "只有他人明确叫本角色才构成即时唤醒；公开旁听与本人回声不是。"
  def direct?(%{target_id: cid, speaker_id: speaker}, cid), do: speaker != cid
  def direct?(_, _), do: false

  @doc "把最近直接叫到本角色的话加入原有的一次检索查询，不另建聊天召回。"
  def query(query, heard, cid) do
    case Enum.find(Enum.reverse(heard), &direct?(&1, cid)) do
      nil -> query
      message -> query <> " Latest addressed utterance by #{message.speaker_id}: " <> message.text
    end
  end

  @doc """
  权威已发生的 Speech 转成带原话与身份的主观经历 `%{"id", "at_ms", "speech", "text", "tags"}`；没有 World seq，
  不评价心智数值。时刻只在 `"at_ms"`（交给 Hindsight 与心智快照时由 Life 加前缀）。原文：

      I said | I heard: <说话人> said to <对象> in conversation <id>, turn <n>: "<原话>". This is a character's statement, not verified world facts.

  人按 `Life.State.person/2` 写成 `名字 (actor <cid>)`。说话人的名字取自消息自带的 `speaker_name`（说话人不必在视野里，
  也覆盖观察里的写法）；对象的名字只取自 `names`——`%{cid => 名字}`，由 Life 取自它此刻持有的观察，取不到写 `actor <cid>`
  （`target_id` 为 0 即“附近”，写 `actor 0`）。空名写 `someone unnamed`。tags：`kind:conversation` 与对方 `actor:<cid>`——
  我说的话对方是 `target_id`（为 0 时没有对方），我听到的话对方是说话人。
  """
  def episode(message, cid, names) do
    {perspective, other} =
      if message.speaker_id == cid,
        do: {"I said", message.target_id},
        else: {"I heard", message.speaker_id}

    source = message |> Jason.encode!() |> Jason.decode!()
    speaker_names = Map.put(names, message.speaker_id, message.speaker_name)

    %{
      "id" => "speech:#{message.conversation_id}:#{message.turn}",
      "at_ms" => message.at_ms,
      "speech" => source,
      "text" =>
        "#{perspective}: #{State.person(message.speaker_id, speaker_names)} " <>
          "said to #{State.person(message.target_id, names)} in conversation #{message.conversation_id}, " <>
          "turn #{message.turn}: " <>
          Jason.encode!(message.text) <>
          ". This is a character's statement, not verified world facts.",
      "tags" => ["kind:conversation"] ++ if(other in [0, cid], do: [], else: ["actor:#{other}"])
    }
  end
end
