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
    assert byte_size(code)>=26
    assert %{"ok"=>true}=request("/account/logout",%{},session["access_token"]) |> json_response(200)
    assert %{"error"=>"invalid_session"}=request("/account/admin/invites",%{count: 1},session["access_token"]) |> json_response(401)
  end
  test "unauthenticated game resources and admin lists reject access" do
    assert %{"error"=>"invalid_session"}=request("/game/regions",%{}) |> json_response(401)
    assert build_conn() |> get("/account/admin/invites") |> json_response(401) == %{"error"=>"invalid_session"}
    conn=build_conn() |> get("/admin")
    assert redirected_to(conn) == "/admin/login"
    assert build_conn() |> get("/admin/login") |> html_response(200) =~ "管理员登录"
  end
end
