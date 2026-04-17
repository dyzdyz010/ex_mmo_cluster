# Auth supervisor map

Current auth-side subtree:

- `InterfaceSup`
  - `AuthServer.Interface`

The auth app is currently small enough that most runtime pieces live directly in
the application tree, but the interface stays wrapped so cluster-facing concerns
remain isolated.
