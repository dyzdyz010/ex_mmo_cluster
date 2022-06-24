defmodule AuthRequest do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.10.0", syntax: :proto3

  field :username, 1, type: :string
  field :code, 3, type: :string
end
