# Cluster

This is a demo project to test ideas of making MMORPG game server cluster in Elixir.

# Structure
<pre>

                                        |----------|
                                        |  client  | x N
                                        |----------|

-----------------------------------------|-----|----------------------------------------------

|-------------|	        |--------------|         |-------------|        |--------------|
| auth_server | x N     | auth_manager | x 1     | gate_server | x N    | gate_manager | x 1
|-------------|         |--------------|         |-------------|        |--------------|

-----------------------------------------|-----|----------------------------------------------


                        |--------------|            |---------------|
                        | agent_server | x N	    | agent_manager | x 1
                        |--------------|            |---------------|

-----------------------------------------|-----|----------------------------------------------


                    |-------------------|            |--------------|
                    | scene_server(TBD) | x N	     | world_server | x 1
                    |-------------------|            |--------------|

-----------------------------------------|-----|----------------------------------------------

                |--------------|         |------------|         |--------------|
                | data_service | x N     | data_store | x N     | data_contact | x 1
                |--------------|         |------------|         |--------------|

-----------------------------------------|-----|----------------------------------------------

                                        |---------------|
                                        | beacon_server | x 1
                                        |---------------|
</pre>

+ auth_server - for user authentication
+ auth_manager - for multiple `auth_server` management
+ gate_server - for accepting client tcp socket connections
+ gate_manager - for multiple `gate_server` management
+ agent_server - for player character logic handling
+ agent_manager - for multiple `agent_server` management
+ scene_server - for scene-related logic handling
+ world_server - for world-class logic handling & multiple `scene_server` management
+ data_service - for in-memory database
+ data_store -  for on-disk database
+ data_contact - for database cluster management
+ beacon_server - for cluster-wide resource exchanging