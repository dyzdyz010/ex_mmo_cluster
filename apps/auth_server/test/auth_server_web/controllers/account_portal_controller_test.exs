defmodule AuthServerWeb.AccountPortalControllerTest do
  use AuthServerWeb.ConnCase, async: false
  alias AuthServer.{Admin, Identity}
  Code.require_file("../../../../data_service/test/support/database.exs", __DIR__)

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
    %{email: "portal-#{System.unique_integer([:positive])}@example.test", password: "portal horse battery staple!"}
  end

  test "browser registration creates the same identity used by game login", c do
    :ok = Admin.set_invite_required(true)
    {:ok, [invite]} = Admin.generate_invites(1, "portal", nil)
    assert build_conn() |> get("/auth/register") |> html_response(200) =~ "邀请码"
    params = %{email: c.email, password: c.password, invite: invite.code}
    conn = post(build_conn(), "/auth/registration-email", params)
    assert html_response(conn, 200) =~ "验证邮件已发送"
    # 发信后进入第二步，重发按钮按服务端每邮箱 60 秒限制冷却。
    assert conn.resp_body =~ ~s(data-cooldown="60")
    refute conn.resp_body =~ c.password
    assert_receive {:account_mail, email, :registration, code}
    assert email == c.email
    conn = post(build_conn(), "/auth/register", Map.put(params, :code, code))
    assert redirected_to(conn) == "/auth/login"
    {:ok, game} = Identity.login(c.email, c.password, false)
    conn = post(build_conn(), "/auth/login", %{email: c.email, password: c.password})
    assert redirected_to(conn) == "/auth"
    conn = recycle(conn) |> get("/auth")
    assert html_response(conn, 200) =~ game.account_id
    assert conn.resp_body =~ c.email
    # 已登录：登录／注册页回到账号页，其他页面顶栏显示当前账号与退出，而不是登录／注册入口。
    assert recycle(conn) |> get("/auth/login") |> redirected_to() == "/auth"
    assert recycle(conn) |> get("/auth/register") |> redirected_to() == "/auth"
    signed_in = recycle(conn) |> get("/auth/forgot") |> html_response(200)
    assert signed_in =~ c.email
    assert signed_in =~ ~s(action="/auth/logout")
    refute signed_in =~ ~s(href="/auth/register")
    conn = recycle(conn) |> post("/auth/change-password", %{current_password: "incorrect", password: "replacement horse battery staple!"})
    assert html_response(conn, 400) =~ "当前密码错误"
    assert {:ok, _} = Identity.authenticate(game.access_token)
    conn = recycle(conn) |> post("/auth/change-password", %{current_password: c.password, password: "replacement horse battery staple!"})
    assert redirected_to(conn) == "/auth/login"
    assert {:error, :invalid_session} = Identity.authenticate(game.access_token)
    assert {:ok, replacement} = Identity.login(c.email, "replacement horse battery staple!", false)
    assert replacement.cid == game.cid
  end

  test "web legacy claim accepts the full email proof and keeps the original character", c do
    username = "portal_old_#{System.unique_integer([:positive])}"
    {:ok, %{account: old, character: character}} = AuthServer.Accounts.upsert_dev(username)
    legacy = Identity.random_token()
    :ok = DataService.AccountStore.import_legacy([{Identity.digest(legacy), username}], Identity.now())
    params = %{email: c.email, password: c.password, legacy_code: legacy}
    conn = post(build_conn(), "/auth/claim-email", params)
    body = html_response(conn, 200)
    assert body =~ "认领验证邮件已发送"
    refute body =~ legacy
    refute body =~ c.password
    assert_receive {:account_mail, _, :legacy_claim, code}
    assert byte_size(code) > 6
    assert body =~ ~s(id="code" name="code" autocomplete="one-time-code" maxlength="128")
    conn = post(build_conn(), "/auth/claim", Map.put(params, :code, code))
    assert redirected_to(conn) == "/auth/login"
    {:ok, session} = Identity.login(c.email, c.password, false)
    assert session.account_id == Integer.to_string(old.id)
    assert session.cid == Integer.to_string(character.id)
    assert post(build_conn(), "/auth/claim", Map.put(params, :code, code)) |> html_response(400) =~ "旧邀请码无法认领"
  end

  test "browser pages over the per-source limit get an account page while the API keeps JSON" do
    # 独立来源地址，避免与其他用例共享 60 次／分钟的限流额度。
    conn = fn -> %{build_conn() | remote_ip: {198, 51, 100, 7}} end
    for _ <- 1..60, do: assert(conn.() |> get("/auth/login") |> html_response(200))
    limited = conn.() |> get("/auth/login")
    assert html_response(limited, 429) =~ "操作过于频繁"
    assert get_resp_header(limited, "retry-after") == ["60"]
    assert conn.() |> post("/account/login", %{}) |> json_response(429) == %{"error" => "rate_limited"}
  end

  test "account management requires a live session and public pages do not expose credentials" do
    assert build_conn() |> get("/auth") |> redirected_to() == "/auth/login"
    assert build_conn() |> post("/auth/logout-all", %{}) |> redirected_to() == "/auth/login"
    for page <- ["login", "register", "forgot", "reset", "claim"] do
      body = build_conn() |> get("/auth/" <> page) |> html_response(200)
      assert body =~ "_csrf_token"
      assert body =~ ~s(href="/auth/register")
      refute body =~ ~s(action="/auth/logout")
      refute body =~ "access_token"
    end
  end
end
