defmodule AuthServer.Connections do
  @moduledoc "全局系统功能：账号会话到游戏连接的派生登记；接纳与撤销串行，数据库始终是授权真值。"
  use GenServer
  alias DataService.AccountStore, as: Store
  @doc false
  def start_link(_), do: GenServer.start_link(__MODULE__,%{},name: __MODULE__)
  @doc "等待登记连接结束后才确认关闭；不把发出消息当成功。"
  def close_sessions(ids), do: GenServer.call(__MODULE__,{:close,ids},15_000)
  @doc "撤销持久化授权并关闭登记连接。"
  def revoke(account,sid), do: GenServer.call(__MODULE__,{:revoke,account,sid},15_000)
  @doc "消费票据并监视连接，Auth 故障由连接反向监视并终止。"
  def consume(digest,cid,username,scene,hello,pid),do: GenServer.call(__MODULE__,{:consume,digest,cid,username,scene,hello,pid})
  @impl true
  def init(state), do: {:ok,state}
  @impl true
  def format_status(status),do: status |> Map.put(:message,:redacted) |> Map.put(:state,:redacted)
  @impl true
  def handle_call({:close,ids},_,state), do: {:reply,:ok,close(ids,state)}
  def handle_call({:revoke,account,sid},_,state) do
    case Store.revoke(account,sid,AuthServer.Identity.now()) do
      {:ok,ids} -> {:reply,:ok,close(ids,state)}
      error -> {:reply,error,state}
    end
  end
  def handle_call({:consume,digest,cid,username,scene,hello,pid},_,state) do
    case Store.consume_ticket(digest,cid,username,scene,hello,AuthServer.Identity.now()) do
      {:ok,c} ->
        ref=Process.monitor(pid)
        Process.send_after(self(),{:expire,c.session_id},max(0,c.expires_at-AuthServer.Identity.now())*1000)
        {:reply,{:ok,c},Map.put(state,ref,{c.session_id,pid})}
      {:error,_} -> {:reply,{:error,:invalid_ticket},state}
    end
  end
  @impl true
  def handle_info({:DOWN,ref,:process,_,_},state), do: {:noreply,Map.delete(state,ref)}
  def handle_info({:expire,sid},state), do: {:noreply,close([sid],state)}
  defp close(ids,state) do
    Enum.reduce(state,state,fn {ref,{sid,pid}},acc ->
      if sid in ids do
        # 连接监督树不会重启正常结束的临时连接进程。
        stop_connection(pid)
        Process.demonitor(ref,[:flush])
        Map.delete(acc,ref)
      else
        acc
      end
    end)
  end
  defp stop_connection(pid) do
    GenServer.stop(pid,:normal,5_000)
  catch
    # A normal disconnect may finish between receiving the revoke and stopping it.
    :exit, :noproc -> :ok
    :exit, {:noproc,_} -> :ok
    :exit, {:normal,_} -> :ok
    # QUIC's linked edit-worker cleanup can terminate the owner with :killed.
    # GenServer.stop observed its death: revocation is complete, not an Auth failure.
    :exit, {:killed,_} -> :ok
  end
end
