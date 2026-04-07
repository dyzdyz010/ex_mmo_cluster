# Start Horde registry for all beacon_server tests
{:ok, _} = Horde.Registry.start_link(name: BeaconServer.DistributedRegistry, keys: :unique, members: :auto)

ExUnit.start()
