defmodule VoxelRegion.TestSupport.HeldPageLog do
  @moduledoc "只测试：真实文件后端，下一次read_pages在读取边界等显式放行；不修改返回的canonical真值。"
  alias VoxelRegion.TestSupport.Log
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

  def read_pages(path, keys, fragments) do
    case :persistent_term.get({__MODULE__, path}, nil) do
      owner when is_pid(owner) ->
        :persistent_term.erase({__MODULE__, path})
        send(owner, {:holding_read, self()})
        receive do: (:continue_read -> :ok)

      nil ->
        :ok
    end

    Log.read_pages(path, keys, fragments)
  end
end
