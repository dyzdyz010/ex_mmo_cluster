defmodule AuthServerWeb.AccountUI do
  @moduledoc """
  全局系统功能：Voxim 账号网页设计系统（玩家账号中心、管理后台、验证邮件共用）。

  token 与 Sköpunarverk landing 仓库 `packages/brand/src/tokens.css` 一致，是本应用唯一色值来源；
  样式见同目录 `account_ui.css`，渐进增强脚本见 `account_ui.js`。Auth 部署只放行
  `/auth`、`/admin` 等路径，因此样式与脚本内联进页面，不经静态资源路由。
  """
  use Phoenix.Component

  @tokens [
    canvas: "#060812", surface: "#101426", "surface-strong": "#0a0d1c", line: "rgba(154, 170, 225, 0.16)",
    text: "#f5f7ff", muted: "#b7bdd2", dim: "#69728f", cyan: "#61d9ff", violet: "#8c7cff",
    magenta: "#ff7bcb", gold: "#ffcc7a", positive: "#79f0cb"
  ]
  @fonts [
    sans: ~s(Inter, "Noto Sans SC", "PingFang SC", "Microsoft YaHei", system-ui, sans-serif),
    display: ~s("Iowan Old Style", "Noto Serif SC", "Songti SC", STSong, serif),
    mono: ~s("SFMono-Regular", Consolas, "Liberation Mono", monospace)
  ]
  @root ":root{" <>
          Enum.map_join(@tokens, &"--sk-color-#{elem(&1, 0)}:#{elem(&1, 1)};") <>
          Enum.map_join(@fonts, &"--sk-font-#{elem(&1, 0)}:#{elem(&1, 1)};") <>
          "--sk-radius-control:0.8rem;--sk-radius-panel:1.5rem;--sk-ease-emphasized:cubic-bezier(0.16,1,0.3,1);" <>
          "--sk-shadow-panel:0 32px 100px rgba(2,4,18,0.6),0 0 60px rgba(97,217,255,0.08);--sk-container:90rem}"

  @css_path Path.join(__DIR__, "account_ui.css")
  @js_path Path.join(__DIR__, "account_ui.js")
  @external_resource @css_path
  @external_resource @js_path
  @style "<style>" <> @root <> File.read!(@css_path) <> "</style>"
  @script "<script>" <> File.read!(@js_path) <> "</script>"
  @favicon "data:image/svg+xml;base64," <>
             Base.encode64(
               ~S|<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><defs><linearGradient id="g" x1="8" y1="8" x2="56" y2="56" gradientUnits="userSpaceOnUse"><stop stop-color="#61d9ff"/><stop offset=".55" stop-color="#8c7cff"/><stop offset="1" stop-color="#ff7bcb"/></linearGradient></defs><path fill="none" stroke="url(#g)" stroke-width="4" d="M32 6 54 19v26L32 58 10 45V19Z"/><path fill="url(#g)" d="m32 17 13 8v15l-13 8-13-8V25Zm0 6-7 4v10l7 4 7-4V27Z"/></svg>|
             )

  @doc "设计 token 色值，供无法使用 CSS 变量的邮件内联样式读取。"
  def color(name), do: Keyword.fetch!(@tokens, name)
  @doc false
  def font(name), do: Keyword.fetch!(@fonts, name)

  attr :title, :string, required: true
  attr :tagline, :string, default: "ACCOUNT"
  attr :home, :string, default: "/auth"
  attr :nav, :list, default: [], doc: "[{文字, 路径}]"
  attr :current, :string, default: nil
  attr :viewer, :map, default: nil, doc: "当前登录者 %{email: …}；nil 表示未登录"
  attr :logout, :string, default: "/auth/logout"
  attr :logout_label, :string, default: "退出登录"
  slot :inner_block, required: true

  @doc "完整页面骨架：品牌页头（按登录状态显示导航与当前账号）、星空背景、页脚。"
  def page(assigns) do
    assigns = assign(assigns, style: Phoenix.HTML.raw(@style), script: Phoenix.HTML.raw(@script), favicon: @favicon)

    ~H"""
    <!DOCTYPE html>
    <html lang="zh-CN">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width,initial-scale=1" />
        <meta name="color-scheme" content="dark" />
        <meta name="theme-color" content="#060812" />
        <meta name="robots" content="noindex" />
        <title>{@title} · Voxim 账号</title>
        <link rel="icon" href={@favicon} />
        {@style}
      </head>
      <body class="sk-shell ac">
        <a class="sk-skip-link" href="#main">跳到正文</a>
        <div class="ac-stars" aria-hidden="true"></div>
        <div class="ac-nebula ac-nebula--violet" aria-hidden="true"></div>
        <div class="ac-nebula ac-nebula--cyan" aria-hidden="true"></div>
        <header class="sk-header">
          <div class="sk-container sk-header__inner">
            <a class="sk-brand" href={@home} aria-label="Voxim 账号首页">
              <span class="sk-brand__mark" aria-hidden="true"></span>
              <span class="sk-brand__copy">
                <span class="sk-brand__name">VOXIM</span>
                <span class="sk-brand__tagline">{@tagline}</span>
              </span>
            </a>
            <div class="ac-header-end">
              <nav :if={@nav != []} class="sk-product-nav" aria-label="账号导航">
                <a :for={{label, href} <- @nav} href={href} aria-current={href == @current && "page"}>{label}</a>
              </nav>
              <div :if={@viewer} class="ac-user">
                <span class="ac-user__email" title={@viewer.email}>{@viewer.email}</span>
                <.form for={%{}} action={@logout}><button class="ac-btn ac-btn--sm">{@logout_label}</button></.form>
              </div>
            </div>
          </div>
        </header>
        <main id="main" class="ac-main">{render_slot(@inner_block)}</main>
        <footer class="sk-footer">
          <div class="sk-container sk-footer__inner">
            <div class="sk-footer__identity">
              <strong>SKÖPUNARVERK</strong>
              <span>让世界被书写，也被运行</span>
            </div>
            <div class="sk-footer__meta">
              <span>VOXIM · 青岚</span>
              <span>ACCOUNT SERVICE</span>
            </div>
          </div>
        </footer>
        {@script}
      </body>
    </html>
    """
  end

  attr :notice, :any, required: true, doc: "nil 或 {:info | :ok | :warn | :error, 文字}"
  attr :role, :string, default: "status"

  @doc "操作结果提示；同一页面只渲染一条，便于读屏与自动化定位。"
  def notice(%{notice: nil} = assigns), do: ~H""

  def notice(assigns) do
    ~H"""
    <p class={"ac-notice ac-notice--#{elem(@notice, 0)}"} role={@role}>{elem(@notice, 1)}</p>
    """
  end

  attr :tone, :string, default: "dim"
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span class={"sk-badge ac-badge ac-badge--#{@tone}"}>{render_slot(@inner_block)}</span>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :autocomplete, :string, required: true
  attr :minlength, :integer, default: nil
  attr :autofocus, :boolean, default: false
  attr :counter, :boolean, default: false, doc: "显示长度提示（设置新密码时）"
  slot :aside, doc: "标签行右侧链接"

  @doc "密码输入：可切换明文，设置新密码时实时提示长度。"
  def secret(assigns) do
    ~H"""
    <div class="ac-field">
      <div class="ac-label-row">
        <label class="ac-label" for={@id}>{@label}</label>
        {render_slot(@aside)}
      </div>
      <div class="ac-secret">
        <input
          id={@id}
          name={@name}
          type="password"
          class="ac-input"
          autocomplete={@autocomplete}
          minlength={@minlength}
          maxlength="128"
          autofocus={@autofocus}
          aria-describedby={@counter && "#{@id}-hint"}
          required
        />
        <button type="button" class="ac-reveal" data-reveal={@id} aria-pressed="false" hidden>显示</button>
      </div>
      <p :if={@counter} id={"#{@id}-hint"} class="ac-hint" data-count={@id}>
        至少 {@minlength} 个字符。一句好记的短语比复杂符号更安全。
      </p>
    </div>
    """
  end
end
