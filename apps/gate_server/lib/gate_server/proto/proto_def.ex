defmodule GateServer.Proto.ProtoDef do
  use Protox, files: [
    "./priv/proto/Packet.proto",
    "./priv/proto/Heartbeat.proto",
    "./priv/proto/AuthRequest.proto",
    "./priv/proto/ServerResponse.proto",
  ]
end