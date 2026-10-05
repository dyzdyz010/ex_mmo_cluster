defmodule AuthServer.TestMailer do
  @moduledoc "只测试：替代外部邮件投递，验证码仍由正式 Auth 生成、保存和验证。"
  def deliver(email,purpose,code) do
    send(Application.fetch_env!(:auth_server,:test_mail_recipient),{:account_mail,email,purpose,code})
    :ok
  end
end
