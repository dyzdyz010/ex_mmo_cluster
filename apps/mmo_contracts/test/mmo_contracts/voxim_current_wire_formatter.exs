defmodule MmoContracts.VoximCurrentWireFormatter do
  @moduledoc false
  use GenServer
  def init(opts), do: {:ok, opts}

  def handle_cast({:test_finished, test}, state) do
    status =
      case test.state do
        nil -> "Success"
        {:failed, _} -> "Fail"
        _ -> "Skipped"
      end

    IO.puts("\nG0_CASE\t#{inspect(test.module)}.#{test.name}\t#{status}")
    {:noreply, state}
  end

  def handle_cast(_, state), do: {:noreply, state}
end
