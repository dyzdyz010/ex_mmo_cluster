defmodule VoxelRegion.Bench.PagingEquiv do
  @moduledoc """
  只测试（Test-only）：M2a 迁移等价（`m2a-page-store.md` §7、§8 第 9 项）的节点内采集，由 `equiv.py` 编排。

  - 判定器 a（原始真值逐键精确）：在 World 进程内按字段算顺序无关摘要（每项 `{键, 值}` 的确定性 ETF 取 MD5 后按 2^128 求和，
    另记项数），只回传摘要，不把状态拉出 World。`thermal.config` 每次启动由资产覆盖（§3），不比较。
  - 判定器 b（正式读取）：经 `World.serve` 取每个页存在的区域（`Pages.units/1` 所在的 {级, 区域}）的整区载荷，
    把头部 seq 置 0 后取 MD5。
  只在空闲节点上调用（无负载）。启动后的自然提交（例如旧检查点里的液体活动集在第一步趋静，m2a §4.2 的无几何提交）
  先走完：采集前等到 seq 连续 `quiet_s` 秒不变且液体不再排程；两侧 seq 由编排脚本核对。
  """
  import Bitwise
  alias MmoContracts.Voxel.Codec
  alias VoxelRegion.World
  alias VoxelRegion.World.Pages

  @maps [:overlay, :region_bases, :refined, :attachments, :liquid_units, :macro_owners, :damage, :instances, :attachment_owners,
    :material_balances, :caster_energy, :material_supplies, :craft_ledger, :food_ledger, :food_receipts, :beacons,
    :beacon_attunements, :phase_inventory]
  @nested [:epochs, :placed_by]
  @scalars [:seq, :attachment_serial, :material_units_per_micro, :interaction_history, :interaction_floor]

  @doc "等到静止后采集一侧的摘要并写到 `path`（JSON）；返回概要 JSON 文本。"
  def capture(path, quiet_s) do
    waited = quiet(GenServer.call(World, :seq, :infinity), System.monotonic_time(:second), quiet_s, System.monotonic_time(:second) + 900)
    started = System.monotonic_time(:millisecond)
    me = self()
    ref = make_ref()
    :sys.replace_state(World, fn s -> send(me, {ref, fields(s)}); s end, :infinity)
    fields = receive do {^ref, f} -> f end
    field_ms = System.monotonic_time(:millisecond) - started
    cv = World.content_version()

    reads =
      Map.new(fields.keys, fn {level, region} = key ->
        request = Codec.encode_request(cv, [%{level: level, region: region, have_seq: 0, have_hash: 0}]) |> IO.iodata_to_binary()
        {:ok, reply} = World.serve(request)
        {:ok, ^cv, [item]} = Codec.decode_reply(IO.iodata_to_binary(reply))

        digest =
          case item do
            {:payload, ^level, ^region, bytes} -> hex(:crypto.hash(:md5, Codec.stamp_payload_seq(bytes, 0)))
            other -> inspect(elem(other, 0))
          end

        {Enum.join([level | Tuple.to_list(region)], ","), digest}
      end)

    result = Map.merge(Map.delete(fields, :keys), %{regions: map_size(reads), reads: reads, field_ms: field_ms, quiet_wait_s: waited,
      read_ms: System.monotonic_time(:millisecond) - started - field_ms})
    File.write!(path, Jason.encode!(result))
    Jason.encode!(Map.drop(result, [:reads, :digests]))
  end

  # seq 连续 quiet_s 秒不变且液体不再排程；返回等待秒数。
  defp quiet(seq, since, quiet_s, deadline) do
    now = System.monotonic_time(:second)
    true = now < deadline
    Process.sleep(1_000)
    current = GenServer.call(World, :seq, :infinity)
    scheduled = GenServer.call(World, :liquid_activity, :infinity).scheduled

    cond do
      current != seq or scheduled -> quiet(current, System.monotonic_time(:second), quiet_s, deadline)
      System.monotonic_time(:second) - since >= quiet_s -> System.monotonic_time(:second) - (deadline - 900)
      true -> quiet(seq, since, quiet_s, deadline)
    end
  end

  @doc "等到已发布前缀覆盖 `seq`（迁移切点发布），最多 `timeout_s` 秒；返回 World 积压计量与当前 seq。"
  def await_published(seq, timeout_s) do
    deadline = System.monotonic_time(:second) + timeout_s
    wait(seq, deadline)
  end

  defp wait(seq, deadline) do
    stats = GenServer.call(World, :stats, :infinity)

    cond do
      stats.published_seq != nil and stats.published_seq >= seq ->
        Jason.encode!(Map.take(stats, [:published_seq, :persist_level, :suffix_txns, :dirty_units, :checkpoints])
          |> Map.put(:seq, GenServer.call(World, :seq, :infinity)))

      System.monotonic_time(:second) > deadline ->
        raise "published_seq #{inspect(stats.published_seq)} did not reach #{seq}"

      true ->
        Process.sleep(1_000)
        wait(seq, deadline)
    end
  end

  defp fields(s) do
    thermal = s.thermal || %{}

    digests =
      Map.new(@maps, &{&1, digest(Map.fetch!(s, &1))})
      |> Map.merge(Map.new(@nested, &{&1, digest(for {_, cells} <- Map.fetch!(s, &1), kv <- cells, do: kv)}))
      |> Map.merge(Map.new(@scalars, &{&1, digest([{&1, Map.fetch!(s, &1)}])}))
      |> Map.merge(%{
        liquid_active: digest(Enum.map(s.liquid_active, &{&1, true})),
        sources: digest(Map.get(thermal, :sources, %{})),
        thermal: digest(Map.drop(thermal, [:config, :sources])),
        protection: digest(s.protection.regions)
      })

    keys =
      Pages.units(s)
      |> Enum.map(fn
        {:chunk, _, {x, y, z}} -> {0, {Integer.floor_div(x, 4), Integer.floor_div(y, 4), Integer.floor_div(z, 4)}}
        {:page, _, key} -> key
      end)
      |> Enum.uniq()
      |> Enum.sort()

    %{seq: s.seq, published: s.page_store.published, cut: s.page_store.cut && s.page_store.cut.seq,
      thermal_run: s.thermal_run != nil, digests: digests, keys: keys}
  end

  # 顺序无关：每项 {键, 值} 的确定性 ETF 取 MD5，按 2^128 求和。
  defp digest(entries) do
    {n, sum} =
      Enum.reduce(entries, {0, 0}, fn kv, {n, sum} ->
        <<h::128>> = :crypto.hash(:md5, :erlang.term_to_binary(kv, [:deterministic]))
        {n + 1, rem(sum + h, 1 <<< 128)}
      end)

    "#{n}:#{Integer.to_string(sum, 16)}"
  end

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
end
