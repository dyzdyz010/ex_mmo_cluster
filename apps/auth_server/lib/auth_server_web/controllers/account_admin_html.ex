defmodule AuthServerWeb.AccountAdminHTML do
  @moduledoc "全局系统功能：邀请码后台 HTML；数据保持 HEEx 默认转义。"
  use AuthServerWeb,:html
  embed_templates "account_admin_html/*"

  def state(invite) do
    cond do
      invite.deleted_at -> "已删除"
      invite.used_at -> "已使用"
      invite.revoked_at -> "已停用"
      invite.expires_at && invite.expires_at <= AuthServer.Identity.now() -> "已过期"
      true -> "未使用"
    end
  end
  def time(nil),do: "—"
  def time(value),do: value |> DateTime.from_unix!() |> DateTime.to_iso8601()
end
