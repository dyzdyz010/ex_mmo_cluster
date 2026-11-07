defmodule VoxelRegion.TestSupport.ThermalReference do
  @moduledoc "只测试：房屋热学历史参考的完整采样判定；不运行 World，不生成参考值。"

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
