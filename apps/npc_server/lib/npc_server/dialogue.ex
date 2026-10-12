defmodule NpcServer.Dialogue do
  @moduledoc """
  NPC 对话能力与已接收 Speech 的纯投影。权威接纳、文本约束和听众裁决只在 SceneServer.Dialogue。
  Runtime 拥有最近 24 句；Life 保存带来源的主观经历，原话不作为已验证世界事实。
  """
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

  @doc "权威已发生的 Speech 转成带原话与身份的主观经历；没有 World seq，不评价心智数值。"
  def episode(message, cid) do
    at_utc = message.at_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
    perspective = if message.speaker_id == cid, do: "I said", else: "I heard"
    source = message |> Jason.encode!() |> Jason.decode!()

    %{
      "id" => "speech:#{message.conversation_id}:#{message.turn}",
      "at_ms" => message.at_ms,
      "speech" => source,
      "text" =>
        "At #{at_utc} (UTC), #{perspective}: actor #{message.speaker_id} " <>
          "(#{message.speaker_name}, epoch #{message.speaker_epoch}, kind #{message.speaker_kind}) " <>
          "said to actor #{message.target_id} in conversation #{message.conversation_id}, turn #{message.turn}: " <>
          Jason.encode!(message.text) <>
          ". This is a character's statement, not verified world facts."
    }
  end
end
