defmodule GateServer.Session.Sink do
  @moduledoc """
  Gate 会话的**出站传输契约** —— TCP 连接与 WebSocket 连接之间唯一的真实差异。

  两个连接进程（`GateServer.TcpConnection` / `GateServer.WsConnection`）跑的是同一套
  会话状态机与同一套体素业务管线；它们只在三件事上不同：

  1. 编码后的字节往哪写（`:gen_tcp.send/2` vs 转交 WebSocket owner 进程）；
  2. 已含 opcode 的裸帧往哪写（同上，但不过字节 codec）；
  3. 结构化 observe 事件名的传输前缀（TCP 无前缀，WS 用 `ws_`）。

  把这三点收进本结构后，业务侧只依赖 sink 契约，不再需要知道自己跑在哪条链路上，
  tcp / ws 也就不必再各自维护一份逐字镜像的实现。

  ## observe 事件命名

  `emit/3` 会给事件名加上传输前缀，因此同一段共享代码在 TCP 下发
  `voxel_prefab_routed`、在 WS 下发 `ws_voxel_prefab_routed` —— 与拆分前逐字一致。
  少数历史上两条链路共用同一个无前缀名字的事件（如 `voxel_edit_intent_routed`）
  直接调 `GateServer.CliObserve.emit/2`，不走本模块，以免改变既有 CLI 契约。
  """

  require Logger

  @enforce_keys [:transport, :ref, :event_prefix]
  defstruct [:transport, :ref, :event_prefix]

  @type transport :: :tcp | :ws | :quic

  @type t :: %__MODULE__{
          transport: transport(),
          ref: port() | pid(),
          event_prefix: String.t()
        }

  alias MmoContracts.Session.Codec, as: SessionCodec
  alias MmoContracts.Voxel.Codec, as: VoxelCodec
  require SessionCodec
  require VoxelCodec

  @doc "M1 Scene 的唯一可靠出口；消息保留 identity 和流语义至连接 owner。"
  def reliable(gate_pid, identity, stream, message) when stream in [:control, :voxel] do
    purpose = if stream == :control, do: 1, else: 2
    send(gate_pid, {:mmo_reliable, identity, purpose, message})
    :ok
  end

  @doc "M1 可替换移动输出；只在调用 async_send_dgram 之前替换旧样本。"
  def datagram(gate_pid, identity, message) do
    send(gate_pid, {:mmo_datagram, identity, message})
    :ok
  end

  @doc "结束此 identity，不触碰之后重新登录的会话。"
  def close(gate_pid, identity, reason) do
    send(gate_pid, {:mmo_close, identity, reason})
    :ok
  end

  @doc "只选择消息所属的字节 owner，不改变传输行为。"
  def encode(message) when SessionCodec.is_message(message), do: SessionCodec.encode(message)
  def encode(message) when VoxelCodec.is_message(message), do: VoxelCodec.encode(message)
  def encode(message), do: GateServer.Codec.encode(message)

  @doc "为一条已接管的 TCP socket 构造 sink。"
  @spec tcp(port()) :: t()
  def tcp(socket), do: %__MODULE__{transport: :tcp, ref: socket, event_prefix: ""}

  @doc "为一个 WebSocket owner 进程构造 sink。"
  @spec ws(pid()) :: t()
  def ws(owner_pid) when is_pid(owner_pid),
    do: %__MODULE__{transport: :ws, ref: owner_pid, event_prefix: "ws_"}

  def quic(owner_pid, identity),
    do: %__MODULE__{transport: :quic, ref: {owner_pid, identity}, event_prefix: "quic_"}

  @doc """
  编码并下发一条协议消息。

  编码失败（新消息类型漏所属领域 `encode/1` 子句）只记结构化日志并丢弃，
  不 raise —— 一条编不出来的下行消息不该带崩整条连接。
  """
  @spec send_encoded(t(), tuple()) :: :ok
  def send_encoded(%__MODULE__{} = sink, message) do
    case encode(message) do
      {:ok, encoded} ->
        send_raw(sink, IO.iodata_to_binary(encoded))

      {:error, reason} ->
        Logger.warning(
          "gate(#{sink.transport}): dropped unencodable outbound message: #{inspect(reason)}"
        )

        GateServer.CliObserve.emit("gate_outbound_encode_failed", %{
          transport: sink.transport,
          reason: reason
        })

        :ok
    end
  end

  @doc """
  下发一份已经含 opcode 的裸 payload（Field 快照等由生产方编好的帧）。

  TCP socket 的 `{packet, 4}` 选项会在 `:gen_tcp` 层补 4 字节大端长度前缀；
  WebSocket 侧由 owner 进程按 binary frame 发出。
  """
  @spec send_raw(t(), binary()) :: :ok
  def send_raw(%__MODULE__{transport: :quic, ref: {owner_pid, identity}}, payload) when is_binary(payload) do
    send(owner_pid, {:mmo_voxel_bytes, identity, payload})
    :ok
  end

  def send_raw(%__MODULE__{transport: :tcp, ref: socket}, payload) when is_binary(payload) do
    _ = :gen_tcp.send(socket, payload)
    :ok
  end

  def send_raw(%__MODULE__{transport: :ws, ref: owner_pid}, payload) when is_binary(payload) do
    send(owner_pid, {:gate_ws_send, payload})
    :ok
  end

  @doc "发一条带传输前缀的结构化 observe 事件。"
  @spec emit(t(), String.t(), map() | (-> map())) :: :ok
  def emit(%__MODULE__{event_prefix: prefix}, event, fields) do
    GateServer.CliObserve.emit(prefix <> event, fields)
  end

  @doc """
  发一条带**传输名**前缀的 observe 事件（`tcp_` / `ws_`）。

  只服务于历史上两条链路都显式带自己传输名的少数事件，保持 CLI 契约不变。
  """
  @spec emit_transport_tagged(t(), String.t(), map() | (-> map())) :: :ok
  def emit_transport_tagged(%__MODULE__{transport: transport}, event, fields) do
    GateServer.CliObserve.emit("#{transport}_" <> event, fields)
  end
end
