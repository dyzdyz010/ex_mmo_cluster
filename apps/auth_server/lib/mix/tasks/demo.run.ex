defmodule Mix.Tasks.Demo.Run do
  @moduledoc """
  Start the local bidirectional demo runtime.

  The task seeds demo accounts/characters, writes client env files, and can
  either run indefinitely with scripted bots or execute a bounded smoke pass.
  """

  use Mix.Task

  @shortdoc "Run the local client/server demo"

  @impl true
  def run(args) do
    Mix.Task.run("compile")

    case parse_args(args) do
      {:ok, opts} ->
        case Demo.Runner.run(opts) do
          {:ok, _result} -> :ok
          {:error, reason} -> Mix.raise(reason)
        end

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  defp parse_args(args), do: parse_args(args, [])

  defp parse_args([], opts), do: {:ok, Enum.reverse(opts)}

  defp parse_args([flag | rest], opts) when flag in ["--dry-run", "--dry_run"] do
    parse_args(rest, [{:dry_run, true} | opts])
  end

  defp parse_args([flag | rest], opts) when flag in ["--smoke"] do
    parse_args(rest, [{:smoke, true} | opts])
  end

  defp parse_args([flag, value | rest], opts)
       when flag in ["--exit-after", "--exit_after"] do
    with {parsed, ""} <- Integer.parse(value) do
      parse_args(rest, [{:exit_after, parsed} | opts])
    else
      _ -> {:error, "invalid integer for #{flag}: #{value}"}
    end
  end

  defp parse_args([flag, value | rest], opts)
       when flag in ["--bot-count", "--bot_count"] do
    with {parsed, ""} <- Integer.parse(value) do
      parse_args(rest, [{:bot_count, parsed} | opts])
    else
      _ -> {:error, "invalid integer for #{flag}: #{value}"}
    end
  end

  defp parse_args([flag, value | rest], opts)
       when flag in ["--human-cid", "--human_cid"] do
    with {parsed, ""} <- Integer.parse(value) do
      parse_args(rest, [{:human_cid, parsed} | opts])
    else
      _ -> {:error, "invalid integer for #{flag}: #{value}"}
    end
  end

  defp parse_args([flag, value | rest], opts)
       when flag in ["--human-username", "--human_username"] do
    parse_args(rest, [{:human_username, value} | opts])
  end

  defp parse_args([flag, value | rest], opts)
       when flag in ["--output-dir", "--output_dir"] do
    parse_args(rest, [{:output_dir, value} | opts])
  end

  defp parse_args([flag, value | rest], opts)
       when flag in ["--gate-addr", "--gate_addr"] do
    parse_args(rest, [{:gate_addr, value} | opts])
  end

  defp parse_args([flag, value | rest], opts)
       when flag in ["--auth-url", "--auth_url"] do
    parse_args(rest, [{:auth_url, value} | opts])
  end

  defp parse_args([flag], _opts) do
    {:error, "missing value for option #{flag}"}
  end

  defp parse_args([flag | _rest], _opts) do
    {:error, "invalid option: #{flag}"}
  end
end
