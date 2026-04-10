# Start Horde registry for all beacon_server tests when it is not already
# running (for example under umbrella-root `mix test`).
case Horde.Registry.start_link(
       name: BeaconServer.DistributedRegistry,
       keys: :unique,
       members: :auto
     ) do
  {:ok, _} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

ExUnit.start()
