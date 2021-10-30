defmodule Ping do
  @moduledoc false
  use Protobuf, syntax: :proto3

  @type t :: %__MODULE__{
          timestamp: String.t()
        }

  defstruct [:timestamp]

  field :timestamp, 1, type: :string
end
