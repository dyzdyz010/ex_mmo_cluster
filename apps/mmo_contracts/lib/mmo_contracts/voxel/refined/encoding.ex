defmodule MmoContracts.Voxel.Refined.Encoding do
  @moduledoc """
  refined 后缀的纯编码输入：每格 `{槽数, 已按槽升序编码的记录}`。

  记录字段与次序由调用方的合法槽投影保证，本边界只构造格索引／计数／字节长度不变量。
  不含 World 私有表示，不是解码后的槽 map，也不参与 payload 读取或世界裁决。
  """
  @enforce_keys [:cells]
  defstruct [:cells]
  @opaque t :: %__MODULE__{cells: %{non_neg_integer() => {pos_integer(), binary()}}}

  @doc "一次接纳编码投影；编码内部直接消费，不再次扫描验证。"
  def new(cells) when is_map(cells) do
    Enum.each(cells, fn
      {index, {count, bytes}} when is_integer(index) and index in 0..287_495
        and is_integer(count) and count in 1..512 and is_binary(bytes) and byte_size(bytes) == count * 16 -> :ok
      row -> raise ArgumentError, "invalid refined encoding cell: #{inspect(row)}"
    end)
    %__MODULE__{cells: cells}
  end

  @doc "编码投影的宏格数量。"
  def size(%__MODULE__{cells: cells}), do: map_size(cells)
end
