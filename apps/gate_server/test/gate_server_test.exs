defmodule GateServerTest do
  use ExUnit.Case
  doctest GateServer

  test "greets the world" do
    assert GateServer.hello() == :world
  end
end
