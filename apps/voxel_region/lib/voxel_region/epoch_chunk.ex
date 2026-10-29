defmodule VoxelRegion.EpochChunk do
  @moduledoc """
  一个16³自然chunk内的不可变宏格世代。唯一正文按local槽号排序，每条为u16槽号和u64世代。
  全局XYZ只在chunk坐标和自然枚举边界重建；缺失槽与显式0不同，旧持久／公开map仅在边界导出。
  """
  alias VoxelRegion.CollisionSource

  @edge VoxelRegion.Spatial.chunk_size()
  @slots @edge * @edge * @edge
  @record_bytes 10
  @max_epoch 18_446_744_073_709_551_615
  @enforce_keys [:coord, :count, :data]
  defstruct [:coord, :count, :data]
  @opaque t :: %__MODULE__{coord: {integer(), integer(), integer()}, count: 0..4096, data: binary()}

  @doc "空自然单元；不代表其中任何槽已写过世代0。"
  def empty(coord), do: %__MODULE__{coord: coord, count: 0, data: <<>>}

  @doc "旧持久map在接纳边界一次校验；外部struct不能冒充已验证正文。"
  def from_map({cx, cy, cz} = coord, cells)
      when is_integer(cx) and is_integer(cy) and is_integer(cz) and
             is_map(cells) and not is_struct(cells) and map_size(cells) <= @slots do
    ordered = Enum.map(cells, fn {cell, epoch} ->
      {chunk, local, epoch} = validate_row(cell, epoch)
      if chunk != coord, do: raise(ArgumentError, "epoch cell #{inspect(cell)} outside chunk #{inspect(coord)}")
      {local, epoch}
    end) |> Enum.sort()
    pack(coord, ordered)
  end
  def from_map(_, _), do: raise(ArgumentError, "epoch chunk requires a coordinate and a map with at most 4096 entries")

  @doc "合法自然单元的记录数，不扫描正文。"
  def size(%__MODULE__{count: count}), do: count

  @doc "从按chunk索引的世代表读取；不存在时返回调用方给定缺省值。"
  def get(table, cell, default \\ nil) do
    coord = CollisionSource.chunk_coord(cell)
    case Map.fetch(table, coord) do
      :error -> default
      {:ok, value} -> search(value, local_index(cell, coord), 0, value.count - 1, default)
    end
  end

  @doc "接纳平铺世代增量；按chunk归组后，每个受影响单元只合并构造一次。"
  def merge(table, flat) when is_map(flat) and not is_struct(flat) do
    grouped = Enum.reduce(flat, %{}, fn {cell, epoch}, grouped ->
      {coord, local, epoch} = validate_row(cell, epoch)
      Map.update(grouped, coord, [{local, epoch}], &[{local, epoch} | &1])
    end)
    Enum.reduce(grouped, table, fn {coord, changes}, table ->
      old = Map.get(table, coord, empty(coord))
      data = merge_records(old.data, Enum.sort(changes), [])
      Map.put(table, coord, build(coord, data))
    end)
  end
  def merge(_, _), do: raise(ArgumentError, "epoch delta requires a map")

  @doc "单个合法单元在旧持久编码边界导出globalXYZ map。"
  def to_map(%__MODULE__{} = value), do: Map.new(value)

  @doc "公开观察／旧日志的平铺globalXYZ map；box沿现有完整XYZ区域契约选择chunk。"
  def flat(table, box \\ nil),
    do: for({coord, chunk} <- table, box == nil or CollisionSource.in_box?(coord, box), row <- chunk, into: %{}, do: row)

  defp validate_row({x, y, z} = cell, epoch)
      when is_integer(x) and is_integer(y) and is_integer(z) and is_integer(epoch) and epoch in 0..@max_epoch do
    coord = CollisionSource.chunk_coord(cell)
    {coord, local_index(cell, coord), epoch}
  end
  defp validate_row(cell, epoch), do: raise(ArgumentError, "invalid epoch row: #{inspect({cell, epoch})}")

  defp local_index({x, y, z}, {cx, cy, cz}),
    do: x - cx * @edge + @edge * (y - cy * @edge + @edge * (z - cz * @edge))

  defp pack(coord, rows), do: build(coord, for({local, epoch} <- rows, into: <<>>, do: <<local::16-little, epoch::64-little>>))
  defp build(coord, data), do: %__MODULE__{coord: coord, count: div(byte_size(data), @record_bytes), data: data}

  # 旧正文已经合法；同一有序序列线性合并，不重新校验或展开成全chunk map。
  defp merge_records(data, [], acc), do: IO.iodata_to_binary(Enum.reverse([data | acc]))
  defp merge_records(<<>>, [{local, epoch} | rest], acc),
    do: merge_records(<<>>, rest, [<<local::16-little, epoch::64-little>> | acc])
  defp merge_records(<<record::binary-size(@record_bytes), tail::binary>> = data, [{local, epoch} | rest] = changes, acc) do
    <<old_local::16-little, _::64>> = record
    cond do
      old_local < local -> merge_records(tail, changes, [record | acc])
      old_local == local -> merge_records(tail, rest, [<<local::16-little, epoch::64-little>> | acc])
      true -> merge_records(data, rest, [<<local::16-little, epoch::64-little>> | acc])
    end
  end

  defp search(_, _, lo, hi, default) when lo > hi, do: default
  defp search(value, local, lo, hi, default) do
    middle = div(lo + hi, 2)
    {found, epoch} = record(value, middle)
    cond do
      found == local -> epoch
      found < local -> search(value, local, middle + 1, hi, default)
      true -> search(value, local, lo, middle - 1, default)
    end
  end

  defp record(%{data: data}, position) do
    offset = position * @record_bytes
    <<_::binary-size(offset), local::16-little, epoch::64-little, _::binary>> = data
    {local, epoch}
  end

  defp row(%{coord: {cx, cy, cz}} = value, position) do
    {local, epoch} = record(value, position)
    {{cx * @edge + rem(local, @edge), cy * @edge + rem(div(local, @edge), @edge),
      cz * @edge + div(local, @edge * @edge)}, epoch}
  end

  @doc false
  def enumerable_reduce(value, acc, fun, position \\ 0)
  def enumerable_reduce(_value, {:halt, acc}, _fun, _position), do: {:halted, acc}
  def enumerable_reduce(value, {:suspend, acc}, fun, position),
    do: {:suspended, acc, &enumerable_reduce(value, &1, fun, position)}
  def enumerable_reduce(%{count: count}, {:cont, acc}, _fun, count), do: {:done, acc}
  def enumerable_reduce(value, {:cont, acc}, fun, position),
    do: enumerable_reduce(value, fun.(row(value, position), acc), fun, position + 1)
end

defimpl Enumerable, for: VoxelRegion.EpochChunk do
  def reduce(value, acc, fun), do: VoxelRegion.EpochChunk.enumerable_reduce(value, acc, fun)
  def count(value), do: {:ok, VoxelRegion.EpochChunk.size(value)}
  def member?(_value, _entry), do: {:error, __MODULE__}
  def slice(_value), do: {:error, __MODULE__}
end
