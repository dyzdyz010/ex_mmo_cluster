defmodule MmoContracts.MovementScaleWireTest do
  @moduledoc "只测试：Hello34 的权威移动系数冻结字节，不从被测编码器生成期望。"
  use ExUnit.Case, async: true
  alias MmoContracts.Movement

  # domain=2、kind=4、48字节；identity=(1,2,3)、tick=45、0.5=IEEE754 3FE0000000000000。
  @sample Base.decode16!("FF0001020400000030" <>
    "0000000000000001" <> "0000000000000002" <> "0000000000000003" <>
    "000000000000002D" <> "3FE0000000000000" <> "3FD6666666666666")

  test "解码冻结系数并逐字节往返" do
    assert {:ok, value} = Movement.Codec.decode(@sample)
    assert value.apply_tick == 45
    assert value.factor == 0.5
    assert value.input_limit == 0.35
    assert value.identity.session_epoch == 1
    assert {:ok, bytes} = Movement.Codec.encode(value)
    assert IO.iodata_to_binary(bytes) == @sample
  end

  test "非正/大于一/非有限系数和零tick在边界拒绝" do
    <<prefix::binary-size(41), _::binary>> = @sample
    for bits <- [0, 0xBFE0000000000000, 0x3FF8000000000000, 0x7FF8000000000000] do
      assert {:error, :invalid_m1_message} = Movement.Codec.decode(prefix <> <<bits::64>> <> <<0.35::float-64>>)
    end
    <<prefix::binary-size(49), _::binary>> = @sample
    for bits <- [0, 0xBFE0000000000000, 0x3FF8000000000000, 0x7FF8000000000000] do
      assert {:error, :invalid_m1_message} = Movement.Codec.decode(prefix <> <<bits::64>>)
    end
    <<prefix::binary-size(33), _tick::64, factor::binary>> = @sample
    assert {:error, :invalid_m1_message} = Movement.Codec.decode(prefix <> <<0::64>> <> factor)
  end
end
