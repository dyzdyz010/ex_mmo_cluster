defmodule VoxelRegion.TestSupport.StaticL0Check do
  @moduledoc "只测试：离线比较同一自然步的语义结果、页读取顺序与退休集合，判定不进入生产路径。"
  @epsilon 1.0e-6

  def compare_steps([], _), do: {:error, :empty_reference}
  def compare_steps(_, []), do: {:error, :empty_run}
  def compare_steps(reference, actual), do: difference(reference, actual, [])

  defp difference(a, b, _) when a === b, do: :ok
  defp difference(a, b, path) when is_float(a) and is_float(b) do
    if abs(a - b) <= @epsilon, do: :ok, else: {:error, {Enum.reverse(path), a, b}}
  end
  defp difference(a, b, path) when is_map(a) and is_map(b) do
    if Map.keys(a) |> Enum.sort() == Map.keys(b) |> Enum.sort() do
      Enum.reduce_while(Enum.sort(Map.keys(a)), :ok, fn key, _ ->
        continue(difference(Map.fetch!(a, key), Map.fetch!(b, key), [key | path]))
      end)
    else
      {:error, {Enum.reverse([:keys | path]), Map.keys(a), Map.keys(b)}}
    end
  end
  defp difference(a, b, path) when is_list(a) and is_list(b) and length(a) == length(b) do
    a |> Enum.zip(b) |> Enum.with_index() |> Enum.reduce_while(:ok, fn {{x, y}, i}, _ ->
      continue(difference(x, y, [i | path]))
    end)
  end
  defp difference(a, b, path), do: {:error, {Enum.reverse(path), a, b}}
  defp continue(:ok), do: {:cont, :ok}
  defp continue(error), do: {:halt, error}

  def verify_reads(events, initially_loaded \\ []) do
    if Enum.any?(events, &(&1.action == :read)) do
      events |> Enum.sort_by(& &1.at) |> Enum.reduce_while({:ok, MapSet.new(initially_loaded)}, fn event, {:ok, loaded} ->
        case event.action do
          :resident -> {:cont, {:ok, MapSet.put(loaded, event.page)}}
          :retire -> {:cont, {:ok, MapSet.delete(loaded, event.page)}}
          :read ->
            if MapSet.member?(loaded, event.page), do: {:cont, {:ok, loaded}},
              else: {:halt, {:error, {:read_before_load, event.page, event.at}}}
        end
      end) |> case do
        {:ok, _} -> :ok
        error -> error
      end
    else
      {:error, :no_reads}
    end
  end

  def verify_retirement(event) do
    expected = event.eligible |> MapSet.intersection(MapSet.union(event.resident, event.staged))
      |> MapSet.difference(event.required) |> MapSet.difference(event.persistence_blocked)
    cond do
      expected != event.retired -> {:error, {:retirement_set_mismatch, expected, event.retired}}
      Enum.any?(event.retired, fn {level, _} -> level != 0 end) -> {:error, :coarse_retirement}
      Enum.any?(event.retired, fn key ->
        not match?(%{source_only: true, core: :ok}, event.cores[key])
      end) -> {:error, :unproven_retirement}
      true -> :ok
    end
  end

  def write_evidence(name, data) do
    if directory = System.get_env("STATIC_L0_EVIDENCE_DIR") do
      File.mkdir_p!(directory)
      path = Path.join(directory, name <> ".etf")
      File.write!(path, :erlang.term_to_binary(data, compressed: 6), [:exclusive])
    end
    :ok
  end
end
