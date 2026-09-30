defmodule GateServer.Session.Sink do
  @moduledoc """
  Voxim QUIC 会话的出站契约：体素意图回执、余额、属性与施法者状态经连接 owner 进程下发。

  字节由现行领域 codec（`MmoContracts.Session.Codec` / `MmoContracts.Voxel.Codec`）编码；
  编不出的消息只记日志并丢弃，不带崩连接。
  """

  require Logger

  @enforce_keys [:transport, :ref, :event_prefix]
  defstruct [:transport, :ref, :event_prefix]

  @type transport :: :quic

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
  defdelegate reliable(gate_pid, identity, stream, message), to: MmoContracts.Session.Outbound

  @doc "M1 可替换移动输出；只在调用 async_send_dgram 之前替换旧样本。"
  defdelegate datagram(gate_pid, identity, message), to: MmoContracts.Session.Outbound

  @doc "结束此 identity，不触碰之后重新登录的会话。"
  defdelegate close(gate_pid, identity, reason), to: MmoContracts.Session.Outbound

  @doc "只选择消息所属的字节 owner，不改变传输行为。"
  def encode(message) when SessionCodec.is_message(message), do: SessionCodec.encode(message)
  def encode(message) when VoxelCodec.is_message(message), do: VoxelCodec.encode(message)
  def encode(message), do: {:error, {:unknown_outbound, elem(message, 0)}}

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
  def send_raw(%__MODULE__{transport: :quic, ref: {owner_pid, identity}}, payload)
      when is_binary(payload) do
    send(owner_pid, {:mmo_voxel_bytes, identity, payload})
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
