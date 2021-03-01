defmodule GameServerManagerTest do
  use ExUnit.Case
  doctest GameServerManager

  test "greets the world" do
    assert GameServerManager.hello() == :world
  end
end
