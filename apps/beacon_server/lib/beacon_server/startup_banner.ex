defmodule BeaconServer.StartupBanner do
  @moduledoc """
  Prints the cluster startup banner once per BEAM.

  The banner is for interactive server startup only. Tests disable it by
  default through `:beacon_server, :startup_banner_enabled` so it does not
  pollute assertion output.
  """

  @default_marker {__MODULE__, :printed}

  @doc "Prints the ASCII startup banner once when enabled."
  def print_once(opts \\ []) do
    enabled? = Keyword.get(opts, :enabled?, banner_enabled?())
    marker = Keyword.get(opts, :marker, @default_marker)
    device = Keyword.get(opts, :device, :stdio)

    if enabled? and not :persistent_term.get(marker, false) do
      :persistent_term.put(marker, true)
      IO.puts(device, banner())
    end

    :ok
  end

  @doc "Returns the ASCII startup banner text."
  def banner do
    """

      ________  __  ___   __  ___   ___  ____ 
     / ____/  |/  /  /  |/  /  /  |/  /  / __ \\
    / __/ / /|_/ /  / /|_/ /  / /|_/ /  / / / /
    / /___/ /  / /  / /  / /  / /  / /  / /_/ / 
    /_____/_/  /_/  /_/  /_/  /_/  /_/   \\____/  

          EX MMO CLUSTER
          World / Scene / Gate

    """
  end

  defp banner_enabled? do
    Application.get_env(:beacon_server, :startup_banner_enabled, default_enabled?())
  end

  defp default_enabled? do
    not mix_test_env?()
  end

  defp mix_test_env? do
    Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test
  end
end
