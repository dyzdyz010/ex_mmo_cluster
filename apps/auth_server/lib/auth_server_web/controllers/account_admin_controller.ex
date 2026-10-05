defmodule AuthServerWeb.AccountAdminController do
  @moduledoc "全局系统功能：Auth 管理页面；全部操作经同一 Identity 权限边界。"
  use AuthServerWeb,:controller
  alias AuthServer.Identity
  plug :put_layout, false
  plug :put_root_layout, false

  def login_page(conn,_), do: render(conn,:login,error: nil)
  def login(conn,p) do
    case Identity.login(p["email"],p["password"],false) do
      {:ok,s} ->
        case Identity.authenticate(s.access_token) do
          {:ok,%{auth_admin: true}} -> conn |> configure_session(renew: true) |> put_session(:account_access,s.access_token) |> redirect(to: "/admin")
          _ -> Identity.logout(s.access_token); conn |> put_status(403) |> render(:login,error: "没有账号管理权限")
        end
      _ -> conn |> put_status(401) |> render(:login,error: "登录失败，请检查邮箱和密码")
    end
  end
  def logout(conn,_) do
    Identity.logout(get_session(conn,:account_access))
    conn |> configure_session(drop: true) |> redirect(to: "/admin/login")
  end
  def index(conn,p), do: page(conn,p,nil,[])
  def policy(conn,p), do: change(conn,:policy,p["invite_required"]=="true")
  def create(conn,p) do
    count=integer(p["count"])
    expiry=if p["days"] in [nil,""],do: nil,else: Identity.now()+integer(p["days"])*86400
    case Identity.administer(get_session(conn,:account_access),:generate,{count,p["batch"] || "",expiry}) do
      {:ok,codes} -> page(conn,%{},"请现在复制这些邀请码；关闭后无法重新查看原码。",codes)
      error -> denied_or_page(conn,error)
    end
  end
  def delete(conn,%{"id"=>id}), do: change(conn,:delete,id)
  def revoke(conn,%{"id"=>id}), do: change(conn,:revoke,id)
  defp change(conn,op,args) do
    case Identity.administer(get_session(conn,:account_access),op,args) do
      :ok -> redirect(conn,to: "/admin")
      error -> denied_or_page(conn,error)
    end
  end
  defp page(conn,p,message,codes) do
    case Identity.administer(get_session(conn,:account_access),:list,AuthServerWeb.AccountController.filters(p)) do
      {:ok,invites} -> render(conn,:index,invites: invites,policy: Identity.registration_policy(),message: message,codes: codes)
      _ -> conn |> configure_session(drop: true) |> redirect(to: "/admin/login")
    end
  end
  defp denied_or_page(conn,{:error,r}) when r in [:forbidden,:invalid_session], do: conn |> configure_session(drop: true) |> redirect(to: "/admin/login")
  defp denied_or_page(conn,{:error,r}), do: page(put_status(conn,400),%{},"操作失败：#{r}",[])
  defp integer(v) when is_binary(v) do
    case Integer.parse(v) do
      {n,""}->n
      _->0
    end
  end
  defp integer(_),do: 0
end
