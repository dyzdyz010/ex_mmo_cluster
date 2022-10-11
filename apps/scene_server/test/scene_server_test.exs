defmodule SceneServerTest do
  use ExUnit.Case
  doctest SceneServer

  test "greets the world" do
    assert SceneServer.hello() == :world
  end
end
