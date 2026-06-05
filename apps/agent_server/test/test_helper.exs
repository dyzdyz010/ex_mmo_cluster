# Interface tests exercise dependency discovery via BeaconServer's Horde
# registry, so the registry must be running before the suite starts.
{:ok, _} = Application.ensure_all_started(:beacon_server)

ExUnit.start()
