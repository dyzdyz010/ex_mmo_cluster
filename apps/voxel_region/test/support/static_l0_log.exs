defmodule VoxelRegion.TestSupport.StaticL0Log do
  @moduledoc "只测试：真实 File 页存储的读取／发布屏障，只控制 IO 完成时机，不改页或事务内容。"
  alias VoxelRegion.OverlayLog.File, as: Log
  defdelegate open(path, cv), to: Log
  defdelegate replay(path), to: Log
  defdelegate append(path, txn), to: Log
  defdelegate checkpoint(path, txn), to: Log
  defdelegate prefix(path), to: Log
  defdelegate clear_unpublished(path, prefix), to: Log
  defdelegate write_pages(path, cut, rows), to: Log
  defdelegate load(path), to: Log
  defdelegate load_head(path, code), to: Log
  defdelegate locate(path, ids), to: Log
  defdelegate page_keys(path), to: Log
  defdelegate collect(path, prefix, limit), to: Log

  def hold_read(path, key, owner), do: :persistent_term.put({__MODULE__, path, :read}, {key, owner})
  def watch_reads(path, key, owner), do: :persistent_term.put({__MODULE__, path, :watch}, {key, owner})
  def hold_publish(path, owner, count), do: :persistent_term.put({__MODULE__, path, :publish}, {owner, count})
  def clear(path) do
    for kind <- [:read, :publish, :watch], do: :persistent_term.erase({__MODULE__, path, kind})
    :ok
  end

  def read_pages(path, keys, fragments) do
    case :persistent_term.get({__MODULE__, path, :watch}, nil) do
      {key, owner} -> if key in keys, do: send(owner, {:static_read_seen, self(), key})
      nil -> :ok
    end
    case :persistent_term.get({__MODULE__, path, :read}, nil) do
      {key, owner} ->
        if key in keys do
          :persistent_term.erase({__MODULE__, path, :read})
          send(owner, {:static_read_held, self(), key})
          receive do: (:continue -> :ok)
        end
      nil -> :ok
    end
    Log.read_pages(path, keys, fragments)
  end

  def publish(path, cut, rows, globals) do
    case :persistent_term.get({__MODULE__, path, :publish}, nil) do
      {owner, count} when count > 0 ->
        :persistent_term.put({__MODULE__, path, :publish}, {owner, count - 1})
        send(owner, {:static_publish_held, self(), cut})
        receive do: ({:continue, ^cut} -> :ok)
      _ -> :ok
    end
    Log.publish(path, cut, rows, globals)
  end
end
