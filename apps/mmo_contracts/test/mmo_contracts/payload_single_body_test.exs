defmodule MmoContracts.PayloadSingleBodyTest do
  @moduledoc "只测试：refined片段到最终载荷只在Codec边界物化；手算原始段与完整压缩字节作独立期望。"
  use ExUnit.Case, async: false
  alias MmoContracts.Voxel.{Codec, Payload, Refined}

  @cells 66 * 66 * 66

  test "完整载荷不先物化refined后缀，最终字节保持手算VXR5" do
    {payload, terrain, tail, _instance_bytes} = sample()
    expected = packet(terrain <> tail, 5)
    {actual, calls} = count_refined_binary(fn -> Payload.encode(payload, %{}, 17, 23) end)
    assert actual == expected
    assert calls == 0
  end

  test "VXRD包裹空或非空base尾段的长度与字节，且复用和有上限入口一致" do
    {base, terrain, refined_tail, instance_bytes} = sample()
    instance = Map.fetch!(base.instances, {7, 0})
    # 原Canopy冻结小例的同一字段顺序：版本、空refined、一个VXR7实例、一个锚点、空残余和空结构。
    canopy = <<1::32-little, 0::32, 1::32-little, instance_bytes::binary,
      0::64, 0::32, 0::32, 1::32-little, -1::signed-little-64,
      -1::signed-little-64, -1::signed-little-64, 7::64-little,
      0::32, 58::16-little, 2::16-little, 0::32, 2::32-little, 0::32>>
    plain = %Payload{cells: base.cells}
    prior = packet(terrain, 4)

    for {payload, tail, version} <- [{plain, <<>>, 4}, {base, refined_tail, 5}] do
      payload = %{payload | canopy: %{{-1, -1, -1} => {58, {7, 0}, 2}},
        canopy_instances: %{{7, 0} => instance}}
      raw = terrain <> <<version::32-little, byte_size(tail)::32-little>> <> tail <> canopy
      expected = packet(raw, 13)
      assert Payload.encode(payload, %{}, 17, 23) == expected
      assert Payload.replace_details(prior, payload, 17, 23) == expected
      assert Payload.encode_below(payload, %{}, 17, 23, byte_size(expected) + 1) == {:ok, expected}
    end
  end

  test "Codec接纳嵌套iodata保持同一字节并按原格式容量拒绝" do
    {_, terrain, tail, _} = sample()
    assert Codec.encode_payload(0, {0, 0, 0}, 17, 23, [terrain, [tail]], 5) == packet(terrain <> tail, 5)
    block = :binary.copy(<<0>>, 4096)
    oversize = List.duplicate(block, div(Payload.max_body_bytes(4), 4096) + 1)
    assert_raise ArgumentError, ~r/exceeds format capacity/, fn ->
      Codec.encode_payload(0, {0, 0, 0}, 17, 23, oversize, 4)
    end
  end

  defp sample do
    cells = :binary.copy(<<11, 0>>, @cells)
    terrain = <<@cells::32-little, cells::binary, 0::96, 1::32-little, 0::160>>
    id = :binary.copy(<<9>>, 32)
    instance = %{definition_id: id, anchor: {-8, -8, -8}, orientation: 0}
    instance_bytes = <<7::64-little, 0::32, id::binary,
      -8::signed-little-64, -8::signed-little-64, -8::signed-little-64, 0>>
    record = <<0::16-little, 11::16-little, 7::64-little, 0::32>>
    tail = <<1::32-little, 1::32-little, 1::32-little, record::binary,
      1::32-little, instance_bytes::binary>>
    projected = Refined.Encoding.new(%{1 => {1, record}})
    {%Payload{cells: cells, refined_encoding: projected, instances: %{{7, 0} => instance}},
      terrain, tail, instance_bytes}
  end

  defp packet(raw, version) do
    magic = if version == 13, do: "VXRD", else: "VXR#{version}"
    body = :zlib.compress(raw)
    <<hash::64-little, _::binary>> = :crypto.hash(:md5, raw)
    <<magic::binary, version::32-little, 0, 0::96, 17::64-little, 23::64-little,
      hash::64-little, 1, byte_size(raw)::32-little, byte_size(body)::32-little, body::binary>>
  end

  defp count_refined_binary(action) do
    mfa = {Refined, :encode, 3}
    assert {:module, Refined} = Code.ensure_loaded(Refined)
    parent = self()
    {worker, monitor} = spawn_monitor(fn ->
      receive do
        :run ->
          send(parent, {:result, self(), action.()})
          receive do: (:stop -> :ok)
      end
    end)
    sessions = :trace.session_info(:all)
    session = :trace.session_create(:payload_single_body, self(), [])
    try do
      assert :trace.function(session, mfa, true, [:local]) == 1
      assert :trace.process(session, worker, true, [:call, :arity]) == 1
      send(worker, :run)
      result = receive do
        {:result, ^worker, result} -> result
      after
        5_000 -> flunk("载荷编码没有完成")
      end
      marker = :trace.delivered(session, worker)
      {result, drain(worker, mfa, marker, 0)}
    after
      :trace.process(session, worker, false, [:call, :arity])
      assert :trace.function(session, mfa, false, [:local]) == 1
      assert :trace.info(session, worker, :flags) == {:flags, []}
      assert :trace.info(session, mfa, :traced) == {:traced, false}
      marker = :trace.delivered(session, worker)
      assert drain(worker, mfa, marker, 0) == 0
      assert :trace.session_destroy(session)
      assert :trace.session_info(worker) == []
      assert :trace.session_info(:all) == sessions
      send(worker, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    end
  end

  defp drain(worker, mfa, marker, calls) do
    receive do
      {:trace, ^worker, :call, ^mfa} -> drain(worker, mfa, marker, calls + 1)
      {:trace_delivered, ^worker, ^marker} -> calls
    after
      1_000 -> flunk("载荷编码trace投递屏障未完成")
    end
  end
end
