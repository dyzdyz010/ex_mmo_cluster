# GateServer

Gate server for the MMO game.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `gate_server` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:gate_server, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/gate_server](https://hexdocs.pm/gate_server).

## Supervision Tree

```mermaid
flowchart TD

A[GateServer] --> B[InterfaceSup]
A --> C[TcpAcceptor]
A --> D[TcpConnectionSup]

B --> E[Interface]
C --> F[TcpAcceptor]
D -- 1:N --> G[TcpConnection]

G .- 1:1 .-> H([SceneServer.PlayerCharacter])
```