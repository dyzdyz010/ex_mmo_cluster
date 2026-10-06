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
    case :gen_smtp_client.send_blocking({from,[email],message(from,email,purpose,code)},Keyword.delete(config,:from)) do
      receipt when is_binary(receipt) -> :ok
      _ -> {:error,:mail_unavailable}
    end
  end
  @doc false
  def message(from,email,purpose,code) do
    {subject,text,html} = AuthServerWeb.AccountEmail.compose(email,purpose,code)
    boundary = "voxim-" <> Base.encode16(:crypto.strong_rand_bytes(12),case: :lower)
    ["From: ",from,"\r\nTo: ",email,"\r\nSubject: =?UTF-8?B?",Base.encode64(subject),"?=\r\nMIME-Version: 1.0\r\n",
     "Content-Type: multipart/alternative; boundary=\"",boundary,"\"\r\n\r\n",
     part(boundary,"text/plain",text),part(boundary,"text/html",html),"--",boundary,"--\r\n"] |> IO.iodata_to_binary()
  end
  # base64 正文按 RFC 2045 每行不超过 76 字符，SMTP 单行上限为 998。
  defp part(boundary,type,body) do
    ["--",boundary,"\r\nContent-Type: ",type,"; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n",wrap(Base.encode64(body)),"\r\n"]
  end
  defp wrap(<<line::binary-size(76),rest::binary>>) when rest != "", do: [line,"\r\n"|wrap(rest)]
  defp wrap(line), do: line
end
