defmodule MmoContracts.DialogueWireTest do
  @moduledoc "只测试：固定手写字节验证新增对话，不以自编码自解码代替线契约。"
  use ExUnit.Case, async: true
  alias MmoContracts.Session

  @identity %Session.Identity{session_epoch: 1, scene_id: 2, scene_epoch: 3}
  @say <<255, 1::16, 1, 15, 56::32, 1::64, 2::64, 3::64, 4::64, 5::64, 0::64, 6::16, 0xE4, 0xBD,
         0xA0, 0xE5, 0xA5, 0xBD>>
  @speech <<255, 1::16, 1, 16, 82::32, 1::64, 2::64, 3::64, 6::64, 1::32, 7::64, 8::64, 1, 3::16,
            0xE7, 0x94, 0xB2, 5::64, 9::64, 6::16, 0xE4, 0xBD, 0xA0, 0xE5, 0xA5, 0xBD>>
  @result <<255, 1::16, 1, 17, 48::32, 1::64, 2::64, 3::64, 4::64, 6::64, 1::32, 2::16, "ok">>

  test "Hello 40 explicitly negotiates dialogue capability" do
    assert Session.Codec.protocol_version() == 40

    assert {:error, :invalid_m1_message} =
             Session.Codec.decode(<<255, 1::16, 1, 1, 66::32, 39::16, 0::512>>)
  end

  test "player Say golden preserves Chinese and contains no speaker claim" do
    assert {:ok, request} = Session.Codec.decode(@say)
    assert request.__struct__ == Session.Say

    assert Map.from_struct(request) == %{
             identity: @identity,
             request_id: 4,
             target_id: 5,
             conversation_id: 0,
             text: "你好"
           }

    assert {:ok, @say} = Session.Codec.encode(request)
  end

  test "authoritative Speech golden includes its own display identity and exact turn" do
    assert {:ok, speech} = Session.Codec.decode(@speech)
    assert speech.__struct__ == Session.Speech

    assert Map.from_struct(speech) == %{
             identity: @identity,
             conversation_id: 6,
             turn: 1,
             speaker_id: 7,
             speaker_epoch: 8,
             speaker_kind: 1,
             speaker_name: "甲",
             target_id: 5,
             at_ms: 9,
             text: "你好"
           }

    assert {:ok, @speech} = Session.Codec.encode(speech)
  end

  test "SayResult golden associates acceptance with the request and conversation" do
    assert {:ok, result} = Session.Codec.decode(@result)
    assert result.__struct__ == Session.SayResult

    assert Map.from_struct(result) == %{
             identity: @identity,
             request_id: 4,
             conversation_id: 6,
             turn: 1,
             reason: "ok"
           }

    assert {:ok, @result} = Session.Codec.encode(result)
  end

  test "truncated, trailing, wrong domain and invalid UTF-8 never produce partial speech" do
    for bytes <- [
          binary_part(@say, 0, byte_size(@say) - 1),
          @speech <> <<0>>,
          <<255, 1::16, 2, 15, 0::32>>,
          <<255, 1::16, 1, 15, 51::32, 1::64, 2::64, 3::64, 4::64, 5::64, 0::64, 1::16, 255>>
        ] do
      assert {:error, :invalid_m1_message} = Session.Codec.decode(bytes)
    end
  end
end
