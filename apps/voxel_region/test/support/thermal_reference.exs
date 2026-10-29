defmodule VoxelRegion.TestSupport.ThermalReference do
  @moduledoc "只测试：房屋热学历史参考的环境选择与完整采样判定；不运行 World，不生成参考值。"

  @doc "按预先声明的 OS 选择已有历史参考，不读取本轮输出选择参照。"
  def radiation({:win32, :nt}, windows, _linux) do
    {:ok, %{profile: :windows, origin: "725455d9f4d2b2964fd1772a68deb5a7a5f3913c", recorded: windows}}
  end

  def radiation({:unix, :linux}, _windows, linux) do
    {:ok, %{profile: :linux, origin: "af180c98c9ba9b436f353093676fbd583ce3743e", recorded: linux}}
  end

  def radiation(os, _windows, _linux), do: {:error, {:unsupported_reference_platform, os}}

  @doc "比较观测摘要与既有参考，返回可诊断的首个缺失或不符点。"
  def compare(trace, recorded) do
    Enum.reduce_while(Enum.sort(recorded), :ok, fn {elapsed, expected}, :ok ->
      case Map.fetch(trace, elapsed) do
        :error -> {:halt, {:error, {:missing_reference_point, elapsed}}}
        {:ok, ^expected} -> {:cont, :ok}
        {:ok, actual} -> {:halt, {:error, {:digest_mismatch, elapsed, expected, actual}}}
      end
    end)
  end
end
