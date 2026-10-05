defmodule AuthServer.RateLimit do
  @moduledoc "全局系统功能：单 release 公网认证限流；固定窗口到期即清理。"
  use GenServer
  @doc false
  def start_link(_), do: GenServer.start_link(__MODULE__,%{},name: __MODULE__)
  @doc "在认证昂贵操作之前计数；时间使用单调时钟。"
  def take(key,limit,seconds), do: GenServer.call(__MODULE__,{:take,key,limit,seconds})
  @impl true
  def init(state) do
    Process.send_after(self(),:expire,60_000)
    {:ok,state}
  end
  @impl true
  def handle_call({:take,key,limit,seconds},_,state) do
    now = System.monotonic_time(:second)
    {count,until} = case Map.get(state,key) do
      {n,expiry} when expiry>now -> {n,expiry}
      _ -> {0,now+seconds}
    end
    reply = if count < limit, do: :ok, else: {:error,:rate_limited}
    {:reply,reply,Map.put(state,key,{count+1,until})}
  end
  @impl true
  def handle_info(:expire,state) do
    now = System.monotonic_time(:second)
    Process.send_after(self(),:expire,60_000)
    {:noreply,Map.reject(state,fn {_,{_,expiry}} -> expiry<=now end)}
  end
end
