defmodule BeaconServerTest do
  use ExUnit.Case
  doctest BeaconServer

  test "greets the world" do
    assert BeaconServer.hello() == :world
  end
end
