defmodule MmoContracts.SourceWireTest do
  use ExUnit.Case, async: true
  alias MmoContracts.{Session, Voxel}

  # 只测试：协议 22（R8-04 增量 3）电源后缀。样本逐字段手写，与 Voxim `Voxim.R8.Source.Wire` 同一份字节：
  # 一块蓄能石宏格（材料 42，微格原点 (8, 16, −24)），300 K，储能 2.5 MJ、电动势 24 V、电流 −12.5 A（充电）。
  @digest :binary.copy(<<0x11>>, 32)
  @head <<0x7E, 0::64, 42::64, 8::signed-64, 16::signed-64, -24::signed-64, 0, 0::64, 0::64, 0::32,
          42::16, 100.0::float-64, 100.0::float-64, 8.0::float-64>> <> @digest
  # flags：位 0 删除，位 1 发光后缀，位 2 开关闭合，位 3 = 电源后缀（24 字节，在最后）。
  @sample @head <> <<8, 300.0::float-64, 2_500_000.0::float-64, 24.0::float-64, -12.5::float-64>>

  defp row do
    %{request_id: 0, seq: 42, micro: {8, 16, -24}, granularity: 0, incarnation: 0, owner: {0, 0},
      material: 42, hp: 100.0, max_hp: 100.0, defense: 8.0, digest: @digest, flags: 0, temperature_kelvin: 300.0}
  end

  defp bytes(row) do
    {:ok, packet} = Voxel.Codec.encode({:voxel_property_state, row})
    IO.iodata_to_binary(packet)
  end

  test "蓄能石行：温度之后追加 24 字节（J、V、带号 A），flags 位 3，逐字节等于手写样本" do
    assert byte_size(@sample) == 153
    assert bytes(Map.merge(row(), %{stored_j: 2_500_000.0, source_emf_v: 24.0, source_current_a: -12.5})) == @sample
    assert binary_part(@sample, 120, 1) == <<8>>
    assert Base.encode16(@sample, case: :lower) ==
             "7e000000000000000000000000000000" <> "2a" <> "0000000000000008" <> "0000000000000010" <>
               "ffffffffffffffe8" <> "00" <> "0000000000000000" <> "0000000000000000" <> "00000000" <> "002a" <>
               "4059000000000000" <> "4059000000000000" <> "4020000000000000" <> String.duplicate("11", 32) <>
               "08" <> "4072c00000000000" <> "414312d000000000" <> "4038000000000000" <> "c029000000000000"

    # 只有储能（本段不在网络里）：电动势与电流写 0；只有观察（热电石）：储能写 0。
    assert binary_part(bytes(Map.put(row(), :stored_j, 7.0)), 129, 24) ==
             <<7.0::float-64, 0.0::float-64, 0.0::float-64>>
    te = %{row() | material: 43} |> Map.merge(%{source_emf_v: 41.0, source_current_a: 19.5})
    assert binary_part(bytes(te), 129, 24) == <<0.0::float-64, 41.0::float-64, 19.5::float-64>>
    # 没有这些字段：与协议 21 的温度记录相同。
    assert byte_size(bytes(row())) == 129
  end

  test "发光与电源后缀同时存在（微格行）：发光 16 字节在前、电源 24 字节在最后；删除位互不干扰" do
    micro = %{row() | granularity: 1, micro: {9, 17, -23}}
    both = bytes(Map.merge(micro, %{electric_w: 5.0, current_a: 2.0, stored_j: 1.0, source_emf_v: 3.0, source_current_a: 2.0}))
    assert binary_part(both, 120, 1) == <<10>>
    assert binary_part(both, 129, 40) ==
             <<5.0::float-64, 2.0::float-64, 1.0::float-64, 3.0::float-64, 2.0::float-64>>
    removed = bytes(Map.merge(row(), %{flags: 1, stored_j: 0.0}))
    assert binary_part(removed, 120, 1) == <<9>>
  end

  test "设备记录已退出协议：带旧 circuit 字段的行不再编码设备段" do
    legacy = Map.put(row(), :circuit, %{tool_id: 3, kind: 1, size: 8, closed: true, fault: 0, anchor: {0, 0, 0},
      remaining_j: 1.0, voltage_v: 0.0, current_a: 0.0, power_w: 0.0})
    assert bytes(legacy) == bytes(row())
  end

  test "Hello 23：Hello 21/22 在线边界拒绝" do
    assert Session.Codec.protocol_version() == 28
    hello = %Session.Hello{protocol_version: 28, kernel_id: <<1::256>>, profile_id: <<2::256>>}
    {:ok, packet} = Session.Codec.encode(hello)
    <<prefix::binary-size(9), 28::16, tail::binary>> = packet
    for old <- [21, 22], do: assert({:error, :invalid_m1_message} = Session.Codec.decode(prefix <> <<old::16>> <> tail))
  end
end
