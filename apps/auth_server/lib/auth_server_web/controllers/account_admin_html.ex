defmodule AuthServerWeb.AccountAdminHTML do
  @moduledoc "全局系统功能：邀请码后台 HTML；数据保持 HEEx 默认转义。"
  use AuthServerWeb,:html
  alias AuthServerWeb.AccountUI, as: UI
  embed_templates "account_admin_html/*"

  # 与 DataService.AccountStore 邀请码列表的 LIMIT 一致。
  @page_size 100
  def page_size, do: @page_size
  def nav, do: [{"账号管理","/auth"},{"邀请码管理","/admin"}]

  def state(invite) do
    cond do
      invite.deleted_at -> "已删除"
      invite.used_at -> "已使用"
      invite.revoked_at -> "已停用"
      invite.expires_at && invite.expires_at <= AuthServer.Identity.now() -> "已过期"
      true -> "未使用"
    end
  end
  def tone("未使用"),do: "cyan"
  def tone("已使用"),do: "positive"
  def tone("已停用"),do: "gold"
  def tone(_),do: "dim"

  attr :at, :integer, default: nil
  @doc "服务端输出 UTC，浏览器脚本再换算为本地时区。"
  def time(%{at: nil}=assigns), do: ~H"—"
  def time(assigns) do
    assigns=assign(assigns,:value,DateTime.from_unix!(assigns.at))
    ~H"""
    <time datetime={DateTime.to_iso8601(@value)}>{Calendar.strftime(@value,"%Y-%m-%d %H:%M UTC")}</time>
    """
  end

  def page_link(filters,offset) do
    query=%{"offset"=>offset} |> put_if("search",filters.search) |> put_if("include_deleted",filters.include_deleted && "true")
    "/admin?" <> URI.encode_query(query)
  end
  defp put_if(map,_,v) when v in [nil,false,""], do: map
  defp put_if(map,k,v), do: Map.put(map,k,v)
end
