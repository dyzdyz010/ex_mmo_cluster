defmodule DataInitTest do
  use ExUnit.Case
  doctest DataInit

  test "exports the database bootstrap functions" do
    assert function_exported?(DataInit, :create_database, 0)
    assert function_exported?(DataInit, :copy_database, 2)
  end
end
