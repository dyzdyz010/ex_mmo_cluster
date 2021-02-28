defmodule ServiceDiscoveryTest do
  use ExUnit.Case
  doctest ServiceDiscovery

  test "greets the world" do
    assert ServiceDiscovery.hello() == :world
  end
end
