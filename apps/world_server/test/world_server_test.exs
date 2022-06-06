defmodule WorldServerTest do
  use ExUnit.Case
  doctest WorldServer

  test "greets the world" do
    assert WorldServer.hello() == :world
  end
end
