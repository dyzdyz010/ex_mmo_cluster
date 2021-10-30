defmodule AgentServerTest do
  use ExUnit.Case
  doctest AgentServer

  test "greets the world" do
    assert AgentServer.hello() == :world
  end
end
