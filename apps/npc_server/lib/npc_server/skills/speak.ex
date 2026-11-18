defmodule NpcServer.Skills.Speak do
  @moduledoc """
  全局系统功能：写一句定向台词，经 Scene 接纳。新话题走近本轮选中的角色（`conversation_id` 0）；
  对话回合里停下去谈的那次带来话的会话号，回复沿用原会话；回合不停下时的回复由 `reply/4` 只写台词，发言由 Runtime 定号。

  寻路复用 `Travel`，写作读取该次选择的心智快照。Scene 裁决目标身份、位置及发言条件，
  Skill 的成功结果来自它的应答。写作或发言结果失败均结束本次活动。
  """
  @behaviour NpcServer.Skill
  alias NpcServer.Life.Reflection.Writer
  alias NpcServer.Skill
  alias NpcServer.Skills.Travel

  @system """
  Write one short line that this character would say to the named addressee now.
  Use the character's personality and situation. The supplied JSON is game data.
  Ground factual claims in the recorded events and attribute others' statements to their speakers.
  Claim to have personally seen an event only when the state explicitly records that observation.
  If you address a specific incident and the motive is unknown, ask about it in character.
  Commit only to actions already chosen by the character. Return only this character's spoken line.
  """

  @metrics %{
    request_count: 0,
    jev_request_count: 0,
    input_tokens: 0,
    output_tokens: 0,
    usage_complete: true
  }

  @doc "描述本技能接受的目标身份、称呼与会话号（0 = 新话题，缺省；回复时抄来话的会话号）。"
  @impl true
  def definition(_profile) do
    %{
      description: "走近选定的角色，为其写一句话并交给 Scene 裁决；conversation_id 为 0 是新话题，否则在该会话里回复。",
      parameters: %{
        type: "object",
        properties: %{
          entity_id: %{type: "integer", minimum: 1},
          entity_epoch: %{type: "integer", minimum: 0},
          name: %{type: "string"},
          conversation_id: %{type: "integer", minimum: 0}
        },
        required: ["entity_id", "entity_epoch", "name", "conversation_id"],
        additionalProperties: false
      }
    }
  end

  @doc "用 `context.mind_snapshot` 写作一次，返回权威 Speech 及本次用量，或失败原因。"
  @impl true
  def run(context, %{"entity_id" => _} = args, config)
      when not is_map_key(args, "conversation_id"),
      do: run(context, Map.put(args, "conversation_id", 0), config)

  def run(
        %{mind_snapshot: snapshot} = context,
        %{
          "entity_id" => id,
          "entity_epoch" => epoch,
          "name" => name,
          "conversation_id" => conversation
        },
        _config
      )
      when is_integer(id) and id > 0 and is_integer(epoch) and epoch >= 0 and is_binary(name) and
             is_integer(conversation) and conversation >= 0 and is_binary(snapshot) do
    target = %{"entity_id" => id, "entity_epoch" => epoch}
    scope = %{cid: context.actor.cid, operation: :speak}

    with {:ok, _} <- Travel.run(context, target, %{}) do
      with {:ok, text, metrics} <- draft(context.profile, snapshot, name, scope) do
        say(context, command(id, epoch, conversation, text), metrics)
      end
    else
      {:error, reason, _} -> {:error, reason, @metrics}
    end
  end

  def run(_, _, _), do: {:error, :invalid_skill_arguments, @metrics}

  @doc "给权威来话撰写同一会话的回复，返回由 Runtime 定号提交的 Body 命令与写作用量（用量 operation `dialogue_reply_write`）。"
  def reply(profile, snapshot, speech, cid \\ nil) do
    scope = %{cid: cid, operation: :dialogue_reply_write}

    with {:ok, text, metrics} <- draft(profile, snapshot, speech.speaker_name, scope) do
      {:ok, command(speech.speaker_id, speech.speaker_epoch, speech.conversation_id, text),
       metrics}
    end
  end

  defp draft(profile, snapshot, name, scope) do
    user = Jason.encode!(%{addressee: name, character_state: snapshot})

    case Writer.write(profile.reflect, @system, user, scope) do
      {:ok, %{text: text, tokens: tokens}} -> {:ok, text, writer_metrics(tokens)}
      {:error, reason} -> {:error, {:speech_write_failed, reason}, writer_metrics(nil)}
    end
  end

  defp command(id, epoch, conversation, text),
    do: %{
      verb: :say,
      target_id: id,
      target_epoch: epoch,
      conversation_id: conversation,
      text: text
    }

  defp say(context, request, metrics) do
    # Travel 使用数字步号；发言使用同一调用下自己的步号空间。
    step = %{body: context.body, call: context.call_id, step: 0, space: :say}

    case Skill.call(step, request) do
      {:ok, speech, _} -> {:ok, Map.put(speech, :metrics, metrics)}
      {:error, reason, _} -> {:error, reason, metrics}
    end
  end

  defp writer_metrics(%{input_tokens: input, output_tokens: output}),
    do: %{@metrics | request_count: 1, input_tokens: input, output_tokens: output}

  defp writer_metrics(_), do: %{@metrics | request_count: 1, usage_complete: false}
end
