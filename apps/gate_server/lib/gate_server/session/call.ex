defmodule GateServer.Session.Call do
  @moduledoc """
  Gate 会话进程发起跨进程调用的**唯一**安全入口。

  连接进程要同时服务 socket 读写与业务调用：被调方（Interface / PlayerManager /
  PlayerCharacter / Scene）不存在、已崩、超时都是**正常可发生**的运行时事件，不该
  把连接进程一起带崩。本模块把 `GenServer.call/3` 的 `:exit` 统一转成显式
  `{:error, reason}`，由调用方按业务语义决定回哪种错误帧。

  注意：返回值是**双层**的 —— `{:ok, reply}` 里的 `reply` 仍是被调方自己的返回，
  典型形如 `{:ok, {:ok, ppid}}`。调用方必须显式区分「调用成功但业务拒绝」与
  「调用本身失败」。
  """

  @default_timeout 15_000

  @doc "Gate 会话默认调用超时（毫秒）——场景 / 鉴权侧调用共用同一预算。"
  @spec default_timeout() :: pos_integer()
  def default_timeout, do: @default_timeout

  @doc """
  调用 `server`，把 exit 归一成 `{:error, reason}`。

  `server` 为 `nil`（尚未接入场景等）直接返回 `{:error, :unavailable}`，免得调用方
  各自加 nil 判断。
  """
  @spec safe(GenServer.server() | nil, term(), timeout()) :: {:ok, term()} | {:error, term()}
  def safe(server, message, timeout \\ @default_timeout)
  def safe(nil, _message, _timeout), do: {:error, :unavailable}

  def safe(server, message, timeout) do
    {:ok, GenServer.call(server, message, timeout)}
  catch
    :exit, reason -> {:error, reason}
  end
end
