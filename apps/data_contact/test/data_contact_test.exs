defmodule DataContactTest do
  use ExUnit.Case
  doctest DataContact

  test "greets the world" do
    assert DataContact.hello() == :world
  end
end
