defmodule AuthServerWeb.AccountEmail do
  @moduledoc """
  全局系统功能：账号验证邮件正文（纯文本＋HTML）。色值取自 AccountUI 设计 token，
  邮件客户端不支持 CSS 变量与外部样式，因此全部内联。

  重置与认领邮件附带按钮，邮箱和验证码放在链接的 # 片段里：片段不随请求发往服务器，
  不会进入访问日志，由账号页脚本填入表单后立即清除。
  """
  use Phoenix.Component
  import AuthServerWeb.AccountUI, only: [color: 1, font: 1]

  @copy %{
    registration: %{subject: "Voxim 注册邮箱验证", title: "验证你的邮箱", proof: "邮箱验证码", ttl: "10 分钟", path: nil,
      body: "在注册页面填写下面的验证码，然后设置密码即可完成注册。"},
    legacy_claim: %{subject: "Voxim 原角色绑定验证", title: "绑定原角色", proof: "认领验证码", ttl: "10 分钟", path: "/auth/claim",
      body: "点击下方按钮回到绑定页面，邮箱和验证码会自动填好。为保护原角色，请重新输入原登录邀请码并设置密码。"},
    password_reset: %{subject: "Voxim 密码重置", title: "重置你的密码", proof: "密码重置码", ttl: "30 分钟", path: "/auth/reset",
      body: "点击下方按钮设置新密码，邮箱和重置码会自动填好。成功后所有设备与游戏连接都会退出。"}
  }

  @doc "返回 {主题, 纯文本, HTML}。"
  def compose(email, purpose, code) do
    copy = Map.fetch!(@copy, purpose)
    link = copy.path && AuthServerWeb.Endpoint.url() <> copy.path <> "#" <> URI.encode_query(%{"email" => email, "code" => code})
    text = [copy.title, "\r\n\r\n", copy.body, "\r\n\r\n", copy.proof, "：", code, "\r\n",
      if(link, do: ["打开页面：", link, "\r\n"], else: []),
      "\r\n", copy.ttl, "内有效。若非本人操作，请忽略此邮件，账号不会有任何变化。\r\n\r\n— Voxim 账号"]
    html = %{copy: copy, code: code, link: link, short: byte_size(code) <= 8, c: &color/1, sans: font(:sans), mono: font(:mono)}
      |> html() |> Phoenix.HTML.Safe.to_iodata()
    {copy.subject, IO.iodata_to_binary(text), IO.iodata_to_binary(html)}
  end

  defp html(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="zh-CN">
      <head><meta charset="utf-8" /><meta name="color-scheme" content="dark" /><title>{@copy.subject}</title></head>
      <body style={"margin:0;padding:0;background:#{@c.(:canvas)};"}>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style={"background:#{@c.(:canvas)};font-family:#{@sans};"}>
          <tr><td align="center" style="padding:40px 16px;">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;">
              <tr><td style={"padding:0 4px 20px;color:#{@c.(:text)};font:600 12px/1 #{@mono};letter-spacing:4px;"}>
                <span style={"color:#{@c.(:violet)};"}>◆</span>&nbsp; VOXIM <span style={"color:#{@c.(:dim)};"}>/ ACCOUNT</span>
              </td></tr>
              <tr><td style={"padding:36px 32px;background:#{@c.(:surface)};border:1px solid #232a45;border-top:1px solid #{@c.(:cyan)};border-radius:24px;"}>
                <p style={"margin:0;color:#{@c.(:dim)};font:600 11px/1.4 #{@mono};letter-spacing:2px;text-transform:uppercase;"}>{@copy.subject}</p>
                <h1 style={"margin:12px 0 0;color:#ffffff;font-size:26px;line-height:1.3;font-weight:600;"}>{@copy.title}</h1>
                <p style={"margin:14px 0 0;color:#{@c.(:muted)};font-size:15px;line-height:1.8;"}>{@copy.body}</p>
                <p style={"margin:28px 0 8px;color:#{@c.(:dim)};font:600 11px/1 #{@mono};letter-spacing:2px;"}>{@copy.proof}</p>
                <div style={"padding:18px 20px;background:#{@c.(:"surface-strong")};border:1px solid #2c2f5a;border-radius:14px;color:#ffffff;font-family:#{@mono};" <> if(@short, do: "font-size:30px;letter-spacing:10px;font-weight:600;", else: "font-size:15px;letter-spacing:1px;word-break:break-all;")}>{@code}</div>
                <table :if={@link} role="presentation" cellpadding="0" cellspacing="0" style="margin-top:28px;"><tr>
                  <td style={"border-radius:13px;background-color:#a9efff;background-image:linear-gradient(110deg,#f8fbff,#a9efff 42%,#a79bff 80%,#ff9ed9);"}>
                    <a href={@link} style="display:inline-block;padding:15px 26px;color:#07101a;font-size:15px;font-weight:700;letter-spacing:1px;text-decoration:none;">打开页面并自动填写 →</a>
                  </td>
                </tr></table>
                <p style={"margin:28px 0 0;padding-top:20px;border-top:1px solid #232a45;color:#{@c.(:dim)};font-size:13px;line-height:1.8;"}>
                  {@copy.ttl}内有效。若非本人操作，请忽略此邮件，账号不会有任何变化。
                </p>
              </td></tr>
              <tr><td style={"padding:20px 4px 0;color:#{@c.(:dim)};font:600 10px/1.8 #{@mono};letter-spacing:3px;"}>
                SKÖPUNARVERK · 让世界被书写，也被运行
              </td></tr>
            </table>
          </td></tr>
        </table>
      </body>
    </html>
    """
  end
end
