defmodule AuthServerTest do
  use ExUnit.Case
  doctest AuthServer

  test "greets the world" do
    assert AuthServer.hello() == :world
  end
end
