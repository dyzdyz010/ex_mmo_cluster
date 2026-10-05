defmodule MmoContracts.OperationWireTest do
  @moduledoc "Test-only: frozen hand-written P2 bytes, independent of the encoder."
  use ExUnit.Case, async: true
  alias MmoContracts.Voxel.Codec
  @base Base.decode16!("08070605040302010000000000000000")
  @operation Base.decode16!("038877665544332211D4C3B2A1001400F7FFFFFFFFFFFFFF5300000000000000EFFFFFFFFFFFFFFF")
  @falls Base.decode16!("02150001000000FFFFFFFF020000000300000001000000")
  @value %{character: 0x1122334455667788, client_seq: 0xA1B2C3D4, kind: 0, material: 20, micro: {-9,83,-17}}

  test "frozen operation and existing falls coexist in either order" do
    txn = %{seq: 0x0102030405060708, entries: [], coarse: [], operation: @value}
    assert IO.iodata_to_binary(Codec.encode_transaction(txn)) == @base <> @operation
    assert {:ok, ^txn} = Codec.decode_transaction(@base <> @operation)
    both = Map.put(txn, :liquid_falls, %{material: 21, transfers: [{{-1,2,3},1}]})
    assert IO.iodata_to_binary(Codec.encode_transaction(both)) == @base <> @falls <> @operation
    assert {:ok, ^both} = Codec.decode_transaction(@base <> @falls <> @operation)
    assert {:ok, ^both} = Codec.decode_transaction(@base <> @operation <> @falls)
    assert {:ok, %{seq: 0x0102030405060708, entries: [], coarse: []}} = Codec.decode_transaction(@base)
  end

  test "truncation unknown duplicate and invalid kind metadata fail explicitly" do
    for size <- 1..(byte_size(@operation)-1) do
      assert {:error, :invalid_transaction} = Codec.decode_transaction(@base <> binary_part(@operation,0,size))
    end
    for tail <- [<<4>>, @operation <> @operation, @falls <> @falls, @operation <> <<4>>] do
      assert {:error, :invalid_transaction} = Codec.decode_transaction(@base <> tail)
    end
    <<prefix::binary-size(13), _kind, rest::binary>> = @operation
    assert {:error, :invalid_transaction} = Codec.decode_transaction(@base <> prefix <> <<3>> <> rest)
  end
end
