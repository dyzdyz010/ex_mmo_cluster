defmodule Mix.Tasks.SceneServer.Worldgen.Inspect do
  @moduledoc """
  只读检查一个服务端 WorldGen canonical XYZ chunk。

      mix scene_server.worldgen.inspect --chunk="CX,CY,CZ" [--seed N]

  PowerShell 检查负坐标时应把整个 switch 加引号，例如：

      mix scene_server.worldgen.inspect '--chunk=-2,-3,-8' --seed 1337

  本任务不启动 Scene runtime、不申请 lease、也不写 authoritative store；输出直接复用
  `SceneServer.Voxel.WorldGen.generate_chunk/3` 的 observation。
  """

  use Mix.Task

  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.Hash
  alias SceneServer.Voxel.WorldGen

  @shortdoc "检查一个 canonical XYZ WorldGen chunk"
  @switches [chunk: :string, seed: :integer]
  @aliases [c: :chunk, s: :seed]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")

    with {options, [], []} <- OptionParser.parse(args, strict: @switches, aliases: @aliases),
         {:ok, chunk_coord} <- parse_chunk(Keyword.get(options, :chunk)),
         worldgen_opts <- worldgen_options(options),
         {:ok, storage, observation} <- WorldGen.generate_chunk(0, chunk_coord, worldgen_opts) do
      result =
        Map.put(
          observation,
          :chunk_hash,
          storage |> Codec.chunk_hash() |> Hash.encode64() |> Base.encode16(case: :lower)
        )

      Mix.shell().info(inspect(result, pretty: false, limit: :infinity))
    else
      {_options, remaining, invalid} ->
        Mix.raise(
          "invalid WorldGen inspect arguments: #{inspect(%{remaining: remaining, invalid: invalid})}"
        )

      {:error, reason} ->
        Mix.raise("WorldGen inspect failed: #{inspect(reason)}")
    end
  end

  defp parse_chunk(value) when is_binary(value) do
    case value |> String.split(",", trim: true) |> Enum.map(&Integer.parse/1) do
      [{x, ""}, {y, ""}, {z, ""}] -> {:ok, {x, y, z}}
      _other -> {:error, :invalid_chunk_coord}
    end
  end

  defp parse_chunk(_value), do: {:error, :missing_chunk_coord}

  defp worldgen_options(options) do
    case Keyword.fetch(options, :seed) do
      {:ok, seed} -> [seed: seed]
      :error -> []
    end
  end
end
