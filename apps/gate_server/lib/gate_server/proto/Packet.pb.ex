defmodule Packet do
  @moduledoc false
  use Protobuf, syntax: :proto3

  @type t :: %__MODULE__{
          payload: {atom, any},
          id: integer
        }

  defstruct [:payload, :id]

  oneof :payload, 0
  field :id, 1, type: :int32
  field :ping, 2, type: Ping, oneof: 0
  field :credentials, 3, type: Credentials, oneof: 0
end
