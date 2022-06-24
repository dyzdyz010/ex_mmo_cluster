defmodule ServerResponse.Status do
  @moduledoc false
  use Protobuf, enum: true, protoc_gen_elixir_version: "0.10.0", syntax: :proto3

  field :OK, 0
  field :ERROR, 1
end
defmodule ServerResponse do
  @moduledoc false
  use Protobuf, protoc_gen_elixir_version: "0.10.0", syntax: :proto3

  oneof :payload, 0

  field :status, 1, type: ServerResponse.Status, enum: true
  field :message, 4, type: :string, oneof: 0
end
