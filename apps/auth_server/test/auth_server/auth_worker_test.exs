defmodule AuthServer.AuthWorkerTest do
  use ExUnit.Case, async: true

  test "issue_token and verify_token roundtrip claims" do
    claims = %{"username" => "player1", "source" => "ingame_login"}

    token = AuthServer.AuthWorker.issue_token(claims)

    assert is_binary(token)
    assert {:ok, ^claims} = AuthServer.AuthWorker.verify_token(token)
  end

  test "verify_token rejects invalid tokens" do
    assert {:error, :mismatch} = AuthServer.AuthWorker.verify_token("not-a-real-token")
  end

  test "build_session_claims adds session_id and preserves optional cid restrictions" do
    claims =
      AuthServer.AuthWorker.build_session_claims("player1",
        source: "ingame_login",
        cid: 42,
        allowed_cids: ["42", 43]
      )

    assert claims["username"] == "player1"
    assert claims["source"] == "ingame_login"
    assert is_binary(claims["session_id"])
    assert claims["cid"] == 42
    assert claims["allowed_cids"] == [42, 43]
  end

  test "validate_username rejects mismatched usernames" do
    claims = %{"username" => "player1"}

    assert :ok = AuthServer.AuthWorker.validate_username(claims, "player1")

    assert {:error, :username_mismatch} =
             AuthServer.AuthWorker.validate_username(claims, "player2")
  end

  test "validate_cid only rejects when claims explicitly constrain cid" do
    unrestricted = %{"username" => "player1"}
    restricted = %{"username" => "player1", "cid" => 42}
    list_restricted = %{"username" => "player1", "allowed_cids" => [42, "43"]}

    assert :ok = AuthServer.AuthWorker.validate_cid(unrestricted, 99)
    assert :ok = AuthServer.AuthWorker.validate_cid(restricted, 42)
    assert {:error, :cid_mismatch} = AuthServer.AuthWorker.validate_cid(restricted, 99)
    assert :ok = AuthServer.AuthWorker.validate_cid(list_restricted, 43)
    assert {:error, :cid_mismatch} = AuthServer.AuthWorker.validate_cid(list_restricted, 99)
  end
end
