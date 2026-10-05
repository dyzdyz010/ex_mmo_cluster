defmodule AuthServer.Mailer do
  @moduledoc "全局系统功能：验证邮件投递边界。正式环境使用阿里云 DirectMail SMTP；测试替换投递模块。"
  @doc "只向验证目标地址投递，不将验证码写日志。"
  def deliver(email,purpose,code) do
    adapter = Application.get_env(:auth_server,:mail_adapter,AuthServer.Mailer.SMTP)
    adapter.deliver(email,purpose,code)
  end
end

defmodule AuthServer.Mailer.SMTP do
  @moduledoc "全局系统功能：SMTP 投递；生产配置显式启用 TLS 证书校验，本地捕获器使用回环地址。"
  @doc false
  def deliver(email,purpose,code) do
    case Application.fetch_env(:auth_server,:smtp) do
      {:ok,config} -> send_mail(email,purpose,code,config)
      :error -> {:error,:mail_unavailable}
    end
  end
  defp send_mail(email,purpose,code,config) do
    from = Keyword.fetch!(config,:from)
    subject = if purpose == :registration, do: "Voxim 注册邮箱验证", else: "Voxim 账号验证"
    body = "您的验证码：#{code}\r\n请在有效期内使用。若非本人操作，请忽略此邮件。"
    message = ["From: ",from,"\r\nTo: ",email,"\r\nSubject: =?UTF-8?B?",Base.encode64(subject),"?=\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n",Base.encode64(body),"\r\n"] |> IO.iodata_to_binary()
    case :gen_smtp_client.send_blocking({from,[email],message},Keyword.delete(config,:from)) do
      receipt when is_binary(receipt) -> :ok
      _ -> {:error,:mail_unavailable}
    end
  end
end
