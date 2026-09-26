defmodule MmoContracts.LiquidWireTest do
  use ExUnit.Case, async: true
  alias MmoContracts.{Session, Voxel}
  alias MmoContracts.Voxel.Payload

  # Test-only: mirrors the client quarter-macro fixture without a production parameter constant.
  defp water(quantity) do
    index = Payload.cell_index({64, 31, 4})
    cells = :binary.copy(<<0, 0>>, 66 * 66 * 66)
    <<head::binary-size(index * 2), _::16, tail::binary>> = cells

    {%Payload{
       region: {-1, 8, 0},
       cells: head <> <<21, 0>> <> tail,
       liquid_units: %{index => quantity}
     }, index}
  end

  test "B7 Hello16 and explicit scoop/pour retain the production envelope" do
    assert Session.Codec.protocol_version() == 30
    hello = %Session.Hello{protocol_version: 30, kernel_id: <<1::256>>, profile_id: <<2::256>>}
    {:ok, packet} = Session.Codec.encode(hello)
    assert {:ok, ^hello} = Session.Codec.decode(packet)
    <<prefix::binary-size(9), 30::16, tail::binary>> = packet
    for version <- [10,15,16,17,18,19,20,21,22] do
      assert {:error, :invalid_m1_message} = Session.Codec.decode(prefix <> <<version::16>> <> tail)
    end

    for action <- [2, 3] do
      wire =
        <<0x7F, 19::64, 7::32, 1::64, action, -1::signed-32, 542::signed-32, 3::signed-32, 11::16,
          21::16>>

      assert byte_size(wire) == 38

      assert {:ok,
              {:voxel_production_intent, %{action: ^action, coord: {-1, 542, 3}, material: 21}}} =
               Voxel.Codec.decode(wire)
    end

    assert {:error, :invalid_message} =
             Voxel.Codec.decode(<<0x7F, 19::64, 7::32, 1::64, 6, 0::96, 11::16, 21::16>>)
  end

  test "VXR9 quantity uses same region seq/hash and sorted little-endian suffix" do
    {payload, index} = water(128)
    packet = Payload.encode(payload, %{}, 47, 9)
    assert {:ok, %{version: 9, seq: 47, level: 0}, raw} = Voxel.Codec.decode_payload_body(packet)

    assert binary_part(raw, byte_size(raw) - 12, 12) ==
             <<1::little-32, index::little-32, 128::little-32>>

    assert {:ok, %{liquid_units: %{^index => 128}, region: {-1, 8, 0}, seq: 47}} =
             Payload.decode(packet)

    changed = Payload.encode(%{payload | liquid_units: %{index => 129}}, %{}, 47, 9)
    assert {:ok, a} = Voxel.Codec.decode_payload_header(packet)
    assert {:ok, b} = Voxel.Codec.decode_payload_header(changed)
    refute a.hash == b.hash
    if path = System.get_env("B7_GOLDEN_PATH"), do: File.write!(path, packet)
  end

  test "VXRA preserves partial Ice quantity and rejects Ice in legacy VXR9" do
    {p, index} = water(128)
    <<head::binary-size(index * 2), _::16, tail::binary>> = p.cells
    p = %{p | cells: head <> <<20, 0>> <> tail}
    packet = Payload.encode(p, %{}, 48, 9)
    assert {:ok, %{version: 10}, raw} = Voxel.Codec.decode_payload_body(packet)
    assert {:ok, %{liquid_units: %{^index => 128}, format_version: 10}} = Payload.decode(packet)

    assert {:error, :invalid_payload} =
             Payload.decode(Voxel.Codec.encode_payload(0, p.region, 48, 9, raw, 9))
  end

  test "VXRB承载Snow Basalt Lava有限量，旧版本不能重解释其后缀" do
    {p, index} = water(128)
    <<head::binary-size(index * 2), _::16, tail::binary>> = p.cells

    for material <- [4, 13, 22] do
      payload = %{p | cells: head <> <<material::little-16>> <> tail}
      packet = Payload.encode(payload, %{}, 49, 9)
      assert {:ok, %{version: 11}, raw} = Voxel.Codec.decode_payload_body(packet)
      assert {:ok, %{liquid_units: %{^index => 128}, format_version: 11}} = Payload.decode(packet)

      assert {:error, :invalid_payload} =
               Payload.decode(Voxel.Codec.encode_payload(0, p.region, 49, 9, raw, 10))
    end
  end

  # R8-07 冻结样本：region {-1,8,0} 的格 {64,31,4} 为沙 5、有限量 524288（0.25 m³），seq 50、cv 9。
  # 头部前 50 字节（magic "VXRC"、版本 12、层级、区域、seq、cv、未压缩体 hash、编码、未压缩体长度）逐字节冻结；
  # hash 覆盖整个未压缩体（含尾部数量记录），客户端解码器以同一份字节验证。压缩体长度随 zlib 实现变化，不冻结。
  @vxrc_header <<"VXRC", 12::little-32, 0, -1::little-signed-32, 8::little-signed-32, 0::little-signed-32,
                 50::little-64, 9::little-64, 144, 89, 70, 216, 225, 81, 211, 183, 1, 575_056::little-32>>

  test "VXRC承载任意非空气宏格的散体有限量，旧版本不能重解释，空气仍拒绝" do
    {p, index} = water(128)
    <<head::binary-size(index * 2), _::16, tail::binary>> = p.cells
    sand = %{p | cells: head <> <<5::little-16>> <> tail, liquid_units: %{index => 524_288}}
    packet = Payload.encode(sand, %{}, 50, 9)
    assert binary_part(packet, 0, 50) == @vxrc_header
    assert {:ok, %{version: 12}, raw} = Voxel.Codec.decode_payload_body(packet)
    assert binary_part(raw, byte_size(raw) - 12, 12) ==
             <<1::little-32, index::little-32, 524_288::little-32>>

    assert {:ok, %{liquid_units: %{^index => 524_288}, format_version: 12}} = Payload.decode(packet)

    for version <- [9, 10, 11] do
      assert {:error, :invalid_payload} =
               Payload.decode(Voxel.Codec.encode_payload(0, p.region, 50, 9, raw, version))
    end

    # 液体与相态材料的有限量仍按原版本编码，不因本版本升级。
    assert {:ok, %{version: 9}, _} = Voxel.Codec.decode_payload_body(Payload.encode(p, %{}, 50, 9))

    air = %{p | cells: head <> <<0::little-16>> <> tail, liquid_units: %{index => 524_288}}
    # 细化宏格的地形格恒为空气（既有校验），所以同一条“非空气”规则也拒绝细化宏格上的数量。
    assert {:error, :invalid_payload} = Payload.decode(Payload.encode(air, %{}, 50, 9))
    if path = System.get_env("R8_07_GOLDEN_PATH"), do: File.write!(path, packet)
  end

  test "legacy water retains implicit full occupancy and quantity records reject impossible shapes" do
    {payload, index} = water(128)

    assert {:ok, %{format_version: 4, liquid_units: %{}}} =
             Payload.decode(Payload.encode(%{payload | liquid_units: %{}}, %{}, 47, 9))

    for invalid <- [%{index => 0}, %{(index + 1) => 128}] do
      assert {:error, :invalid_payload} =
               Payload.decode(Payload.encode(%{payload | liquid_units: invalid}, %{}, 47, 9))
    end

    packet = Payload.encode(%{payload | level: 1}, %{}, 47, 9)
    assert {:error, :invalid_payload} = Payload.decode(packet)
  end

  test "Hello16 codec still carries B6 combustion after thermal state" do
    row = %{
      request_id: 0,
      seq: 7,
      micro: {336, 4112, 504},
      granularity: 0,
      incarnation: 2,
      owner: {0, 0},
      material: 19,
      hp: 90.0,
      max_hp: 100.0,
      defense: 0.0,
      digest: <<0::256>>,
      flags: 0,
      temperature_kelvin: 307.0,
      burning: false,
      remaining_fuel_j: 11000.0,
      power_w: 0.0
    }

    assert {:ok, packet} = Voxel.Codec.encode({:voxel_property_state, row})
    bytes = IO.iodata_to_binary(packet)
    assert byte_size(bytes) == 146
    assert binary_part(bytes, 129, 17) == <<0, 11000.0::float-64, 0.0::float-64>>
  end
end
