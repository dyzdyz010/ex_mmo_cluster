defmodule AgentManagerTest do
  use ExUnit.Case
  doctest AgentManager

  test "greets the world" do
    assert AgentManager.hello() == :world
  end
end
