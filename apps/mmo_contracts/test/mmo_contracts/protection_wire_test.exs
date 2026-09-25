defmodule MmoContracts.ProtectionWireTest do
  @moduledoc """
  只测试：协议 19 PropertyBatch 末尾的受保护区域记录（R8-03 增量 2）。

  样本字节手写（与 Voxim `Voxim.R8.Protection.Wire` 同一串十六进制），不由编码器生成：
  删除 {5,2}；角色 42 的区域 {7,1} 矩形 (-3,16)..(15,31)；保留区域 {7,2} 矩形 (100,-200)..(163,-137)。
  """
  use ExUnit.Case, async: true
  alias MmoContracts.{Session, Voxel}

  # 每条 37 B：id_seq:u64 id_n:u32 holder:u8 cid:u64 min_x:i32 min_z:i32 max_x:i32 max_z:i32（大端）。
  @sample Base.decode16!(
            "0000000000000005" <> "00000002" <> "00" <> "0000000000000000" <>
              "00000000" <> "00000000" <> "00000000" <> "00000000" <>
              "0000000000000007" <> "00000001" <> "02" <> "000000000000002A" <>
              "FFFFFFFD" <> "00000010" <> "0000000F" <> "0000001F" <>
              "0000000000000007" <> "00000002" <> "01" <> "0000000000000000" <>
              "00000064" <> "FFFFFF38" <> "000000A3" <> "FFFFFF77"
          )

  @delta %{
    {5, 2} => nil,
    {7, 1} => %{holder: {:character, 42}, min: {-3, 16}, max: {15, 31}},
    {7, 2} => %{holder: :reserved, min: {100, -200}, max: {163, -137}}
  }

  defp batch(complete, protection) do
    %Voxel.PropertyBatch{
      identity: %Session.Identity{session_epoch: 1, scene_id: 2, scene_epoch: 3},
      transaction_seq: 7,
      l0_min: {0, 0, 0},
      l0_max_exclusive: {1, 1, 1},
      complete: complete,
      hp_enabled: 1,
      digest: :binary.copy(<<0xA5>>, 32),
      thermal_enabled: 1,
      ambient_kelvin: 293.15,
      epochs: <<>>,
      states: [],
      protection: protection
    }
  end

  test "Hello 21：旧 Hello 在线边界拒绝" do
    assert Session.Codec.protocol_version() == 27
    hello = %Session.Hello{protocol_version: 27, kernel_id: <<1::256>>, profile_id: <<2::256>>}
    {:ok, packet} = Session.Codec.encode(hello)
    <<prefix::binary-size(9), 27::16, tail::binary>> = packet
    assert {:error, :invalid_m1_message} = Session.Codec.decode(prefix <> <<20::16>> <> tail)
  end

  test "区域增量逐字节等于手写样本；存储字段（created_seq/created_by）不上线" do
    assert byte_size(@sample) == 3 * 37
    stored = Map.new(@delta, fn {id, r} -> {id, r && Map.merge(r, %{created_seq: 7, created_by: 42})} end)
    assert Voxel.Codec.encode_protection(stored) == @sample
    assert Voxel.Codec.decode_protection(@sample) == {:ok, @delta}
    assert Voxel.Codec.encode_protection(%{}) == <<>>
  end

  test "区域段附在属性批次末尾：增量可含删除，完整批次不能含删除" do
    {:ok, empty} = Voxel.Codec.encode_m1(batch(0, <<>>))
    {:ok, frame} = Voxel.Codec.encode_m1(batch(0, @sample))
    # 信封头 9 B（255, 版本 u16, 领域, kind, 长度 u32）；无区域时区域段是 0 长度，有区域时同一前缀后接 u32 长度与样本。
    # 协议 25 起区域段之后还有拟态段、协议 27 起再有施放段（这里都为空：0 长度）。
    <<head::binary-size(5), size0::32, rest0::binary>> = empty
    <<^head::binary-size(5), size1::32, rest1::binary>> = frame
    assert size1 == size0 + 111
    assert binary_part(rest0, byte_size(rest0) - 12, 12) == <<0::32, 0::32, 0::32>>
    assert rest1 == binary_part(rest0, 0, byte_size(rest0) - 12) <> <<111::32>> <> @sample <> <<0::32, 0::32>>
    assert {:ok, decoded} = Voxel.Codec.decode_m1(frame)
    assert decoded.protection == @sample

    complete = Voxel.Codec.encode_protection(Map.delete(@delta, {5, 2}))
    assert {:ok, %{protection: ^complete}} = Voxel.Codec.decode_m1(elem(Voxel.Codec.encode_m1(batch(1, complete)), 1))
    assert {:error, :invalid_m1_message} = Voxel.Codec.decode_m1(elem(Voxel.Codec.encode_m1(batch(1, @sample)), 1))
  end

  test "反例：乱序、重复、未知持有者、保留区带 cid、角色 cid 0、反向矩形、删除带矩形、截断都拒绝" do
    <<first::binary-size(37), second::binary-size(37), third::binary-size(37)>> = @sample
    <<head::binary-size(12), _holder, _cid::64, rect::binary-size(16)>> = second
    <<rhead::binary-size(12), _, _::64, _::binary-size(16)>> = third

    for bad <- [
          second <> first,
          second <> second,
          head <> <<3, 42::64>> <> rect,
          rhead <> <<1, 9::64>> <> binary_part(third, 21, 16),
          head <> <<2, 0::64>> <> rect,
          head <> <<2, 42::64, 15::signed-32, 16::signed-32, -3::signed-32, 31::signed-32>>,
          binary_part(first, 0, 21) <> <<1::32, 0::96>>,
          binary_part(@sample, 0, 110)
        ] do
      assert Voxel.Codec.decode_protection(bad) == {:error, :invalid_protection}
      assert {:error, :invalid_m1_message} = Voxel.Codec.decode_m1(elem(Voxel.Codec.encode_m1(batch(0, bad)), 1))
    end
  end
end
