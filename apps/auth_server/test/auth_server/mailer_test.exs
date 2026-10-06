defmodule AuthServer.MailerTest do
  use ExUnit.Case, async: true

  # 拆出 multipart/alternative 的各部分并解码 base64 正文。
  defp parts(message) do
    [_, boundary] = Regex.run(~r/boundary="([^"]+)"/, message)
    message
    |> String.split("--" <> boundary)
    |> Enum.filter(&String.contains?(&1, "Content-Type: text/"))
    |> Map.new(fn part ->
      [head, body] = String.split(part, "\r\n\r\n", parts: 2)
      [_, type] = Regex.run(~r{Content-Type: (text/\w+)}, head)
      {type, body |> String.replace("\r\n", "") |> Base.decode64!()}
    end)
  end

  test "reset mail carries the proof in the link fragment, never in the query" do
    message = AuthServer.Mailer.SMTP.message("accounts@voxim.test", "player+1@example.test", :password_reset, "Ab-c_9")
    assert message =~ "Subject: =?UTF-8?B?" <> Base.encode64("Voxim 密码重置") <> "?="
    assert Enum.all?(String.split(message, "\r\n"), &(byte_size(&1) <= 78))
    %{"text/plain" => text, "text/html" => html} = parts(message)
    link = AuthServerWeb.Endpoint.url() <> "/auth/reset#code=Ab-c_9&email=player%2B1%40example.test"
    assert text =~ "密码重置码：Ab-c_9"
    assert text =~ link
    assert html =~ ~s(href="#{String.replace(link, "&", "&amp;")}")
    refute html =~ "?code="
  end

  test "existing-account notice carries no code and links to sign-in" do
    %{"text/plain" => text, "text/html" => html} =
      parts(AuthServer.Mailer.SMTP.message("accounts@voxim.test", "owner@example.test", :account_exists, nil))
    assert text =~ "这个邮箱已经有账号"
    assert html =~ ~s(href="#{AuthServerWeb.Endpoint.url()}/auth/login")
    refute text =~ "验证码："
  end

  test "registration mail shows the six-digit code without a link" do
    %{"text/plain" => text, "text/html" => html} =
      parts(AuthServer.Mailer.SMTP.message("accounts@voxim.test", "new@example.test", :registration, "042517"))
    assert text =~ "邮箱验证码：042517"
    assert html =~ ">042517</div>"
    refute html =~ "href="
  end
end
