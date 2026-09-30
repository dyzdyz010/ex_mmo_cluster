defmodule MmoContracts.ToolWireTest do
  @moduledoc "Test-only: Hello35 ToolState fixture: identity24 + request8 + source24 + action4 + target16 + part7 + body2 = 85 bytes."
  use ExUnit.Case, async: true
  alias MmoContracts.Session

  @sample Base.decode16!(
            "FF0001010D00000055" <>
              "0000000000000001" <>
              "0000000000000002" <>
              "0000000000000003" <>
              "0000000000000004" <>
              "0000000000000005" <>
              "0000000000000006" <>
              "0000000000000007" <>
              "00000008" <>
              "0000000000000009" <> "000000000000000A" <> "0005" <> "746F72736F" <> "50" <> "14"
          )

  test "tool receipt matches fixed bytes" do
    value = %Session.ToolState{
      identity: %Session.Identity{session_epoch: 1, scene_id: 2, scene_epoch: 3},
      request_id: 4,
      source_id: 5,
      source_session: 6,
      source_life: 7,
      action_seq: 8,
      target_id: 9,
      target_life: 10,
      part: "torso",
      life: 80,
      recoverable: 20
    }

    {:ok, bytes} = Session.Codec.encode(value)
    assert IO.iodata_to_binary(bytes) == @sample
    assert {:ok, ^value} = Session.Codec.decode(@sample)
  end
end
