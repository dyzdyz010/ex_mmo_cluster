defmodule GateServer.Transport.QuicListener do
  @moduledoc "Voxim 的单一 QUIC 接入点；连接进程接管后才握手，角色替换只撤销旧 identity。"
  use GenServer

  alias GateServer.Session.QuicConnection
  alias MmoContracts.Session.Identity

  @doc "启动监听与其连接监督树。证书及 Hello 身份必须由部署显式提供。"
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, listener} = :quicer.listen(Keyword.fetch!(opts, :port), [
      certfile: opts |> Keyword.fetch!(:certfile) |> String.to_charlist(),
      keyfile: opts |> Keyword.fetch!(:keyfile) |> String.to_charlist(),
      alpn: [~c"voxim-m1"], peer_bidi_stream_count: 2, peer_unidi_stream_count: 0,
      datagram_receive_enabled: 1, server_resumption_level: 0, send_buffering_enabled: 0, pacing_enabled: 1
    ])
    # quicer rejects NEW_CONNECTION immediately when its acceptor queue is empty.
    # The M1 simultaneous two-account probe requires two armed native accepts.
    for _ <- 1..2, do: {:ok, ^listener} = :quicer.async_accept(listener, %{})
    {:ok, %{listener: listener, supervisor: supervisor, opts: opts,
      characters: %{}, next_epoch: System.system_time(:microsecond)}}
  end

  @impl true
  def handle_info({:quic, :new_conn, conn, _info}, state) do
    {:ok, _} = :quicer.async_accept(state.listener, %{})
    {:ok, pid} = DynamicSupervisor.start_child(state.supervisor,
      {QuicConnection, [conn: conn, listener: self()] ++ state.opts})
    :ok = :quicer.controlling_process(conn, pid)
    GenServer.cast(pid, :activate)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    characters = Map.reject(state.characters, fn {_, owner} -> owner.pid == pid and owner.monitor == ref end)
    {:noreply, %{state | characters: characters}}
  end

  def handle_info({:EXIT, supervisor, reason}, %{supervisor: supervisor} = state),
    do: {:stop, reason, state}

  def handle_info({:quic, _, _, _}, state), do: {:noreply, state}

  @impl true
  def handle_call({:claim, scene, route, character}, {pid, _}, state) do
    cid = character.id
    case state.characters[cid] do
      nil -> :ok
      previous ->
        :ok = previous.scene.leave(previous.scene_ref, previous.identity, 2)
        send(previous.pid, {:mmo_close, previous.identity, 2})
    end
    identity = %Identity{session_epoch: state.next_epoch, scene_id: route.scene_id, scene_epoch: route.scene_epoch}
    # 同一 listener 先 leave 后 join，Scene 的邮箱顺序保证旧成员先退出；不等旧 QUIC 关闭。
    :ok = scene.join(route.scene_ref, identity, character, pid)
    owner = %{pid: pid, identity: identity, monitor: Process.monitor(pid), scene: scene, scene_ref: route.scene_ref}
    {:reply, identity, %{state | next_epoch: state.next_epoch + 1,
      characters: Map.put(state.characters, cid, owner)}}
  end

  @impl true
  def terminate(_reason, state) do
    :quicer.close_listener(state.listener)
    if Process.alive?(state.supervisor), do: Supervisor.stop(state.supervisor)
  end
end
