defmodule Mix.Tasks.SceneServer.Worldgen.InspectTest do
  use ExUnit.Case, async: false

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    Mix.Shell.Process.flush()

    on_exit(fn ->
      Mix.Shell.Process.flush()
      Mix.shell(previous_shell)
    end)

    :ok
  end

  test "输出固定 canonical XYZ chunk 的结构化 observation" do
    Mix.Tasks.SceneServer.Worldgen.Inspect.run([
      "--chunk=-2,-3,-8",
      "--seed",
      "1337"
    ])

    output = receive_worldgen_output()
    assert output =~ ~s(algorithm_version: "worldgen_density_v2@1")
    assert output =~ ~s(chunk_coord: {-2, -3, -8})
    assert output =~ ~s(chunk_hash: "c3074cd53f9d98f1")
    assert output =~ "solid_cells: 4072"
    assert output =~ "cave_air_cells: 24"
  end

  test "缺少 chunk 参数时显式失败" do
    assert_raise Mix.Error, ~r/missing_chunk_coord/, fn ->
      Mix.Tasks.SceneServer.Worldgen.Inspect.run([])
    end
  end

  defp receive_worldgen_output do
    receive do
      {:mix_shell, :info, [output]} ->
        if String.contains?(output, "algorithm_version") do
          output
        else
          receive_worldgen_output()
        end
    after
      1_000 -> flunk("未收到 WorldGen inspect 输出")
    end
  end
end
