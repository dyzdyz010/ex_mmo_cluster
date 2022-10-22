# SceneServer

Scene server for the game.

## Features

+ Player character management
+ Movement syncing
+ AOI management

## Run in Debug

```bash
iex --name <name> --cookie <cookie> -S mix
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/scene_server>.

## The Supervision Tree

```mermaid
flowchart TD

A[SceneServer] --> B[InterfaceSup]
A --> C[PlayerSup]
A --> D[AoiSup]
B --> E[Interface]

subgraph Player
C --> F[PlayerManager]
C --> G[PlayerCharacterSup]
G -- 1:N --> J[PlayerCharacter]
end

subgraph AOI
D --> H[AoiManager]
D --> I[AoiItemSup]
I -- 1:N --> K[AoiItem]
end

J -.-> K
```