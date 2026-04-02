defmodule DataService.PasswordTest do
  use ExUnit.Case, async: true

  alias DataService.Password

  test "hash_password/1 returns a stable hash for its generated salt" do
    {:ok, hashed_password, salt} = Password.hash_password("secret-password")

    assert is_binary(hashed_password)
    assert is_binary(salt)
    assert hashed_password == Password.hash_password("secret-password", salt)
  end

  test "verify_password/3 matches the original password only" do
    {:ok, hashed_password, salt} = Password.hash_password("secret-password")

    assert Password.verify_password("secret-password", hashed_password, salt)
    refute Password.verify_password("wrong-password", hashed_password, salt)
  end
end
