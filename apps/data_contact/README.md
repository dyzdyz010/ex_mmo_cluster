# DataContact

Mnesia cluster beacon node. Every Mnesia node should connect to this node before providing services to other nodes.

## Functionalities

1. Beacon to all Mnesia nodes, monitoring.
2. Select `data_service` node for request node, with load-balancing.

**TODO: Add description**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `data_contact` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:data_contact, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/data_contact](https://hexdocs.pm/data_contact).

