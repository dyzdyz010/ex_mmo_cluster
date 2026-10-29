defmodule AuthServerWeb.AccountControllerTest do
  use AuthServerWeb.ConnCase, async: false
  alias AuthServer.Admin
  Code.require_file("../../../../data_service/test/support/database.exs",__DIR__)

  setup_all do
    MmoTest.Database.start!()
    {:ok,_} = Application.ensure_all_started(:auth_server)
    :ok
  end
  setup do
    Application.put_env(:auth_server,:mail_adapter,AuthServer.TestMailer)
    Application.put_env(:auth_server,:test_mail_recipient,self())
    old = Application.get_env(:auth_server,:playtest_access_file)
    Application.put_env(:auth_server,:playtest_access_file,"does-not-authorize-new-routes.json")
    on_exit(fn ->
      Application.delete_env(:auth_server,:mail_adapter)
      Application.delete_env(:auth_server,:test_mail_recipient)
      Application.put_env(:auth_server,:playtest_access_file,old)
    end)
    %{email: "http-#{System.unique_integer([:positive])}@example.test", password: "correct horse battery staple!"}
  end
  defp request(path,params,token \\ nil) do
    conn = build_conn() |> put_req_header("content-type","application/json")
    conn = if token, do: put_req_header(conn,"authorization","Bearer " <> token), else: conn
    post(conn,path,Jason.encode!(params))
  end
  defp register(c) do
    {:ok,[invite]}=Admin.generate_invites(1,"http",nil)
    assert %{"ok"=>true}=request("/account/registration-email",%{email: c.email,invite: invite.code}) |> json_response(200)
    assert_receive {:account_mail,email,:registration,code}
    assert email == c.email
    assert %{"account_id"=>id}=request("/account/register",%{email: c.email,password: c.password,code: code,invite: invite.code}) |> json_response(201)
    assert is_binary(id)
    request("/account/login",%{email: c.email,password: c.password}) |> json_response(200)
  end
  test "real HTTP register/login, admin permission, revoke, and no legacy route bypass", c do
    session=register(c)
    assert %{"error"=>"forbidden"}=request("/account/admin/policy",%{invite_required: false},session["access_token"]) |> json_response(403)
    :ok=Admin.grant(c.email)
    assert %{"ok"=>true}=request("/account/admin/policy",%{invite_required: true},session["access_token"]) |> json_response(200)
    assert %{"invites"=>[%{"code"=>code}]}=request("/account/admin/invites",%{count: 1,batch: "via-admin"},session["access_token"]) |> json_response(201)
    assert byte_size(code)==5
    assert code =~ ~r/[A-Z]/ and code =~ ~r/[2-9]/
    assert %{"ok"=>true}=request("/account/logout",%{},session["access_token"]) |> json_response(200)
    assert %{"error"=>"invalid_session"}=request("/account/admin/invites",%{count: 1},session["access_token"]) |> json_response(401)
  end
  test "admin generated invitations remain fully visible after revisiting and searching", c do
    register(c)
    :ok = Admin.grant(c.email)
    conn = post(build_conn(), "/admin/login", %{email: c.email, password: c.password})
    assert redirected_to(conn) == "/admin"
    batch = "visible-#{System.unique_integer([:positive])}"
    conn = recycle(conn) |> post("/admin/invites", %{count: "1", batch: batch, max_uses: "7"})
    assert html_response(conn, 200)
    [invite] = Admin.list_invites(%{search: batch})
    [_, code] = Regex.run(~r/<li title="[^"]+">([A-HJ-NP-Z2-9]{5})<\/li>/, conn.resp_body)
    assert invite.hint == code
    assert invite.max_uses == 7
    body = recycle(conn) |> get("/admin", %{search: code}) |> html_response(200)
    assert body =~ ~s(<span class="ac-code">#{code}</span>)
    refute body =~ "列表仅保留掩码"
    assert body =~ "0 / 7 人"
    conn = recycle(conn) |> post("/admin/invites/#{invite.id}/limit", %{max_uses: "12"})
    assert redirected_to(conn) == "/admin"
    assert recycle(conn) |> get("/admin", %{search: code}) |> html_response(200) =~ "0 / 12 人"
    for suffix <- ["first", "second"] do
      params = %{email: "#{suffix}-#{c.email}", password: c.password, invite: code}
      assert post(build_conn(), "/auth/registration-email", params) |> html_response(200) =~ "验证邮件已发送"
      assert_receive {:account_mail, _, :registration, verification}
      assert post(build_conn(), "/auth/register", Map.put(params, :code, verification)) |> redirected_to() == "/auth/login"
    end
    body = recycle(conn) |> get("/admin", %{search: code}) |> html_response(200)
    assert body =~ "2 / 12 人"
    assert body =~ "可使用"
    assert body =~ ~s(action="/admin/invites/#{invite.id}/revoke")
    rejected = recycle(conn) |> post("/admin/invites/#{invite.id}/limit", %{max_uses: "1"})
    assert html_response(rejected, 400) =~ "人数上限不能低于已注册人数"
  end

  test "unauthenticated game resources and admin lists reject access" do
    assert %{"error"=>"invalid_session"}=request("/game/regions",%{}) |> json_response(401)
    assert build_conn() |> get("/account/admin/invites") |> json_response(401) == %{"error"=>"invalid_session"}
    conn=build_conn() |> get("/admin")
    assert redirected_to(conn) == "/admin/login"
    assert build_conn() |> get("/admin/login") |> html_response(200) =~ "管理员登录"
  end
end
