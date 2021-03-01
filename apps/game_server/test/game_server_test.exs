defmodule GameServerTest do
  use ExUnit.Case
  doctest GameServer

  test "greets the world" do
    assert GameServer.hello() == :world
  end
end
