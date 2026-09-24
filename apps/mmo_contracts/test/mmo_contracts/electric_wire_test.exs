defmodule MmoContracts.ElectricWireTest do
  use ExUnit.Case, async: true
  alias MmoContracts.Voxel

  # 只测试：协议 20 发光导体后缀（电功率 W、穿过电流 A）。样本逐字段手写，与 Voxim `Voxim.R8.Electric.Wire` 同一份字节：
  # 一个 1/8 m 电阻合金（40）灯丝格，302 K，128 W，8 A。
  @digest :binary.copy(<<0xA5>>, 32)
  @head <<0x7E, 0::64, 9::64, 536::signed-64, 3336::signed-64, -4112::signed-64, 1, 5::64, 7::64, 0::32,
          40::16, 0.1953125::float-64, 0.1953125::float-64, 8.0::float-64>> <> @digest
  # flags：位 0 删除，位 1 = 带发光后缀。
  @sample @head <> <<2, 302.0::float-64, 128.0::float-64, 8.0::float-64>>
  @dark @head <> <<0, 302.0::float-64>>

  defp row do
    %{request_id: 0, seq: 9, micro: {536, 3336, -4112}, granularity: 1, incarnation: 5, owner: {7, 0},
      material: 40, hp: 0.1953125, max_hp: 0.1953125, defense: 8.0, digest: @digest, flags: 0,
      temperature_kelvin: 302.0}
  end

  defp bytes(row) do
    {:ok, packet} = Voxel.Codec.encode({:voxel_property_state, row})
    IO.iodata_to_binary(packet)
  end

  test "发光格记录 = 温度之后追加 16 字节（W、A），逐字节等于手写样本" do
    assert byte_size(@sample) == 145
    assert bytes(Map.merge(row(), %{electric_w: 128.0, current_a: 8.0})) == @sample
    # 不发光（没有这两个字段）时 flags 位 1 为 0、没有后缀，与协议 19 的温度记录相同。
    assert bytes(row()) == @dark
    assert byte_size(@dark) == 129
    assert Base.encode16(@sample, case: :lower) ==
             "7e0000000000000000000000000000000900000000000002180000000000000d08ffffffffffffeff0" <>
               "01000000000000000500000000000000070000000000283fc90000000000003fc90000000000004020000000000000" <>
               String.duplicate("a5", 32) <> "024072e000000000004060000000000000" <> "4020000000000000"
  end

  test "燃烧与发光同时存在时，燃烧 17 字节在前、发光 16 字节在最后" do
    burning = Map.merge(row(), %{burning: true, remaining_fuel_j: 10.0, power_w: 5.0, electric_w: 128.0, current_a: 8.0})
    assert bytes(burning) ==
             binary_part(@sample, 0, 129) <> <<1, 10.0::float-64, 5.0::float-64>> <> <<128.0::float-64, 8.0::float-64>>
    # 删除记录（flags 位 0）与发光位互不干扰。
    removed = bytes(Map.merge(row(), %{flags: 1, electric_w: 0.0, current_a: 0.0}))
    assert binary_part(removed, 120, 1) == <<3>>
  end
end
