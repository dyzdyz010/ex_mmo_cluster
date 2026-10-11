defmodule SceneServer.Dialogue do
  @moduledoc """
  全局系统功能：附近公开对话的纯接纳规则；状态与时钟由 Movement.Scene 唯一拥有。

  角色表只接收 Scene 已知的权威观察，身份、位置、姓名与种类均不来自发言请求。
  接纳返回不可变 Speech 数据及本次听众；重复请求只返回原结果，不再次投递。
  """

  @limits %{
    range_m: 12.0,
    max_chars: 512,
    max_bytes: 2048,
    interval_ms: 2000,
    npc_topic_interval_ms: 300_000,
    npc_turn_limit: 8,
    idle_ms: 120_000
  }
  @max_u64 0xFFFFFFFFFFFFFFFF

  @doc "服务端规则及 NPC 能力说明共同消费的唯一参数源。"
  def limits, do: @limits

  @doc "创建当前 Scene 独占的空对话状态。"
  def new do
    %{
      conversations: %{},
      requests: %{},
      last_said: %{},
      last_topic: %{},
      accepted: 0,
      rejected: 0,
      replayed: 0
    }
  end

  @doc "只读接纳统计，不泄露尚未向调用方投递的发言内容。"
  def observe(state),
    do:
      Map.take(state, [:accepted, :rejected, :replayed])
      |> Map.put(:active_conversations, map_size(state.conversations))

  @doc "移除离场身份的请求与听众资格；NPC 新话题冷却仍按角色保留到期。"
  def leave(state, identity) do
    conversations =
      Map.new(state.conversations, fn {id, conversation} ->
        {id, %{conversation | heard: MapSet.delete(conversation.heard, identity)}}
      end)

    %{
      state
      | conversations: conversations,
        requests: Map.delete(state.requests, identity),
        last_said: Map.delete(state.last_said, identity)
    }
  end

  @doc "由 Scene 自有定时器推进空闲失效及角色话题冷却退休，不依赖新发言。"
  def expire(state, now_ms) do
    %{
      state
      | conversations:
          Map.reject(state.conversations, fn {_, c} -> now_ms - c.last_ms >= @limits.idle_ms end),
        last_topic:
          Map.reject(state.last_topic, fn {_, at} ->
            now_ms - at >= @limits.npc_topic_interval_ms
          end)
    }
  end

  @doc "下一项需要 owner 自行退休的单调时钟 deadline；空状态无需定时器。"
  def next_expiry(state) do
    deadlines =
      Enum.map(state.conversations, fn {_, c} -> c.last_ms + @limits.idle_ms end) ++
        Enum.map(state.last_topic, fn {_, at} -> at + @limits.npc_topic_interval_ms end)

    Enum.min(deadlines, fn -> nil end)
  end

  @doc "按当前权威角色表裁决一次请求，返回 {状态, 结果, 本次投递身份}。时间与新会话号由 owner 提供。"
  def say(state, identity, request, roster, now_ms, at_ms, new_conversation_id) do
    state = expire(state, now_ms)

    with {:ok, actor} <- speaker(roster, identity),
         :ok <- request_shape(request, identity) do
      fingerprint = Map.take(request, [:target_id, :conversation_id, :text])

      case Map.get(state.requests, identity) do
        %{id: id, fingerprint: ^fingerprint, result: result} when id == request.request_id ->
          {%{state | replayed: state.replayed + 1}, result, []}

        %{id: id} when id == request.request_id ->
          reject(state, :request_conflict)

        %{id: id} when id > request.request_id ->
          reject(state, :stale_request)

        _ ->
          {next, result, recipients} =
            accept(state, identity, actor, request, roster, now_ms, at_ms, new_conversation_id)

          cache = %{id: request.request_id, fingerprint: fingerprint, result: result}
          {%{next | requests: Map.put(next.requests, identity, cache)}, result, recipients}
      end
    else
      {:error, reason} -> reject(state, reason)
    end
  end

  defp speaker(roster, identity) do
    case roster[identity] do
      nil -> {:error, :invalid_session}
      actor -> {:ok, actor}
    end
  end

  defp request_shape(
         %{request_id: id, target_id: target, conversation_id: conversation, text: text} = request,
         identity
       )
       when is_integer(id) and id >= 0 and id <= @max_u64 and is_integer(target) and target >= 0 and
              target <= @max_u64 and
              is_integer(conversation) and conversation >= 0 and conversation <= @max_u64 and
              is_binary(text) do
    if Map.get(request, :identity, identity) == identity,
      do: :ok,
      else: {:error, :invalid_session}
  end

  defp request_shape(_, _), do: {:error, :invalid_request}

  defp accept(state, identity, actor, request, roster, now_ms, at_ms, new_id) do
    with :ok <- if(actor.available, do: :ok, else: {:error, :not_ready}),
         {:ok, text} <- text(request.text),
         :ok <- interval(state.last_said[identity], now_ms, @limits.interval_ms, :rate_limited),
         {:ok, recipients} <- audience(actor, request.target_id, roster),
         {:ok, id, conversation} <-
           conversation(state, identity, actor, request.conversation_id, now_ms, new_id) do
      speech = %{
        conversation_id: id,
        turn: conversation.turn + 1,
        speaker_id: actor.id,
        speaker_epoch: actor.epoch,
        speaker_kind: actor.kind,
        speaker_name: actor.name,
        target_id: request.target_id,
        at_ms: at_ms,
        text: text
      }

      conversation = %{
        turn: speech.turn,
        npc_turns: if(actor.kind == 1, do: conversation.npc_turns + 1, else: 0),
        last_ms: now_ms,
        heard: MapSet.union(conversation.heard, MapSet.new(recipients))
      }

      state = %{
        state
        | conversations: Map.put(state.conversations, id, conversation),
          last_said: Map.put(state.last_said, identity, now_ms),
          last_topic:
            if(actor.kind == 1 and request.conversation_id == 0,
              do: Map.put(state.last_topic, actor.id, now_ms),
              else: state.last_topic
            ),
          accepted: state.accepted + 1
      }

      {state, {:ok, speech}, recipients}
    else
      {:error, reason} -> reject(state, reason)
    end
  end

  defp text(raw) do
    if String.valid?(raw) do
      trimmed = String.trim(raw)

      cond do
        # 先检查原文，不能借首尾修剪把 TAB、CR 等不合法控制字符吞掉。
        Regex.match?(~r/[\x00-\x09\x0B-\x1F\x7F-\x9F]/u, raw) ->
          {:error, :invalid_text}

        trimmed == "" ->
          {:error, :empty_text}

        byte_size(trimmed) > @limits.max_bytes or String.length(trimmed) > @limits.max_chars ->
          {:error, :text_too_long}

        true ->
          {:ok, trimmed}
      end
    else
      {:error, :invalid_text}
    end
  end

  defp audience(actor, target, roster) do
    recipients =
      for {identity, other} <- roster,
          other.available and in_range?(actor.position, other.position),
          do: identity

    cond do
      target == 0 ->
        {:ok, recipients}

      Enum.any?(recipients, &(roster[&1].id == target)) ->
        {:ok, recipients}

      Enum.any?(roster, fn {_, other} -> other.id == target and other.available end) ->
        {:error, :target_out_of_range}

      true ->
        {:error, :target_unavailable}
    end
  end

  defp in_range?({x, y, z}, {a, b, c}),
    do:
      (x - a) * (x - a) + (y - b) * (y - b) + (z - c) * (z - c) <=
        @limits.range_m * @limits.range_m

  defp conversation(state, _identity, actor, 0, now_ms, new_id) do
    with :ok <-
           if(actor.kind == 1,
             do:
               interval(
                 state.last_topic[actor.id],
                 now_ms,
                 @limits.npc_topic_interval_ms,
                 :topic_rate_limited
               ),
             else: :ok
           ) do
      {:ok, new_id, %{turn: 0, npc_turns: 0, heard: MapSet.new()}}
    end
  end

  defp conversation(state, identity, actor, id, _now_ms, _new_id) do
    case state.conversations[id] do
      nil ->
        {:error, :conversation_expired}

      conversation ->
        cond do
          not MapSet.member?(conversation.heard, identity) ->
            {:error, :conversation_forbidden}

          actor.kind == 1 and conversation.npc_turns >= @limits.npc_turn_limit ->
            {:error, :conversation_limit}

          true ->
            {:ok, id, conversation}
        end
    end
  end

  defp interval(nil, _, _, _), do: :ok

  defp interval(previous, now_ms, required, reason),
    do: if(now_ms - previous >= required, do: :ok, else: {:error, reason})

  defp reject(state, reason), do: {%{state | rejected: state.rejected + 1}, {:error, reason}, []}
end
