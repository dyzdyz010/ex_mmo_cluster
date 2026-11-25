defmodule GateServer.Telemetry do
  @moduledoc """
  全局系统功能：玩家使用遥测（商业验证用的最小埋点）。事件追加进 `auth_audit`（`DataService.AccountStore`），
  对象是账号 id，不记邮箱。事件：`session_start`（Join 被接纳）、`session_end`（连接结束，带时长与原因）、
  `first_edit`（该账号第一次被服务端确认的世界意图，终身一行）。

  写库放在独立的一次性 Task：不阻塞 Gate / 编辑 worker，失败只记一条警告，不影响游戏会话，也不重试。
  每个事件至多一个 Task，数量受会话数约束。
  """
  require Logger
  alias DataService.AccountStore

  @doc "Join 被接纳、`WorldServer.Session.claim` 成功后由连接进程调用；`cid` 是本次入场的角色。"
  def session_start(cid),
    do:
      run(:session_start, cid, fn ->
        AccountStore.record_session_event(cid, "session_start", %{}, now())
      end)

  @doc """
  已入场的连接进程结束时调用。`started_ms` 是入场时的单调时钟毫秒，时长按整秒向下取整；
  `reason` 是 `close/3` 记下的断连原因名，没有经过 `close/3` 时为 terminate 原因的 inspect 文本。
  """
  def session_end(cid, started_ms, reason) do
    details = %{
      duration_s: div(System.monotonic_time(:millisecond) - started_ms, 1000),
      reason: reason
    }

    run(:session_end, cid, fn ->
      AccountStore.record_session_event(cid, "session_end", details, now())
    end)
  end

  @doc "在执行确认的 worker 进程里调用；每个会话（每个 worker）最多触发一次 SQL，账号层面的终身一次由语句保证。"
  def first_edit(cid) do
    unless Process.get(:telemetry_first_edit) do
      Process.put(:telemetry_first_edit, true)
      run(:first_edit, cid, fn -> AccountStore.record_first_edit(cid, now()) end)
    end

    :ok
  end

  defp now, do: System.os_time(:second)

  defp run(event, cid, fun) do
    Task.start(fn ->
      try do
        fun.()
      rescue
        error ->
          Logger.warning(
            "telemetry_failed event=#{event} cid=#{inspect(cid)} error=#{Exception.message(error)}"
          )
      end
    end)

    :ok
  end
end
