defmodule DataStoreTest do
  use ExUnit.Case
  doctest DataStore

  test "greets the world" do
    assert DataStore.hello() == :world
  end
end
