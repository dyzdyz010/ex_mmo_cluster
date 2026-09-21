defmodule GateServer.Transport.QuicListener do
  @moduledoc "全局系统功能：Voxim 的单一 QUIC 接入点；连接进程接管后才握手。会话占用登记在 `GateServer.Session.Claims`。"
  use GenServer
  require Logger

  # 公网实测：大于此 IP 包长时，路径清除 DF 后分片串包。由传输层限制 PMTU 探测与数据包，
  # 可靠流由 QUIC 分包，DATAGRAM 队列继续服从协商得到的 dgram_max_len。
  @maximum_mtu 1252

  alias GateServer.Session.{Claims, QuicConnection}

  @doc "启动监听与其连接监督树。证书及 Hello 身份必须由部署显式提供。"
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    # 会话占用登记与传输无关；部署传入共享登记处（NPC Body 也用它），单独启动的 listener 自带一个。
    claims =
      Keyword.get_lazy(opts, :claims, fn ->
        {:ok, pid} = Claims.start_link(Keyword.take(opts, [:route_module]))
        pid
      end)

    {:ok, listener} =
      :quicer.listen(Keyword.fetch!(opts, :port),
        certfile: opts |> Keyword.fetch!(:certfile) |> String.to_charlist(),
        keyfile: opts |> Keyword.fetch!(:keyfile) |> String.to_charlist(),
        alpn: [~c"voxim-m1"],
        peer_bidi_stream_count: 2,
        peer_unidi_stream_count: 0,
        # 单个未完成发送依赖 MsQuic 内部缓冲；关闭缓冲会变成每 RTT 仅发送一条时间线消息。
        datagram_receive_enabled: 1,
        server_resumption_level: 0,
        send_buffering_enabled: 1,
        pacing_enabled: 1,
        # 显式指定 QUIC 的 1200 B 最小载荷加 IPv6/UDP 头，握手不沿用库的更大初始 MTU。
        minimum_mtu: 1248,
        maximum_mtu: @maximum_mtu
      )

    Logger.info(
      "voxim_quic_listener port=#{Keyword.fetch!(opts, :port)} maximum_mtu=#{@maximum_mtu}"
    )

    # quicer rejects NEW_CONNECTION immediately when its acceptor queue is empty.
    # The M1 simultaneous two-account probe requires two armed native accepts.
    for _ <- 1..2, do: {:ok, ^listener} = :quicer.async_accept(listener, %{})

    {:ok,
     %{
       listener: listener,
       supervisor: supervisor,
       opts: opts,
       claims: claims
     }}
  end

  @impl true
  def handle_info({:quic, :new_conn, conn, _info}, state) do
    {:ok, _} = :quicer.async_accept(state.listener, %{})

    {:ok, pid} =
      DynamicSupervisor.start_child(
        state.supervisor,
        {QuicConnection, [conn: conn, listener: state.claims] ++ state.opts}
      )

    :ok = :quicer.controlling_process(conn, pid)
    GenServer.cast(pid, :activate)
    {:noreply, state}
  end

  def handle_info({:EXIT, supervisor, reason}, %{supervisor: supervisor} = state),
    do: {:stop, reason, state}

  def handle_info({:quic, _, _, _}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :quicer.close_listener(state.listener)
    if Process.alive?(state.supervisor), do: Supervisor.stop(state.supervisor)
  end
end
