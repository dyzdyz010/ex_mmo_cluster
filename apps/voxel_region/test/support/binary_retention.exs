defmodule VoxelRegion.TestSupport.BinaryRetention do
  @moduledoc """
  只测试：判定一个 binary 是否让更大的父 binary 一直存活，不依赖 `:binary.referenced_byte_size/1`。

  OTP 27.2.4 的该 BIF 对 <= 64 字节的 binary 恒返回 8 * byte_size（按位数），所以小值的“独立”断言
  不能用它。这里改为在全新进程里求值、整堆 GC，再用 `Process.info(:binary)` 读该进程仍引用的
  refc binary：值若是大父对象的切片，父对象的完整大小会留在列表里。实测 <= 64 字节的切片在该 VM 上
  总是被复制成独立 heap binary（返回 0），因此对这一长度的断言由 VM 保证；> 64 字节才有判别力。
  """

  @doc """
  在全新进程内执行 `fun`（须返回被测 binary，大输入请在 `fun` 内部构造而不要从闭包捕获），
  返回求值完成并 GC 后该进程仍引用的最大 refc binary 字节数。独立的小 binary 返回 0（heap binary），
  独立的大 binary 返回它自己的大小，切片返回父对象大小。
  """
  def max_retained_bytes(fun) when is_function(fun, 0) do
    caller = self()
    ref = make_ref()

    {_pid, monitor} =
      spawn_monitor(fn ->
        value = fun.()
        :erlang.garbage_collect()
        {:binary, binaries} = Process.info(self(), :binary)
        retained = binaries |> Enum.map(fn {_id, size, _refs} -> size end) |> Enum.max(fn -> 0 end)
        # 求值结果在 GC 之后仍被引用，才能代表“值存活时父对象是否被拖住”。
        send(caller, {ref, retained, byte_size(value)})
      end)

    receive do
      {^ref, retained, _size} ->
        Process.demonitor(monitor, [:flush])
        retained

      {:DOWN, ^monitor, :process, _pid, reason} ->
        raise "binary retention probe exited: #{inspect(reason)}"
    after
      10_000 -> raise "binary retention probe did not finish"
    end
  end
end
