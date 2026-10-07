defmodule AuthServer.IdentityTest do
  use ExUnit.Case, async: false

  alias AuthServer.Identity

  defmodule KilledConnection do
    @moduledoc "Test-only: reproduces the real QUIC owner exiting :killed during linked-worker cleanup."
    use GenServer
    def start, do: GenServer.start(__MODULE__, nil)
    def init(nil), do: {:ok, nil}
    def terminate(_, _), do: Process.exit(self(), :kill)
  end

  Code.require_file("../../../data_service/test/support/database.exs", __DIR__)

  setup_all do
    MmoTest.Database.start!()
    {:ok, _} = Application.ensure_all_started(:auth_server)
    :ok
  end

  setup do
    Application.put_env(:auth_server, :mail_adapter, AuthServer.TestMailer)
    Application.put_env(:auth_server, :test_mail_recipient, self())
    on_exit(fn ->
      Application.delete_env(:auth_server, :mail_adapter)
      Application.delete_env(:auth_server, :test_mail_recipient)
    end)
    suffix = System.unique_integer([:positive])
    email = "account-#{suffix}@example.test"
    {:ok, [invite]} = AuthServer.Admin.generate_invites(1, "test-#{suffix}", nil)
    %{email: email, invite: invite, password: "a correct long password #{suffix}"}
  end

  defp proof(email, invite) do
    assert :ok = Identity.send_registration_email(email, invite, "127.0.0.1")
    assert_receive {:account_mail, ^email, :registration, code}
    code
  end

  test "legacy ownership claim preserves identity and character and cannot be replayed", c do
    username="old_#{System.unique_integer([:positive])}"
    {:ok,%{account: old,character: character}}=AuthServer.Accounts.upsert_dev(username)
    legacy=Identity.random_token()
    assert :ok=DataService.AccountStore.import_legacy([{Identity.digest(legacy),username}],Identity.now())
    assert :ok=Identity.send_claim_email(c.email,legacy,"local-claim")
    assert_receive {:account_mail,_,:legacy_claim,code}
    assert {:error,:invalid_legacy_claim}=Identity.claim_legacy(c.email,c.password,code,c.invite.code)
    assert :ok=Identity.claim_legacy(c.email,c.password,code,legacy)
    assert {:ok,session}=Identity.login(c.email,c.password,false)
    assert session.account_id==Integer.to_string(old.id)
    assert session.cid==Integer.to_string(character.id)
    {_,after_character}=DataService.AccountStore.account_with_character(old.id)
    assert after_character==character
    assert {:error,:invalid_legacy_claim}=Identity.claim_legacy(c.email,c.password,code,legacy)
  end

  test "legacy claim accepts a short code pasted with whitespace or typed in lower case", c do
    username="old_#{System.unique_integer([:positive])}"
    {:ok,%{account: old}}=AuthServer.Accounts.upsert_dev(username)
    assert :ok=DataService.AccountStore.import_legacy([{Identity.digest("K7QX2"),username}],Identity.now())
    assert :ok=Identity.send_claim_email(c.email," k7qx2
","local-claim-case")
    assert_receive {:account_mail,_,:legacy_claim,code}
    assert :ok=Identity.claim_legacy(c.email,c.password,code,"k7qx2 ")
    assert {:ok,session}=Identity.login(c.email,c.password,false)
    assert session.account_id==Integer.to_string(old.id)
  end

  test "register consumes one invite and records the verified account", c do
    invite = String.downcase(c.invite.code)
    code = proof(c.email, invite)
    assert {:ok, account} = Identity.register(c.email, c.password, code, invite)
    assert account.email == c.email
    assert {:ok, session} = Identity.login(c.email, c.password, false)
    assert session.account_id == Integer.to_string(account.id)
    [record] = AuthServer.Admin.list_invites(%{id: c.invite.id})
    assert record.used_by == account.id
    assert record.used_at != nil
    refute Map.has_key?(record, :code)
    assert {:error, :invalid_verification} = Identity.register(c.email, c.password, code, c.invite.code)
  end

  test "new invitations are five unambiguous mixed characters and never reveal the full code in history" do
    {:ok, invites} = AuthServer.Admin.generate_invites(100, "short-codes", nil)
    codes = Enum.map(invites, & &1.code)
    assert length(codes) == 100
    assert MapSet.size(MapSet.new(codes)) == 100
    for invite <- invites do
      assert invite.code =~ ~r/\A[A-HJ-NP-Z2-9]{5}\z/
      assert invite.code =~ ~r/[A-Z]/
      assert invite.code =~ ~r/[2-9]/
      assert String.length(invite.hint) == 3
      refute invite.hint =~ invite.code
    end
  end

  test "an invitation digest collision rolls back the entire batch and keeps the original code usable", c do
    fresh = %{id: Ecto.UUID.generate(), digest: Identity.digest(Identity.random_token()), hint: "A…9"}
    duplicate = %{id: Ecto.UUID.generate(), digest: Identity.invite_digest(c.invite.code), hint: "B…8"}
    assert {:error, :invite_collision} = DataService.AccountStore.create_invites([fresh, duplicate], "test", "collision", nil, Identity.now())
    assert [] == AuthServer.Admin.list_invites(%{id: fresh.id})
    assert [] == AuthServer.Admin.list_invites(%{id: duplicate.id})
    assert :ok == DataService.AccountStore.admission(Identity.invite_digest(c.invite.code), Identity.now())
  end

  test "invalid invite does not consume email proof and deleted used invite retains history", c do
    code = proof(c.email, c.invite.code)
    assert {:error, :invalid_invite} = Identity.register(c.email, c.password, code, "wrong")
    assert {:ok, account} = Identity.register(c.email, c.password, code, c.invite.code)
    assert :ok = AuthServer.Admin.delete_invite(c.invite.id)
    [record] = AuthServer.Admin.list_invites(%{id: c.invite.id, include_deleted: true})
    assert record.used_by == account.id
    assert record.deleted_at != nil
    assert {:ok, _} = Identity.login(c.email, c.password, false)
  end

  test "policy at commit rejects an old open form, opening does not consume supplied invite", c do
    :ok = AuthServer.Admin.set_invite_required(false)
    on_exit(fn -> AuthServer.Admin.set_invite_required(true) end)
    code = proof(c.email, nil)
    :ok = AuthServer.Admin.set_invite_required(true)
    assert {:error, :invite_required} = Identity.register(c.email, c.password, code, nil)
    :ok = AuthServer.Admin.set_invite_required(false)
    assert {:ok, _} = Identity.register(c.email, c.password, code, c.invite.code)
    [record] = AuthServer.Admin.list_invites(%{id: c.invite.id})
    assert record.used_by == nil
  end

  test "two verified emails racing for one invite create exactly one account", c do
    other = "other-#{c.email}"
    one = proof(c.email, c.invite.code)
    two = proof(other, c.invite.code)
    results =
      [{c.email, one}, {other, two}]
      |> Enum.map(fn {email, code} -> Task.async(fn -> Identity.register(email, c.password, code, c.invite.code) end) end)
      |> Enum.map(&Task.await(&1, 15_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :invalid_invite})) == 1
  end

  test "refresh rotates and reuse revokes session; ordinary accounts cannot manage invitations", c do
    code = proof(c.email, c.invite.code)
    assert {:ok, _} = Identity.register(c.email, c.password, code, c.invite.code)
    assert {:ok, session} = Identity.login(c.email, c.password, true)
    assert {:ok, _} = Identity.authenticate(session.access_token)
    assert {:error, :forbidden} = Identity.administer(session.access_token, :policy, false)
    assert {:ok, next} = Identity.refresh(session.refresh_token)
    assert next.refresh_token != session.refresh_token
    assert {:error, :invalid_session} = Identity.refresh(session.refresh_token)
    assert {:error, :invalid_session} = Identity.authenticate(next.access_token)
  end

  test "ticket is scene bound and single use, logout closes the registered connection", c do
    code=proof(c.email,c.invite.code)
    {:ok,_}=Identity.register(c.email,c.password,code,c.invite.code)
    {:ok,s}=Identity.login(c.email,c.password,false)
    hello=%MmoContracts.Session.Hello{protocol_version: MmoContracts.Session.Codec.protocol_version(),kernel_id: <<1::256>>,profile_id: <<2::256>>}
    assert {:ok,ticket}=Identity.game_ticket(s.access_token,1,hello)
    assert {:error,:invalid_ticket}=Identity.consume_ticket(ticket.token,String.to_integer(s.cid),s.username,2,hello,self())
    assert {:error,:invalid_ticket}=Identity.consume_ticket(s.access_token,String.to_integer(s.cid),s.username,1,hello,self())
    pid=start_supervised!({Agent,fn -> nil end})
    monitor=Process.monitor(pid)
    assert {:ok,%{account_id: _}}=Identity.consume_ticket(ticket.token,String.to_integer(s.cid),s.username,1,hello,pid)
    assert {:error,:invalid_ticket}=Identity.consume_ticket(ticket.token,String.to_integer(s.cid),s.username,1,hello,pid)
    assert :ok=Identity.logout(s.access_token)
    assert_receive {:DOWN,^monitor,:process,^pid,:normal}
    assert {:error,:invalid_session}=Identity.game_ticket(s.access_token,1,hello)
  end

  test "a killed connection at revocation cannot restart Auth or close another session", c do
    code = proof(c.email, c.invite.code)
    {:ok, _} = Identity.register(c.email, c.password, code, c.invite.code)
    {:ok, one} = Identity.login(c.email, c.password, false)
    {:ok, other} = Identity.login(c.email, c.password, false)
    hello = %MmoContracts.Session.Hello{protocol_version: MmoContracts.Session.Codec.protocol_version(), kernel_id: <<1::256>>, profile_id: <<2::256>>}
    {:ok, killed} = KilledConnection.start()
    survivor = start_supervised!({Agent, fn -> nil end})
    for {session, pid} <- [{one, killed}, {other, survivor}] do
      {:ok, ticket} = Identity.game_ticket(session.access_token, 1, hello)
      assert {:ok, _} = Identity.consume_ticket(ticket.token, String.to_integer(session.cid), session.username, 1, hello, pid)
    end
    owner = Process.whereis(AuthServer.Connections)
    ref = Process.monitor(killed)
    assert :ok = Identity.logout(one.access_token)
    assert_receive {:DOWN, ^ref, :process, ^killed, :killed}
    assert Process.whereis(AuthServer.Connections) == owner
    assert Process.alive?(survivor)
    assert {:ok, _} = Identity.authenticate(other.access_token)
  end

  defmodule CrashingConnection do
    @moduledoc "Test-only: a connection whose cleanup raises while it is being stopped."
    use GenServer
    def start, do: GenServer.start(__MODULE__, nil)
    def init(nil), do: {:ok, nil}
    def terminate(_, _), do: raise("cleanup failed")
  end

  test "a stuck or crashing connection at revocation is forced down without restarting Auth", c do
    code = proof(c.email, c.invite.code)
    {:ok, _} = Identity.register(c.email, c.password, code, c.invite.code)
    {:ok, one} = Identity.login(c.email, c.password, false)
    {:ok, other} = Identity.login(c.email, c.password, false)
    hello = %MmoContracts.Session.Hello{protocol_version: MmoContracts.Session.Codec.protocol_version(), kernel_id: <<1::256>>, profile_id: <<2::256>>}
    # 不处理系统消息的进程模拟卡住的连接：GenServer.stop 会超时。
    stuck = spawn(fn -> receive do: (:never -> :ok) end)
    {:ok, crashing} = CrashingConnection.start()
    survivor = start_supervised!({Agent, fn -> nil end})
    for {session, pid} <- [{one, stuck}, {one, crashing}, {other, survivor}] do
      {:ok, ticket} = Identity.game_ticket(session.access_token, 1, hello)
      assert {:ok, _} = Identity.consume_ticket(ticket.token, String.to_integer(session.cid), session.username, 1, hello, pid)
    end
    owner = Process.whereis(AuthServer.Connections)
    assert :ok = Identity.logout(one.access_token)
    refute Process.alive?(stuck)
    refute Process.alive?(crashing)
    assert Process.whereis(AuthServer.Connections) == owner
    assert Process.alive?(survivor)
  end

  test "failed reset attempts by someone else cannot lock the owner's 256-bit reset code", c do
    code = proof(c.email, c.invite.code)
    {:ok, _} = Identity.register(c.email, c.password, code, c.invite.code)
    assert :ok = Identity.forgot_password(c.email, "owner")
    assert_receive {:account_mail, _, :password_reset, reset}
    for _ <- 1..8, do: assert({:error, :invalid_verification} = Identity.reset_password(c.email, "guess", "an attacker chosen password"))
    assert :ok = Identity.reset_password(c.email, reset, "the owner's new long password")
  end

  test "registering an existing email answers the same and mails the owner a sign-in notice", c do
    # 用已存在的账号邮箱（开发账号），避免与本用例自己发信的每邮箱 60 秒限额冲突。
    {:ok, %{account: existing}} = AuthServer.Accounts.upsert_dev("exists_#{System.unique_integer([:positive])}")
    email = existing.email
    assert :ok = Identity.send_registration_email(email, c.invite.code, "elsewhere")
    assert_receive {:account_mail, ^email, :account_exists, nil}
    refute_received {:account_mail, ^email, :registration, _}
  end

  test "a mistyped invite does not spend the email's one-per-minute mail slot", c do
    assert {:error, :invalid_invite} = Identity.send_registration_email(c.email, "WRONG", "typo")
    assert :ok = Identity.send_registration_email(c.email, c.invite.code, "typo")
    assert_receive {:account_mail, _, :registration, _}
  end

  test "failed logins from one source do not lock the account for another source", c do
    code = proof(c.email, c.invite.code)
    {:ok, _} = Identity.register(c.email, c.password, code, c.invite.code)
    for _ <- 1..10, do: Identity.login(c.email, "a wrong long password guess", false, source: "attacker")
    assert {:error, :rate_limited} = Identity.login(c.email, c.password, false, source: "attacker")
    assert {:ok, session} = Identity.login(c.email, c.password, false, source: "owner")
    # 相对寿命让客户端不依赖本机时钟。
    assert session.access_expires_in in 899..900
    assert {:ok, web} = Identity.login(c.email, c.password, false, source: "owner", web: true)
    assert web.access_expires_in > 86_000
  end

  test "a malformed game ticket request is rejected without claiming the session is invalid", c do
    code = proof(c.email, c.invite.code)
    {:ok, _} = Identity.register(c.email, c.password, code, c.invite.code)
    {:ok, s} = Identity.login(c.email, c.password, false)
    hello = %MmoContracts.Session.Hello{protocol_version: MmoContracts.Session.Codec.protocol_version(), kernel_id: <<1::256>>, profile_id: <<2::256>>}
    assert {:error, :invalid_request} = Identity.game_ticket(s.access_token, "1", hello)
    assert {:error, :invalid_session} = Identity.game_ticket(nil, 1, hello)
  end

  test "password reset invalidates all sessions and proof cannot be reused", c do
    code=proof(c.email,c.invite.code)
    {:ok,_}=Identity.register(c.email,c.password,code,c.invite.code)
    {:ok,s}=Identity.login(c.email,c.password,true)
    assert :ok=Identity.forgot_password(c.email,"reset-source")
    assert_receive {:account_mail,_,:password_reset,reset}
    next="a different long password"
    assert :ok=Identity.reset_password(c.email,reset,next)
    assert {:error,:invalid_session}=Identity.authenticate(s.access_token)
    assert {:error,:invalid_credentials}=Identity.login(c.email,c.password,false)
    assert {:ok,_}=Identity.login(c.email,next,false)
    assert {:error,:invalid_verification}=Identity.reset_password(c.email,reset,c.password)
  end
end
