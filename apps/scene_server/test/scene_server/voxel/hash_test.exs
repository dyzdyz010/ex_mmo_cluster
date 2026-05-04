defmodule SceneServer.Voxel.HashTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Hash

  describe "xxHash64 conformance vectors (seed=0)" do
    test "matches the empty-input vector" do
      # XXH64("", seed=0) per the official xxHash specification.
      assert Hash.digest64(<<>>) == 0xEF46DB3751D8E999
    end

    test "matches the single-byte 'a' vector" do
      # XXH64("a", seed=0) per the xxHash 0.8 reference test corpus.
      assert Hash.digest64("a") == 0xD24EC4F1A98C6E5B
    end

    test "matches the 39-byte 'Nobody inspects ...' vector" do
      # XXH64("Nobody inspects the spammish repetition", seed=0) — exceeds the
      # 32-byte stripe threshold, so this exercises the wide-input merge_round
      # path that the empty/single-byte vectors cannot.
      input = "Nobody inspects the spammish repetition"
      assert Hash.digest64(input) == 0xFBCEA83C8A378BF1
    end

    test "is deterministic for iodata equivalent to its concatenation" do
      assert Hash.digest64(["hello", " ", "world"]) == Hash.digest64("hello world")
    end

    test "non-zero seed support exposes the algorithm for vector pinning" do
      # Same input, different seed must produce a different digest.
      base = Hash.xxhash64("Nobody inspects the spammish repetition", 0)
      assert Hash.xxhash64("Nobody inspects the spammish repetition", 1) != base
    end
  end

  describe "digest32" do
    test "is the low 32 bits of digest64" do
      input = "voxel S0 cell digest"
      assert Hash.digest32(input) == Bitwise.band(Hash.digest64(input), 0xFFFF_FFFF)
    end
  end

  describe "encode64 / decode64" do
    test "round-trip a 64-bit digest as eight big-endian bytes" do
      value = Hash.digest64("voxel chunk truth payload sample")
      assert Hash.decode64(Hash.encode64(value)) == value
      assert byte_size(Hash.encode64(value)) == 8
    end
  end
end
