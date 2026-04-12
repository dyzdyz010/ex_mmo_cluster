defmodule Mix.Tasks.Demo.Observe do
  @moduledoc """
  Tail structured demo observe logs from `.demo/observe`.
  """

  use Mix.Task

  @shortdoc "Read demo observe logs"

  @impl true
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [dir: :string, file: :string, lines: :integer]
      )

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    dir = opts[:dir] || Path.expand(".demo/observe")
    lines = max(opts[:lines] || 20, 1)

    files =
      case opts[:file] do
        nil ->
          Path.join(dir, "*.log")
          |> Path.wildcard()
          |> Enum.sort()

        file ->
          [Path.join(dir, file)]
      end

    if files == [] do
      Mix.raise("no observe logs found in #{dir}")
    end

    Enum.each(files, fn path ->
      Mix.shell().info("")
      Mix.shell().info("=== #{path} ===")

      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.take(-lines)
      |> Enum.each(fn line -> Mix.shell().info(line) end)
    end)
  end
end
