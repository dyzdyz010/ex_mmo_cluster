defmodule SceneServer.Voxel.Hash do
  @moduledoc """
  Stable S0 voxel digest helpers.

  TODO: replace this fallback with the protocol-required `xxHash64` seed `0`
  once an approved dependency or native implementation is introduced. Until
  then, S0 uses the first 64 bits of SHA-256 as a deterministic standard-library
  fallback for consistency checks and round-trip tests.
  """

  import Bitwise, only: [band: 2]

  @max_u64 0xFFFF_FFFF_FFFF_FFFF

  @doc "Returns a stable unsigned 64-bit digest for canonical iodata."
  @spec digest64(iodata()) :: 0..0xFFFF_FFFF_FFFF_FFFF
  def digest64(iodata) do
    <<value::unsigned-big-integer-size(64), _rest::binary>> =
      :crypto.hash(:sha256, IO.iodata_to_binary(iodata))

    value
  end

  @doc "Returns the low 32 bits of `digest64/1` for macro-cell hash fields."
  @spec digest32(iodata()) :: 0..0xFFFF_FFFF
  def digest32(iodata) do
    iodata
    |> digest64()
    |> band(0xFFFF_FFFF)
  end

  @doc "Encodes an unsigned 64-bit digest as big-endian bytes."
  @spec encode64(non_neg_integer()) :: <<_::64>>
  def encode64(value) when is_integer(value) and value >= 0 and value <= @max_u64 do
    <<value::unsigned-big-integer-size(64)>>
  end

  @doc "Decodes exactly eight big-endian bytes into an unsigned 64-bit integer."
  @spec decode64(<<_::64>>) :: 0..0xFFFF_FFFF_FFFF_FFFF
  def decode64(<<value::unsigned-big-integer-size(64)>>), do: value
end
