defmodule GateServer.VoximAuthBoundaryTest do
  use ExUnit.Case, async: false
  alias GateServer.Session.Auth
  alias AuthServer.AuthWorker

  # Only service discovery is local test plumbing. Gate calls the real AuthWorker
  # through its normal RPC boundary; signing/verification use the real Endpoint.
  defmodule AuthNode do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: GateServer.Interface)
    def init(nil), do: {:ok, nil}
    def handle_call(:auth_server, _, state), do: {:reply, node(), state}
  end

  test "Gate rejects an expired signed token and tampering while preserving exact cid ownership" do
    {:ok, _} = Application.ensure_all_started(:phoenix)
    start_supervised!({AuthServerWeb.Endpoint,
      server: false, secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64)),
      cache_static_manifest: nil, pubsub_server: AuthServer.PubSub})
    start_supervised!(AuthNode)

    claims = AuthWorker.build_session_claims("m1-isolated-auth", cid: 101)
    token = AuthWorker.issue_token(claims)
    expired = Phoenix.Token.sign(AuthServerWeb.Endpoint, "ingame-auth", claims,
      signed_at: System.system_time(:second) - 86_401)
    assert {:ok, ^claims} = Auth.verify_token(token)
    assert {:error, :mismatch} = Auth.verify_token(expired)
    assert {:error, :mismatch} = Auth.verify_token(token <> "tampered")
    assert :ok = Auth.validate_username(claims, "m1-isolated-auth")
    assert {:error, :username_mismatch} = Auth.validate_username(claims, "another-account")
    assert :ok = Auth.authorize_cid(claims, 101)
    assert {:error, :cid_mismatch} = Auth.authorize_cid(claims, 202)
    IO.puts("M1_AUTH_NEGATIVE " <> Jason.encode!(%{
      valid_signature_accepted: true, expired_signed_token_rejected: true,
      tampered_token_rejected: true, wrong_username_rejected: true, wrong_cid_rejected: true,
      gate_auth_and_auth_worker: "production", discovery: "isolated_local_node",
      http_quic_or_live_database: false, tokens_logged: false
    }))
  end
end
