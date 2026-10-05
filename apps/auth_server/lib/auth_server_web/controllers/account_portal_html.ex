defmodule AuthServerWeb.AccountPortalHTML do
  @moduledoc "全局系统功能：玩家账号中心，输入由 HEEx 转义，密码与邮件证明不回显。"
  use AuthServerWeb, :html
  embed_templates "account_portal_html/*"
end
