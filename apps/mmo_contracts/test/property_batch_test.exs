defmodule MmoContracts.PropertyBatchTest do
  use ExUnit.Case, async: true
  alias MmoContracts.Voxel.Codec

  # 只测试：与 UE 解码器共用新增属性批次黄金帧，不改变任何已冻结旧帧。
  test "完整批次跨语言黄金帧与截断拒绝" do
    path = Path.expand("../../../../Voxim/Docs/R7/fixtures/property-batch.bin", __DIR__)
    bytes = File.read!(path)
    assert {:ok, batch} = Codec.decode_m1(bytes)
    assert batch.transaction_seq == 10
    assert batch.complete == 1 and batch.hp_enabled == 1
    assert batch.epochs == <<1::32, 1::32, 1::32, 4::64>>
    assert [<<0x7E, _::binary>>] = batch.states
    assert {:ok, ^bytes} = Codec.encode_m1(batch)

    for size <- 0..(byte_size(bytes) - 1) do
      assert {:error, :invalid_m1_message} = Codec.decode_m1(binary_part(bytes, 0, size))
    end
  end
end
