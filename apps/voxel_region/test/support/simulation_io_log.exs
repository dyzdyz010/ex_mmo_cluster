defmodule VoxelRegion.TestSupport.SimulationIoLog do
  @moduledoc "只测试：真实文件页读外加指定冷页的失败／成功前读取闸。"
  alias VoxelRegion.OverlayLog.File, as: Log
  defdelegate open(path, cv), to: Log
  defdelegate replay(path), to: Log
  defdelegate append(path, txn), to: Log
  defdelegate checkpoint(path, txn), to: Log
  defdelegate prefix(path), to: Log
  defdelegate clear_unpublished(path, prefix), to: Log
  defdelegate write_pages(path, cut, rows), to: Log
  defdelegate publish(path, cut, rows, globals), to: Log
  defdelegate load(path), to: Log
  defdelegate load_head(path, code), to: Log
  defdelegate locate(path, ids), to: Log
  defdelegate page_keys(path), to: Log
  defdelegate collect(path, prefix, limit), to: Log

  @doc "在指定页的真实读取边界注入失败或成功前屏障；仅用于测试与显式CLI probe。"
  def mode(mode, observer, key), do: :persistent_term.put(__MODULE__, {mode, observer, key})
  @doc "退休本probe的读取屏障。"
  def clear, do: :persistent_term.erase(__MODULE__)

  @doc "读取真实文件段；命中屏障时先通知观察者，不创建另一份页真值。"
  def read_pages(path, keys, fragments) do
    case :persistent_term.get(__MODULE__, nil) do
      {mode, observer, key} ->
        if key in keys do
          send(observer, {:simulation_io_read, self(), key})
          case mode do
            :fail -> raise "test-only simulation page unavailable"
            :hold -> receive do: (:continue -> :ok)
          end
        end
      nil -> :ok
    end
    Log.read_pages(path, keys, fragments)
  end
end

