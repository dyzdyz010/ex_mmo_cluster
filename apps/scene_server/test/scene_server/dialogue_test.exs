defmodule SceneServer.DialogueTest do
  use ExUnit.Case, async: true
  alias SceneServer.Dialogue
  alias MmoContracts.Session

  defp identity(epoch),
    do: %Session.Identity{session_epoch: epoch, scene_id: 1, scene_epoch: 7}

  defp actor(id, position, kind \\ 0),
    do: %{id: id, epoch: id, kind: kind, name: "角色#{id}", position: position, available: true}

  defp request(id, changes \\ %{}),
    do: Map.merge(%{request_id: id, target_id: 0, conversation_id: 0, text: " 你好，世界 \n"}, changes)

  defp say(state, who, request, roster, now, conversation \\ 100),
    do: Dialogue.say(state, who, request, roster, now, 1_800_000_000_000 + now, conversation)

  test "权威三维听众、本人回声、中文修剪与最近请求去重" do
    a = identity(1)
    b = identity(2)
    c = identity(3)

    roster = %{
      a => actor(1, {0, 0, 0}),
      b => actor(2, {0, 12, 0}, 1),
      c => actor(3, {0, 12.01, 0})
    }

    req = request(1, %{target_id: 2, speaker_name: "伪造"})

    {state, {:ok, speech}, recipients} = say(Dialogue.new(), a, req, roster, 0)
    assert MapSet.new(recipients) == MapSet.new([a, b])
    assert speech.text == "你好，世界"
    assert speech.speaker_name == "角色1"
    assert speech.speaker_id == 1
    assert speech.conversation_id == 100
    assert speech.turn == 1
    {state, {:ok, ^speech}, []} = say(state, a, req, roster, 1)
    {state, {:error, :request_conflict}, []} = say(state, a, %{req | text: "不同"}, roster, 2)
    {state, {:error, :rate_limited}, []} = say(state, a, request(2), roster, 1999)
    assert {_, {:error, :stale_request}, []} = say(state, a, req, roster, 2000)
    assert Dialogue.observe(state).accepted == 1
  end

  test "文本边界明确拒绝，不截断中文或吞掉控制字符" do
    who = identity(1)
    roster = %{who => actor(1, {0, 0, 0})}

    for {text, reason} <- [
          {" \n ", :empty_text},
          {<<255>>, :invalid_text},
          {"\t你好", :invalid_text},
          {"你好\r", :invalid_text},
          {String.duplicate("中", 513), :text_too_long},
          {String.duplicate("é", 512) <> String.duplicate("́", 300), :text_too_long}
        ] do
      assert {_, {:error, ^reason}, []} =
               say(Dialogue.new(), who, request(1, %{text: text}), roster, 0)
    end

    for text <- ["你好\n世界", String.duplicate("中", 512), String.duplicate("😀", 512)] do
      assert {_, {:ok, %{text: ^text}}, [^who]} =
               say(Dialogue.new(), who, request(1, %{text: text}), roster, 0)
    end
  end

  test "每次重检目标与听众，不能猜会话或用重连身份加入" do
    a = identity(1)
    b = identity(2)
    c = identity(3)
    roster = %{a => actor(1, {0, 0, 0}), b => actor(2, {0, 0, 1}, 1), c => actor(3, {0, 30, 0})}
    {state, {:ok, _}, _} = say(Dialogue.new(), a, request(1), roster, 0)

    assert {_, {:error, :conversation_forbidden}, []} =
             say(state, c, request(1, %{conversation_id: 100}), roster, 2000)

    assert {_, {:error, :invalid_session}, []} =
             say(state, a, request(2, %{identity: b}), roster, 2000)

    assert {_, {:error, :target_out_of_range}, []} =
             say(state, a, request(2, %{target_id: 3}), roster, 2000)

    assert {_, {:error, :target_unavailable}, []} =
             say(state, a, request(2, %{target_id: 77}), roster, 2000)

    assert {_, {:error, :not_ready}, []} =
             say(state, b, request(1), put_in(roster[b].available, false), 2000)

    moved = put_in(roster[b].position, {0, 13, 0})

    assert {_, {:ok, %{turn: 2}}, [^a]} =
             say(state, a, request(2, %{conversation_id: 100}), moved, 2000)

    assert {_, {:error, :target_out_of_range}, []} =
             say(state, a, request(2, %{conversation_id: 100, target_id: 2}), moved, 2000)

    rejoined = Map.put(Map.delete(roster, b), identity(4), roster[b])
    state = Dialogue.leave(state, b)

    assert {_, {:error, :conversation_forbidden}, []} =
             say(state, identity(4), request(1, %{conversation_id: 100}), rejoined, 2000)
  end

  test "NPC连续8句后拒绝，玩家发言重置；新话题5分钟冷却不会因重连绕过" do
    a = identity(1)
    b = identity(2)
    roster = %{a => actor(1, {0, 0, 0}), b => actor(2, {1, 0, 0}, 1)}
    {state, {:ok, _}, _} = say(Dialogue.new(), a, request(1), roster, 0)

    state =
      Enum.reduce(1..8, state, fn turn, state ->
        {state, {:ok, speech}, _} =
          say(state, b, request(turn, %{conversation_id: 100}), roster, turn * 2000)

        assert speech.turn == turn + 1
        state
      end)

    {state, {:error, :conversation_limit}, []} =
      say(state, b, request(9, %{conversation_id: 100}), roster, 18_000)

    {state, {:ok, %{turn: 10}}, _} =
      say(state, a, request(2, %{conversation_id: 100}), roster, 18_000)

    assert {_, {:ok, %{turn: 11}}, _} =
             say(state, b, request(10, %{conversation_id: 100}), roster, 18_000)

    {state, {:ok, _}, _} = say(Dialogue.new(), b, request(1), roster, 0)

    assert {_, {:error, :topic_rate_limited}, []} =
             say(state, b, request(2), roster, 299_999, 200)

    rejoined = Map.put(Map.delete(roster, b), identity(3), roster[b])
    state = Dialogue.leave(state, b)

    assert {_, {:error, :topic_rate_limited}, []} =
             say(state, identity(3), request(1), rejoined, 2000, 200)

    assert {_, {:ok, %{conversation_id: 200}}, _} =
             say(state, identity(3), request(1), rejoined, 300_000, 200)
  end

  test "120秒空闲由owner主动退休，且失败结果原样去重" do
    who = identity(1)
    roster = %{who => actor(1, {0, 0, 0})}
    {state, {:ok, _}, _} = say(Dialogue.new(), who, request(1), roster, 0)
    assert Dialogue.next_expiry(state) == 120_000
    assert Dialogue.observe(Dialogue.expire(state, 119_999)).active_conversations == 1
    state = Dialogue.expire(state, 120_000)
    assert Dialogue.observe(state).active_conversations == 0
    assert Dialogue.next_expiry(state) == nil

    {state, {:error, :conversation_expired}, []} =
      say(state, who, request(2, %{conversation_id: 100}), roster, 120_000)

    {state, {:error, :conversation_expired}, []} =
      say(state, who, request(2, %{conversation_id: 100}), roster, 122_000)

    assert Dialogue.observe(state).replayed == 1
  end
end
