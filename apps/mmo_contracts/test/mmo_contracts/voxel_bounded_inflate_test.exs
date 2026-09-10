defmodule MmoContracts.VoxelBoundedInflateTest do
  use ExUnit.Case, async: false
  alias MmoContracts.Voxel.Codec

  test "underdeclared expansion stops at the declared output limit and closes the stream" do
    raw_bytes = 592_506
    expansion = 16 * 1024 * 1024
    compressed = :zlib.compress(:binary.copy(<<0>>, expansion))
    packet = payload(compressed, raw_bytes, 0)
    {result, trace} = traced_decode(packet)
    assert result == {:error, :invalid_payload}
    sizes = output_sizes(trace)
    emitted = Enum.sum(sizes)

    IO.inspect(
      %{
        declared: raw_bytes,
        expansion: expansion,
        emitted: emitted,
        calls: length(sizes),
        largest_chunk: Enum.max(sizes)
      },
      label: "allocation_boundary"
    )

    # OTP 的单次输出块是 16 KiB；旧 uncompress 会在拒绝前产出全部 16 MiB。
    assert emitted <= raw_bytes + 16_384
    assert emitted > raw_bytes
    assert Enum.sum(Enum.drop(sizes, -1)) <= raw_bytes
    assert Enum.count(trace, &match?({:close, :ok}, &1)) == 1
  end

  test "CanonicalBootstrap retains its legal header but aborts the larger real expansion" do
    fixture =
      Path.expand(
        "../../../../../Voxim/Docs/M1/fixtures/movement-wire/elixir_canonical_bootstrap.bin",
        __DIR__
      )

    assert {:ok, bootstrap} = Codec.decode_m1(File.read!(fixture))
    [{coord, first} | rest] = bootstrap.regions
    assert {:ok, header} = Codec.decode_payload_header(first)
    assert header.raw_bytes == 592_506
    compressed = :zlib.compress(:binary.copy(<<0>>, 16 * 1024 * 1024))
    <<prefix::binary-size(50), _::binary>> = first
    malformed = <<prefix::binary, byte_size(compressed)::32-little, compressed::binary>>
    assert {:ok, packet} = Codec.encode_m1(%{bootstrap | regions: [{coord, malformed} | rest]})
    {result, trace} = traced_decode(packet, &Codec.decode_m1/1)
    assert result == {:error, :invalid_m1_message}
    emitted = Enum.sum(output_sizes(trace))
    IO.inspect(%{declared: header.raw_bytes, emitted: emitted}, label: "bootstrap_boundary")
    assert emitted > header.raw_bytes and emitted <= header.raw_bytes + 16_384
    assert Enum.count(trace, &match?({:close, :ok}, &1)) == 1
  end

  test "complete streams preserve exact bytes on both sides of the output chunk boundary" do
    for size <- [0, 16_383, 16_384, 16_385, 592_506] do
      raw = :binary.copy(<<42>>, size)
      packet = Codec.encode_payload(0, {0, 0, 0}, 1, 1, raw)
      {result, trace} = traced_decode(packet)
      assert {:ok, %{raw_bytes: ^size}, ^raw} = result
      assert Enum.sum(output_sizes(trace)) == size
      assert Enum.count(trace, &match?({:inflateEnd, :ok}, &1)) == 1
      assert Enum.count(trace, &match?({:close, :ok}, &1)) == 1
    end
  end

  test "matching output without the zlib trailer is incomplete and closes the stream" do
    raw = :binary.copy(<<42>>, 16_385)
    compressed = :zlib.compress(raw)
    truncated = binary_part(compressed, 0, byte_size(compressed) - 4)
    {result, trace} = traced_decode(payload(truncated, byte_size(raw), Codec.body_hash(raw)))
    assert result == {:error, :invalid_payload}
    assert Enum.sum(output_sizes(trace)) == byte_size(raw)
    assert Enum.count(trace, &match?({:close, :ok}, &1)) == 1
  end

  test "short output and corrupt compressed input reject and close on every exit" do
    raw = :binary.copy(<<42>>, 16_385)
    compressed = :zlib.compress(raw)
    prefix = binary_part(compressed, 0, byte_size(compressed) - 1)
    last = :binary.last(compressed)
    corrupt = <<prefix::binary, Bitwise.bxor(last, 1)>>

    for {body, declared} <- [
          {compressed, byte_size(raw) + 1},
          {corrupt, byte_size(raw)},
          {<<0, 0>>, 1}
        ] do
      {result, trace} = traced_decode(payload(body, declared, Codec.body_hash(raw)))
      assert result == {:error, :invalid_payload}
      assert Enum.count(trace, &match?({:close, :ok}, &1)) == 1
    end
  end

  test "preset dictionary requests reject and close without a dictionary fallback" do
    z = :zlib.open()

    compressed =
      try do
        :ok = :zlib.deflateInit(z)
        :zlib.deflateSetDictionary(z, "dictionary")
        data = :zlib.deflate(z, "dictionary", :finish)
        :ok = :zlib.deflateEnd(z)
        IO.iodata_to_binary(data)
      after
        :zlib.close(z)
      end

    {result, trace} = traced_decode(payload(compressed, 10, Codec.body_hash("dictionary")))
    assert result == {:error, :invalid_payload}
    assert Enum.any?(trace, &match?({:safeInflate, {:need_dictionary, _, _}}, &1))
    assert Enum.count(trace, &match?({:close, :ok}, &1)) == 1
  end

  defp payload(body, raw_bytes, hash) do
    <<"VXR4", 4::32-little, 0, 0::96, 1::64-little, 1::64-little, hash::64-little, 1,
      raw_bytes::32-little, byte_size(body)::32-little, body::binary>>
  end

  defp traced_decode(packet, decode \\ &Codec.decode_payload_body/1) do
    parent = self()
    functions = [{:inflate, 2}, {:safeInflate, 2}, {:inflateEnd, 1}, {:close, 1}]

    Enum.each(functions, fn {name, arity} ->
      :erlang.trace_pattern({:zlib, name, arity}, [{:_, [], [{:return_trace}]}], [:local])
    end)

    pid =
      spawn_link(fn ->
        receive do
          :decode -> send(parent, {:result, self(), decode.(packet)})
        end

        receive do
          :stop -> :ok
        end
      end)

    try do
      :erlang.trace(pid, true, [:call, {:tracer, parent}])
      send(pid, :decode)

      result =
        receive do
          {:result, ^pid, result} -> result
        after
          10_000 -> flunk("decoder did not finish")
        end

      ref = :erlang.trace_delivered(pid)
      {result, collect_trace(pid, ref, [])}
    after
      send(pid, :stop)

      Enum.each(functions, fn {name, arity} ->
        :erlang.trace_pattern({:zlib, name, arity}, false, [:local])
      end)
    end
  end

  defp collect_trace(pid, ref, acc) do
    receive do
      {:trace, ^pid, :return_from, {:zlib, name, _}, result} ->
        collect_trace(pid, ref, [{name, result} | acc])

      {:trace, ^pid, :call, _} ->
        collect_trace(pid, ref, acc)

      {:trace_delivered, ^pid, ^ref} ->
        Enum.reverse(acc)
    after
      10_000 -> flunk("trace delivery did not finish")
    end
  end

  defp output_sizes(trace) do
    Enum.flat_map(trace, fn
      {:inflate, output} ->
        [IO.iodata_length(output)]

      {:safeInflate, {status, output}} when status in [:continue, :finished] ->
        [IO.iodata_length(output)]

      _ ->
        []
    end)
  end
end
