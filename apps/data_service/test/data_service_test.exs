defmodule DataServiceTest do
  use ExUnit.Case
  doctest DataService

  test "greets the world" do
    assert DataService.hello() == :world
  end
end
