defmodule SceneServer.Voxel.Hash do
  @moduledoc """
  Stable S0 voxel digest helpers.

  `digest64/1` is xxHash64 with seed `0` — the protocol-required hash for
  `chunk_hash`, `cell_hash`, `source_hash`, etc. Implemented in pure Elixir so
  it stays available in tests and in non-NIF runtimes; the algorithm reads
  input little-endian per the xxHash specification.

  `digest32/1` returns the low 32 bits of `digest64/1` for fields the protocol
  caps to `u32` (`cell_hash`, `cover_hash`, …).
  """

  import Bitwise

  @prime1 0x9E3779B185EBCA87
  @prime2 0xC2B2AE3D27D4EB4F
  @prime3 0x165667B19E3779F9
  @prime4 0x85EBCA77C2B2AE63
  @prime5 0x27D4EB2F165667C5

  @u64_mask 0xFFFF_FFFF_FFFF_FFFF
  @u32_mask 0xFFFF_FFFF

  @doc "Returns a stable unsigned 64-bit xxHash64(seed=0) digest for canonical iodata."
  @spec digest64(iodata()) :: 0..0xFFFF_FFFF_FFFF_FFFF
  def digest64(iodata) do
    iodata
    |> IO.iodata_to_binary()
    |> xxhash64(0)
  end

  @doc "Returns the low 32 bits of `digest64/1` for fields the protocol caps to `u32`."
  @spec digest32(iodata()) :: 0..0xFFFF_FFFF
  def digest32(iodata) do
    iodata
    |> digest64()
    |> band(@u32_mask)
  end

  @doc "Encodes an unsigned 64-bit digest as big-endian bytes."
  @spec encode64(non_neg_integer()) :: <<_::64>>
  def encode64(value) when is_integer(value) and value >= 0 and value <= @u64_mask do
    <<value::unsigned-big-integer-size(64)>>
  end

  @doc "Decodes exactly eight big-endian bytes into an unsigned 64-bit integer."
  @spec decode64(<<_::64>>) :: 0..0xFFFF_FFFF_FFFF_FFFF
  def decode64(<<value::unsigned-big-integer-size(64)>>), do: value

  @doc """
  Computes `xxHash64(input, seed)` against a binary.

  Exposed mainly for tests that want to pin known vectors with non-zero seeds;
  `digest64/1` is the production entry point and uses seed `0`.
  """
  @spec xxhash64(binary(), non_neg_integer()) :: 0..0xFFFF_FFFF_FFFF_FFFF
  def xxhash64(input, seed) when is_binary(input) and is_integer(seed) and seed >= 0 do
    len = byte_size(input)

    {h64, tail} =
      if len >= 32 do
        v1 = seed + @prime1 + @prime2 &&& @u64_mask
        v2 = seed + @prime2 &&& @u64_mask
        v3 = seed
        v4 = seed - @prime1 &&& @u64_mask

        {v1, v2, v3, v4, rest} = consume_stripes(input, v1, v2, v3, v4)

        h =
          rotl64(v1, 1) + rotl64(v2, 7) + rotl64(v3, 12) + rotl64(v4, 18) &&& @u64_mask

        h =
          h
          |> merge_round(v1)
          |> merge_round(v2)
          |> merge_round(v3)
          |> merge_round(v4)

        {h, rest}
      else
        {seed + @prime5 &&& @u64_mask, input}
      end

    h64
    |> Kernel.+(len)
    |> band(@u64_mask)
    |> consume_tail(tail)
    |> avalanche()
  end

  defp consume_stripes(
         <<a::little-64, b::little-64, c::little-64, d::little-64, rest::binary>>,
         v1,
         v2,
         v3,
         v4
       ) do
    consume_stripes(rest, round64(v1, a), round64(v2, b), round64(v3, c), round64(v4, d))
  end

  defp consume_stripes(rest, v1, v2, v3, v4), do: {v1, v2, v3, v4, rest}

  defp consume_tail(h, <<k1::little-64, rest::binary>>) do
    h
    |> bxor(round64(0, k1))
    |> rotl64(27)
    |> Kernel.*(@prime1)
    |> band(@u64_mask)
    |> Kernel.+(@prime4)
    |> band(@u64_mask)
    |> consume_tail(rest)
  end

  defp consume_tail(h, <<k1::little-32, rest::binary>>) do
    h
    |> bxor(k1 * @prime1 &&& @u64_mask)
    |> rotl64(23)
    |> Kernel.*(@prime2)
    |> band(@u64_mask)
    |> Kernel.+(@prime3)
    |> band(@u64_mask)
    |> consume_tail(rest)
  end

  defp consume_tail(h, <<k1::8, rest::binary>>) do
    h
    |> bxor(k1 * @prime5 &&& @u64_mask)
    |> rotl64(11)
    |> Kernel.*(@prime1)
    |> band(@u64_mask)
    |> consume_tail(rest)
  end

  defp consume_tail(h, <<>>), do: h

  defp round64(acc, val) do
    acc = acc + val * @prime2 &&& @u64_mask
    acc = rotl64(acc, 31)
    acc * @prime1 &&& @u64_mask
  end

  defp merge_round(h, val) do
    h
    |> bxor(round64(0, val))
    |> Kernel.*(@prime1)
    |> band(@u64_mask)
    |> Kernel.+(@prime4)
    |> band(@u64_mask)
  end

  defp avalanche(h) do
    h = bxor(h, h >>> 33)
    h = h * @prime2 &&& @u64_mask
    h = bxor(h, h >>> 29)
    h = h * @prime3 &&& @u64_mask
    bxor(h, h >>> 32)
  end

  defp rotl64(value, n) when n in 1..63 do
    masked = value &&& @u64_mask
    (masked <<< n ||| masked >>> (64 - n)) &&& @u64_mask
  end
end
