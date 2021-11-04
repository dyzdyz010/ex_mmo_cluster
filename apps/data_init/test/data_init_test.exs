defmodule DataInitTest do
  use ExUnit.Case
  doctest DataInit

  test "greets the world" do
    assert DataInit.hello() == :world
  end
end
