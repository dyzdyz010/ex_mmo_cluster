defmodule VoxelRegion.LogProjection do
  @moduledoc "全局系统功能：已提交体素日志的空间投影，不持有世界或订阅状态。"
  import Bitwise
  alias MmoContracts.Voxel.{Codec, Payload}

  @doc "按订阅范围生成现有协议消息；范围内无变化时返回 nil，由 owner 负责发送。"
  def message(%{entries: entries, coarse: coarse} = txn, filter) do
    entries = Enum.filter(entries, &matches?(&1, filter))
    coarse = Enum.filter(coarse, &matches_cell?(&1.level, &1.cell, filter))

    if entries != [] or coarse != [] do
      bin =
        Codec.encode_transaction(%{txn | entries: entries, coarse: coarse})
        |> IO.iodata_to_binary()

      {:voxel_log_transaction_payload, bin}
    end
  end

  def message(entry, filter) do
    if matches?(entry, filter),
      do: {:voxel_log_entry_payload, IO.iodata_to_binary(Codec.encode_entry(entry))}
  end

  defp matches?(%{payload: bytes}, filter) do
    {:ok, h} = Codec.decode_payload_header(bytes)
    {x, y, z} = h.region

    matches_span?(
      h.level,
      {x * 64, y * 64, z * 64},
      {x * 64 + 63, y * 64 + 63, z * 64 + 63},
      filter
    )
  end

  defp matches?(%{structure: _, level: level, cell: cell}, filter),
    do: matches_cell?(level, cell, filter)

  defp matches?(entry, {{{x0, y0, z0}, {x1, y1, z1}}, min_level}) do
    {rx, ry, rz} = region_of(entry.coord)

    in_box =
      rx >= x0 - 1 and rx <= x1 + 1 and ry >= y0 - 1 and ry <= y1 + 1 and rz >= z0 - 1 and
        rz <= z1 + 1

    in_box or Enum.any?(entry.coarse, &(&1.level >= min_level))
  end

  defp matches_cell?(level, cell, filter), do: matches_span?(level, cell, cell, filter)

  defp matches_span?(level, {ax, ay, az}, {bx, by, bz}, {{{x0, y0, z0}, {x1, y1, z1}}, min_level}) do
    step = 1 <<< level

    level >= min_level or
      (floor_div(ax * step, 64) <= x1 + 1 and floor_div((bx + 1) * step - 1, 64) >= x0 - 1 and
         floor_div(ay * step, 64) <= y1 + 1 and floor_div((by + 1) * step - 1, 64) >= y0 - 1 and
         floor_div(az * step, 64) <= z1 + 1 and floor_div((bz + 1) * step - 1, 64) >= z0 - 1)
  end

  @doc "投影到指定层级的完整三维区域；含覆盖该区域的替换条目时返回 :region。"
  def region(%{entries: entries, coarse: coarse} = txn, level, region) do
    {ox, oy, oz} = Payload.origin(region)

    replacement =
      Enum.any?(entries, fn
        %{structure: _, level: l, cell: cell} ->
          l == level and Payload.in_span?(Payload.local(region, cell))

        %{payload: bytes} ->
          {:ok, h} = Codec.decode_payload_header(bytes)
          {x, y, z} = h.region

          h.level == level and x * 64 <= ox + 65 and x * 64 + 63 >= ox and y * 64 <= oy + 65 and
            y * 64 + 63 >= oy and z * 64 <= oz + 65 and z * 64 + 63 >= oz

        _ ->
          false
      end)

    if replacement do
      :region
    else
      cells =
        Enum.filter(entries, fn e ->
          level == 0 and Map.has_key?(e, :coord) and
            Payload.in_span?(Payload.local(region, e.coord))
        end)

      coarse =
        Enum.filter(coarse, fn e ->
          e.level == level and Payload.in_span?(Payload.local(region, e.cell))
        end)

      %{txn | entries: cells, coarse: coarse}
    end
  end

  def region(entry, level, region) do
    region(
      %{seq: entry.seq, entries: [%{entry | coarse: []}], coarse: entry.coarse},
      level,
      region
    )
  end

  defp region_of({x, y, z}), do: {floor_div(x, 64), floor_div(y, 64), floor_div(z, 64)}
  defp floor_div(a, b), do: div(a - rem(rem(a, b) + b, b), b)
end
