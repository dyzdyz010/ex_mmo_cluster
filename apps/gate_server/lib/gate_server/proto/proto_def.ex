defmodule GateServer.Proto.ProtoDef do
  use Protox, files: [
    "./priv/proto/Packet.proto",
    "./priv/proto/Heartbeat.proto",
    "./priv/proto/AuthRequest.proto",
    "./priv/proto/EntityAction.proto",
    "./priv/proto/ServerResponse.proto",
    "./priv/proto/Reply.proto",
    "./priv/proto/Types.proto",
    "./priv/proto/BroadcastPlayerAction.proto",
  ]
end
