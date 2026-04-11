defmodule Demo.ConfigWriter do
  @moduledoc """
  Emit human-friendly config files for the local demo.
  """

  def write!(scenario, output_dir) do
    File.mkdir_p!(output_dir)

    client_entries =
      scenario.humans
      |> Enum.map(fn human ->
        payload = %{
          gate_addr: scenario.gate_addr,
          auth_url: scenario.auth_url,
          username: human.username,
          cid: human.cid,
          token: human.token
        }

        base =
          if human.slot == 1 do
            "human-client"
          else
            "human-client-#{human.slot}"
          end

        write_client_files!(output_dir, base, payload)
      end)

    manifest_path = Path.join(output_dir, "human-clients.json")
    File.write!(manifest_path, Jason.encode_to_iodata!(client_entries, pretty: true))

    primary = Enum.find(client_entries, &(&1.slot == 1))

    %{
      json: primary.json,
      powershell: primary.powershell,
      shell: primary.shell,
      manifest: manifest_path,
      clients: client_entries
    }
  end

  defp write_client_files!(output_dir, base, payload) do
    json_path = Path.join(output_dir, "#{base}.json")
    ps1_path = Path.join(output_dir, "#{base}.ps1")
    sh_path = Path.join(output_dir, "#{base}.env.sh")

    File.write!(json_path, Jason.encode_to_iodata!(payload, pretty: true))
    File.write!(ps1_path, render_ps1(payload))
    File.write!(sh_path, render_sh(payload))

    %{
      slot: payload[:slot] || infer_slot(base),
      username: payload.username,
      cid: payload.cid,
      json: json_path,
      powershell: ps1_path,
      shell: sh_path
    }
  end

  defp render_ps1(payload) do
    """
    $env:BEVY_CLIENT_GATE_ADDR='#{ps_single_quoted(payload.gate_addr)}'
    $env:BEVY_CLIENT_USERNAME='#{ps_single_quoted(payload.username)}'
    $env:BEVY_CLIENT_CID='#{ps_single_quoted(payload.cid)}'
    $env:BEVY_CLIENT_TOKEN='#{ps_single_quoted(payload.token)}'
    $env:DEMO_AUTH_URL='#{ps_single_quoted(payload.auth_url)}'
    """
  end

  defp render_sh(payload) do
    """
    export BEVY_CLIENT_GATE_ADDR='#{sh_single_quoted(payload.gate_addr)}'
    export BEVY_CLIENT_USERNAME='#{sh_single_quoted(payload.username)}'
    export BEVY_CLIENT_CID='#{sh_single_quoted(payload.cid)}'
    export BEVY_CLIENT_TOKEN='#{sh_single_quoted(payload.token)}'
    export DEMO_AUTH_URL='#{sh_single_quoted(payload.auth_url)}'
    """
  end

  defp ps_single_quoted(value) do
    value
    |> clean_env_value()
    |> String.replace("'", "''")
  end

  defp sh_single_quoted(value) do
    value
    |> clean_env_value()
    |> String.replace("'", "'\"'\"'")
  end

  defp clean_env_value(value) do
    value
    |> to_string()
    |> String.replace(~r/[\r\n]+/, " ")
  end

  defp infer_slot("human-client"), do: 1

  defp infer_slot(base) do
    case Integer.parse(String.replace_prefix(base, "human-client-", "")) do
      {slot, ""} -> slot
      _ -> 1
    end
  end
end
