defmodule AuthServerWeb.AccountPortalController do
  @moduledoc "全局系统功能：玩家账号网页；复用 Identity，与游戏共享账号和撤销语义。"
  use AuthServerWeb, :controller
  alias AuthServer.Identity
  plug :put_layout, false
  plug :put_root_layout, false
  plug :no_store

  def login_page(conn, _), do: guest_only(conn, :login)
  def register_page(conn, _), do: guest_only(conn, :register)
  def forgot_page(conn, _), do: page(conn, :forgot)
  def reset_page(conn, _), do: page(conn, :reset)
  def claim_page(conn, _), do: page(conn, :claim)

  def index(conn, _) do
    with_account(conn, fn conn, context -> page(conn, :manage, %{}, nil, context) end)
  end

  def login(conn, p) do
    case Identity.login(p["email"], p["password"], false) do
      {:ok, session} ->
        Identity.logout(get_session(conn, :account_access))
        conn |> configure_session(renew: true) |> put_session(:account_access, session.access_token) |> redirect(to: "/auth")
      {:error, reason} -> failure(conn, :login, p, reason)
    end
  end

  def registration_email(conn, p) do
    result(conn, :register, p, Identity.send_registration_email(p["email"], p["invite"], source(conn)), "验证邮件已发送；请填写邮件验证码和密码完成注册。已有账号可直接登录。")
  end

  def register(conn, p) do
    case Identity.register(p["email"], p["password"], p["code"], p["invite"]) do
      {:ok, _} -> conn |> put_flash(:ok, "注册成功。现在可以在 Voxim 游戏中使用邮箱和密码登录。") |> redirect(to: "/auth/login")
      {:error, reason} -> failure(conn, :register, p, reason)
    end
  end

  def forgot(conn, p) do
    result(conn, :forgot, p, Identity.forgot_password(p["email"], source(conn)), "若该邮箱已注册，重置邮件已发送。请使用邮件中的重置码设置新密码。")
  end

  def reset(conn, p) do
    case Identity.reset_password(p["email"], p["code"], p["password"]) do
      :ok -> signed_out(conn, :ok, "密码已重置，所有设备已退出。请重新登录。")
      {:error, reason} -> failure(conn, :reset, p, reason)
    end
  end

  def claim_email(conn, p) do
    result(conn, :claim, p, Identity.send_claim_email(p["email"], p["legacy_code"], source(conn)), "认领验证邮件已发送，请填写验证码和新密码绑定原角色。")
  end

  def claim(conn, p) do
    case Identity.claim_legacy(p["email"], p["password"], p["code"], p["legacy_code"]) do
      :ok -> conn |> put_flash(:ok, "原角色已绑定，请用邮箱和密码登录游戏。") |> redirect(to: "/auth/login")
      {:error, reason} -> failure(conn, :claim, p, reason)
    end
  end

  def change_password(conn, p) do
    with_account(conn, fn conn, context ->
      case Identity.change_password(get_session(conn, :account_access), p["current_password"], p["password"]) do
        :ok -> signed_out(conn, :ok, "密码已更新，所有设备已退出。请重新登录。")
        {:error, :invalid_session} -> signed_out(conn, :info, "登录已失效，请重新登录。")
        {:error, reason} -> conn |> put_status(400) |> page(:manage, %{}, {:error, if(reason == :invalid_credentials, do: "当前密码错误。", else: error_text(reason))}, context)
      end
    end)
  end

  def logout(conn, _), do: end_session(conn, false)
  def logout_all(conn, _), do: end_session(conn, true)

  defp end_session(conn, all) do
    with_account(conn, fn conn, _ ->
      case Identity.logout(get_session(conn, :account_access), all) do
        :ok -> signed_out(conn, :ok, if(all, do: "所有设备已退出，游戏连接已关闭。", else: "已退出账号网页。"))
        {:error, :invalid_session} -> signed_out(conn, :info, "登录已失效，请重新登录。")
      end
    end)
  end

  defp with_account(conn, action) do
    case Identity.authenticate(get_session(conn, :account_access)) do
      {:ok, context} -> action.(conn, context)
      _ -> signed_out(conn, :info, "请登录后管理账号。")
    end
  end

  defp signed_out(conn, tone, message) do
    conn |> clear_session() |> configure_session(renew: true) |> put_flash(tone, message) |> redirect(to: "/auth/login")
  end

  # 邮件已发出：页面进入第二步，并按服务端每邮箱 60 秒一封的限制显示重发冷却。
  defp result(conn, screen, p, :ok, message), do: conn |> assign(:sent, true) |> page(screen, p, {:ok, message})
  defp result(conn, screen, p, {:error, reason}, _), do: failure(conn, screen, p, reason)
  defp failure(conn, screen, p, reason), do: conn |> put_status(if(reason == :rate_limited, do: 429, else: 400)) |> page(screen, p, {:error, error_text(reason)})
  # 已登录时登录／注册页没有意义，直接回到账号页。
  defp guest_only(conn, screen) do
    case Identity.authenticate(get_session(conn, :account_access)) do
      {:ok, _} -> redirect(conn, to: "/auth")
      _ -> page(conn, screen)
    end
  end
  defp page(conn, screen, p \\ %{}, notice \\ nil, context \\ nil) do
    viewer = if context, do: Identity.profile(context.account_id) |> Map.put(:admin, context.auth_admin), else: Identity.viewer(get_session(conn, :account_access))
    render(conn, :index, screen: screen, email: p["email"] || "", invite: p["invite"] || "", sent: conn.assigns[:sent] || false,
      notice: notice || flash_notice(conn), viewer: viewer, account: context,
      invite_required: Identity.registration_policy().invite_required)
  end
  defp flash_notice(conn) do
    Enum.find_value([:ok, :info], fn tone -> (text = Phoenix.Flash.get(conn.assigns.flash, tone)) && {tone, text} end)
  end
  defp no_store(conn, _), do: put_resp_header(conn, "cache-control", "no-store")
  defp source(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
  defp error_text(:invalid_credentials), do: "邮箱或密码错误。"
  defp error_text(:invalid_email), do: "请输入有效邮箱。"
  defp error_text(:invalid_password), do: "密码需为 15–128 个字符，避免常见弱密码。"
  defp error_text(:invite_required), do: "当前需要邀请码，请填写后重试。"
  defp error_text(:invalid_invite), do: "邀请码不可用，请检查或联系发放者。"
  defp error_text(:invalid_legacy_claim), do: "旧邀请码无法认领，请检查是否已绑定或联系管理员。"
  defp error_text(:invalid_verification), do: "邮件验证码错误或已失效。"
  defp error_text(:rate_limited), do: "操作过于频繁，请稍后再试。"
  defp error_text(:registration_failed), do: "无法注册，请检查信息；已有账号请登录或找回密码。"
  defp error_text(:account_disabled), do: "账号已停用。"
  defp error_text(:mail_unavailable), do: "邮件暂时无法发送，请稍后再试。"
  defp error_text(_), do: "操作未完成，请稍后重试。"
end
