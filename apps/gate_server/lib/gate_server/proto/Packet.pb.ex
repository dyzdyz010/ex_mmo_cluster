defmodule Packet do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.10.0", syntax: :proto3

  oneof :payload, 0

  field :id, 1, type: :int32
  field :ping, 2, type: Ping, oneof: 0
  field :authrequest, 3, type: AuthRequest, oneof: 0
end
