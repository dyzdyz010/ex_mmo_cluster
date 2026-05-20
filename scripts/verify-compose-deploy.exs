defmodule VerifyComposeDeploy do
  @moduledoc false

  @compose Path.expand("../deploy/docker-compose.yml", __DIR__)
  @env_example Path.expand("../deploy/.env.example", __DIR__)
  @mix Path.expand("../mix.exs", __DIR__)

  def run do
    compose = read!(@compose)
    env_example = read!(@env_example)
    mix = read!(@mix)

    checks = [
      {"compose defines scene service", contains?(compose, ~r/^  scene:\s*$/m)},
      {"scene uses published image tag",
       contains?(compose, ~r/^    image:\s*\$\{IMAGE_TAG\}\s*$/m)},
      {"scene runs scene-only release", contains?(compose, ~r/ex_mmo_scene/)},
      {"scene has no host port bindings",
       not contains?(compose, ~r/^  scene:[\s\S]*?^    ports:/m)},
      {"app release node is not pinned to Docker short hostname",
       not contains?(compose, ~r/RELEASE_NODE:\s*app@app\s*$/m)},
      {"app release node uses a long-name FQDN",
       contains?(compose, ~r/RELEASE_NODE:\s*app@app\.[a-z0-9-]+\.internal\b/)},
      {"app FQDN is published as a network alias",
       contains?(compose, ~r/aliases:\s*\n\s+- app\.[a-z0-9-]+\.internal\b/)},
      {"env documents SCENE_SERVER_COUNT",
       contains?(env_example, ~r/^SCENE_SERVER_COUNT=\d+\s*$/m)},
      {"umbrella defines ex_mmo_scene release", contains?(mix, ~r/ex_mmo_scene:\s*\[/)}
    ]

    failures = for {label, false} <- checks, do: label

    if failures == [] do
      IO.puts("compose deploy contract ok")
    else
      Enum.each(failures, &IO.puts("missing: #{&1}"))
      System.halt(1)
    end
  end

  defp read!(path), do: File.read!(path)
  defp contains?(content, pattern), do: Regex.match?(pattern, content)
end

VerifyComposeDeploy.run()
