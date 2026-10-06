defmodule AuthServerWeb.AccountPortalHTML do
  @moduledoc "全局系统功能：玩家账号中心，输入由 HEEx 转义，密码与邮件证明不回显。"
  use AuthServerWeb, :html
  alias AuthServerWeb.AccountUI, as: UI
  embed_templates "account_portal_html/*"

  @doc "顶栏导航随登录状态变化；找回密码入口在登录表单内。"
  def nav(nil), do: [{"登录", "/auth/login"}, {"注册", "/auth/register"}]
  def nav(%{admin: true}), do: [{"账号管理", "/auth"}, {"邀请码管理", "/admin"}]
  def nav(_viewer), do: [{"账号管理", "/auth"}]

  def current(:manage), do: "/auth"
  def current(:login), do: "/auth/login"
  def current(:register), do: "/auth/register"
  def current(_screen), do: nil

  def title(:manage), do: "账号管理"
  def title(:login), do: "登录"
  def title(:register), do: "注册"
  def title(:forgot), do: "找回密码"
  def title(:reset), do: "重置密码"
  def title(:claim), do: "绑定原角色"

  @doc "来源请求过多时的网页（由限流 plug 直接发送，不经控制器）。"
  def rate_limited_page do
    assigns = %{}

    ~H"""
    <UI.page title="请稍后再试" nav={nav(nil)}>
      <div class="sk-container ac-w-solo">
        <section class="ac-card ac-card--magenta" aria-labelledby="screen-title">
          <p class="ac-eyebrow"><span class="ac-dot ac-dot--magenta"></span>Too many requests</p>
          <h1 id="screen-title" class="ac-title">请稍后再试</h1>
          <UI.notice notice={{:error, "操作过于频繁，请稍后再试。"}} />
          <p class="ac-text">为保护账号安全，同一网络一分钟内的请求次数有限。请约一分钟后返回上一页重试。</p>
          <div class="ac-card-foot"><a href="/auth/login">返回登录</a></div>
        </section>
      </div>
    </UI.page>
    """
    |> Phoenix.HTML.Safe.to_iodata()
  end
end
