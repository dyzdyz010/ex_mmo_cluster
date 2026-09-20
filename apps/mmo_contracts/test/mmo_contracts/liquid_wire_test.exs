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

  test "B7 Hello15 and explicit scoop/pour retain the production envelope" do
    assert Session.Codec.protocol_version() == 15
    hello = %Session.Hello{protocol_version: 15, kernel_id: <<1::256>>, profile_id: <<2::256>>}
    {:ok, packet} = Session.Codec.encode(hello)
    assert {:ok, ^hello} = Session.Codec.decode(packet)
    <<prefix::binary-size(9), 15::16, tail::binary>> = packet
    assert {:error, :invalid_m1_message} = Session.Codec.decode(prefix <> <<10::16>> <> tail)

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
             Voxel.Codec.decode(<<0x7F, 19::64, 7::32, 1::64, 4, 0::96, 11::16, 21::16>>)
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

  test "Hello15 codec still carries B6 combustion after thermal state" do
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
