# Demo runtime map

This directory contains the local end-to-end demo scaffolding used to exercise
the real auth/gate/scene/client pipeline.

## Modules

- `scenario.ex`
  - stable human/bot identity and choreography definitions
- `seeds.ex`
  - ensures demo accounts/characters exist and issues real tokens
- `config_writer.ex`
  - writes human client env/json helper files
- `protocol.ex`
  - small binary helpers for the scripted demo bot
- `bot.ex`
  - scripted actor that traverses the real runtime path
- `runner.ex`
  - orchestrates setup, seeding, bot startup, NPC startup, and bounded/smoke runs

## Design rule

The demo should go through the real runtime path whenever possible. Avoid adding
shortcuts that bypass auth/gate/scene just to make the demo easier.
