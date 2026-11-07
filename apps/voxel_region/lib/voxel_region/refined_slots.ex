defmodule VoxelRegion.RefinedSlots do
  @moduledoc """
  单宏格的不可变合法细化槽。构造时校验完整字段域，最多 512 槽。

  独立 binary 按 slot 升序保存纯协议记录；枚举、查询与编码都读这一段。
  槽没有天然的加入次序，次序按 slot 键定义：HP 浮点累加与代表微格（末个槽）由此确定，
  不随 map 遍历次序变化（Erlang 不承诺该次序；OTP 29 对超过 32 键的 map 反转了 `maps:to_list`）。
  旧 map 只在局部编辑或持久编码边界临时导出，不作为第二份常驻真值。
  """
  defstruct count: 0, data: <<>>
  @opaque t :: %__MODULE__{count: 0..512, data: binary()}

  @doc "空槽值；canonical owner 不为它保留宏格。"
  def empty, do: %__MODULE__{}

  @doc "已接纳值直接传递；局部编辑或旧存储 map 在此一次冻结合法字段。"
  def new(%__MODULE__{} = value), do: value
  def new(slots), do: from_map(slots)

  @doc "外部旧格式只接纳普通 map，不能用伪造 struct 冒充已验证值。"
  def from_map(slots) when is_map(slots) and not is_struct(slots) and map_size(slots) <= 512 do
    records = for row <- Enum.sort(slots), into: <<>> do
      case row do
        {slot, {material, {birth, occurrence}}}
        when is_integer(slot) and slot in 0..511 and is_integer(material) and material in 1..65_535
          and is_integer(birth) and birth in 0..18_446_744_073_709_551_615
          and is_integer(occurrence) and occurrence in 0..4_294_967_295 ->
          MmoContracts.Voxel.Refined.slot_record(row)
        _ -> raise ArgumentError, "invalid refined slot: #{inspect(row)}"
      end
    end
    %__MODULE__{count: map_size(slots), data: records}
  end
  def from_map(_), do: raise(ArgumentError, "refined slots require a map with at most 512 entries")

  @doc "合法值的槽数，不扫描记录。"
  def size(%__MODULE__{count: count}), do: count

  @doc "已接纳槽的升序协议记录；直接引用独立宏格的记录前缀，不解码或重编码。"
  def sorted_records(%__MODULE__{data: data, count: count}), do: binary_part(data, 0, count * 16)

  @doc "按 slot 二分查找；洞或范围外返回 :error。"
  def fetch(%__MODULE__{} = value, slot), do: search(value, slot, 0, value.count - 1)
  defp search(_, _, lo, hi) when lo > hi, do: :error
  defp search(value, slot, lo, hi) do
    middle = div(lo + hi, 2)
    {found, entry} = row(value, middle)
    cond do
      found == slot -> {:ok, entry}
      found < slot -> search(value, slot, middle + 1, hi)
      true -> search(value, slot, lo, middle - 1)
    end
  end

  @doc "按 slot 升序归约（与 `Enumerable` 同序）。"
  def reduce(%__MODULE__{} = value, acc, fun), do: Enum.reduce(value, acc, fun)

  @doc "按 slot 升序归约，直接读取有序记录，不重新排序。"
  def reduce_sorted(%__MODULE__{} = value, acc, fun), do: ordered_reduce(value, 0, acc, fun)
  defp ordered_reduce(%{count: count}, count, acc, _fun), do: acc
  defp ordered_reduce(value, position, acc, fun),
    do: ordered_reduce(value, position + 1, fun.(row(value, position), acc), fun)

  @doc "局部编辑／旧持久格式边界临时导出 map。"
  def to_map(%__MODULE__{} = value), do: reduce(value, %{}, fn {slot, row}, acc -> Map.put(acc, slot, row) end)

  defp row(%{data: data}, position) do
    offset = position * 16
    <<_::binary-size(^offset), slot::16-little, material::16-little, birth::64-little,
      occurrence::32-little, _::binary>> = data
    {slot, {material, {birth, occurrence}}}
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

defimpl Enumerable, for: VoxelRegion.RefinedSlots do
  def reduce(value, acc, fun), do: VoxelRegion.RefinedSlots.enumerable_reduce(value, acc, fun)
  def count(value), do: {:ok, VoxelRegion.RefinedSlots.size(value)}
  def member?(_value, _entry), do: {:error, __MODULE__}
  def slice(_value), do: {:error, __MODULE__}
end
