defmodule AuthServerWeb.AccountController do
  @moduledoc "全局系统功能：账号 API；公开输入在 Auth 边界验证，日志不包含凭据。"
  use AuthServerWeb, :controller
  alias AuthServer.Identity

  def policy(conn,_), do: json(conn,Identity.registration_policy())
  def session(conn,_) do
    case Identity.authenticate(token(conn)) do
      {:ok,c} -> json(conn,%{account_id: Integer.to_string(c.account_id),expires_at: c.expires_at})
      error -> respond(conn,error)
    end
  end
  def registration_email(conn,p), do: respond(conn,Identity.send_registration_email(p["email"],p["invite"],source(conn)))
  def claim_email(conn,p), do: respond(conn,Identity.send_claim_email(p["email"],p["legacy_code"],source(conn)))
  def claim(conn,p), do: respond(conn,Identity.claim_legacy(p["email"],p["password"],p["code"],p["legacy_code"]))
  def register(conn,p) do
    case Identity.register(p["email"],p["password"],p["code"],p["invite"]) do
      {:ok,a} -> conn |> put_status(201) |> json(%{account_id: Integer.to_string(a.id)})
      error -> respond(conn,error)
    end
  end
  def login(conn,p), do: respond(conn,Identity.login(p["email"],p["password"],p["remember"] == true,source: source(conn)))
  def refresh(conn,p), do: respond(conn,Identity.refresh(p["refresh_token"]))
  def logout(conn,_), do: respond(conn,Identity.logout(token(conn)))
  def logout_all(conn,_), do: respond(conn,Identity.logout(token(conn),true))
  def forgot_password(conn,p),do: respond(conn,Identity.forgot_password(p["email"],source(conn)))
  def reset_password(conn,p),do: respond(conn,Identity.reset_password(p["email"],p["code"],p["password"]))
  def change_password(conn,p),do: respond(conn,Identity.change_password(token(conn),p["current_password"],p["password"]))
  def game_ticket(conn,p) do
    case Application.get_env(:gate_server,:quic) do
      nil -> respond(conn,{:error,:game_unavailable})
      deployment -> respond(conn,Identity.game_ticket(token(conn),p["scene_id"],Keyword.fetch!(deployment,:hello)))
    end
  end
  def admin_policy(conn,p), do: respond(conn,Identity.administer(token(conn),:policy,p["invite_required"]))
  def invite_list(conn,p), do: respond(conn,Identity.administer(token(conn),:list,filters(p)))
  def invite_create(conn,p) do
    case Identity.administer(token(conn),:generate,{p["count"],p["batch"] || "",p["expires_at"]}) do
      {:ok,invites} -> conn |> put_status(201) |> json(%{invites: invites})
      error -> respond(conn,error)
    end
  end
  def invite_delete(conn,%{"id"=>id}), do: respond(conn,Identity.administer(token(conn),:delete,id))
  def invite_revoke(conn,%{"id"=>id}), do: respond(conn,Identity.administer(token(conn),:revoke,id))
  @doc false
  def token(conn) do
    case get_req_header(conn,"authorization") do
      ["Bearer "<>value] -> value
      _ -> nil
    end
  end
  @doc false
  def respond(conn,:ok), do: json(conn,%{ok: true})
  def respond(conn,{:ok,data}) when is_list(data), do: json(conn,%{invites: Enum.map(data,fn row -> Map.update(row,:used_by,nil,fn id -> if id, do: Integer.to_string(id) end) end)})
  def respond(conn,{:ok,data}), do: json(conn,data)
  def respond(conn,{:error,reason}) do
    status=case reason do
      :invalid_session -> 401
      :invalid_credentials -> 401
      :forbidden -> 403
      :account_disabled -> 403
      :rate_limited -> 429
      :not_found -> 404
      :mail_unavailable -> 503
      :game_unavailable -> 503
      _ -> 400
    end
    conn |> put_status(status) |> json(%{error: reason})
  end
  @doc false
  def source(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
  @doc false
  def filters(p), do: %{include_deleted: p["include_deleted"] in [true,"true"], search: text(p["search"]), offset: offset(p["offset"])}
  defp text(s) when is_binary(s) and byte_size(s)<=160, do: s
  defp text(_), do: nil
  defp offset(s) when is_binary(s) do
    case Integer.parse(s) do
      {n,""} when n>=0 -> n
      _ -> 0
    end
  end
  defp offset(_), do: 0
end
