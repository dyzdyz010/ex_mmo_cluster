# Autopilot Spec: Dev login flow (server auto-upsert + client login screen)

## Goal

Decouple client from pre-provisioned user/token. User opens bevy_client, types a username, clicks Enter — client issues one HTTP call that upserts account+character on the server and returns a signed token, then connects the gate normally. Deployment only sets server address env vars.

## Non-goals

- Production auth changes. The new endpoint is dev-only, gated by `DEV_AUTO_LOGIN=true`.
- Removing the existing `/ingame/login_post` form flow.
- Changing gate token verification.

## Server changes

1. **`AuthServer.Accounts.upsert_dev/1`** (`apps/auth_server/lib/auth_server/accounts.ex`)
   - Input: `username` (string)
   - Behavior: look up account by username; if present, reuse; if absent, insert new account + companion character at spawn `(1000.0, 1000.0, 100.0)` with default attrs/hp.
   - Return: `{:ok, %{account: %Account{}, character: %Character{}}}`.
   - cid policy: re-use existing character's `id` when account already exists; new account gets new cid from `DataService.UidGenerator.generate/0` (running GenServer in the app).

2. **`AuthServerWeb.IngameController.auto_login/2`** (`apps/auth_server/lib/auth_server_web/controllers/ingame_controller.ex`)
   - Route: `POST /ingame/auto_login` returning JSON.
   - Request body: `{"username": "alice"}`.
   - Response 200: `{"token": "...", "cid": 42, "username": "alice"}`.
   - Response 403: `{"error": "dev_auto_login_disabled"}` when config flag is falsy.
   - Uses `AuthServer.AuthWorker.build_session_claims/2` + `issue_token/1` (existing signing path, unchanged).

3. **Router** (`apps/auth_server/lib/auth_server_web/router.ex`)
   - Mount `post "/auto_login"` under a new `:api` pipeline (JSON) inside the `/ingame` scope.

4. **Runtime config** (`config/runtime.exs`)
   - Read `DEV_AUTO_LOGIN` env. Store in `:auth_server, :dev_auto_login` as boolean.
   - In `prod` env, raise at boot if `DEV_AUTO_LOGIN=true` is set — prevent accidental enablement in prod.

5. **Deployment** (`deploy/.env`, `deploy/.env.example`)
   - Add `DEV_AUTO_LOGIN=true` to local `.env`.
   - Add comment in `.env.example` explaining it MUST stay unset in prod.

## Client changes

1. **Deps** (`clients/bevy_client/Cargo.toml`)
   - Add `bevy_egui` (version compatible with current Bevy).
   - Add `ureq` (smaller sync HTTP, no tokio).

2. **Config refactor** (`clients/bevy_client/src/config.rs`)
   - Remove `username`, `cid`, `token` from `ClientConfig::from_env`.
   - Keep: `gate_addr`, add `auth_addr` (default `http://127.0.0.1:4000`), keep other transport/observe fields.
   - Add `SessionCredentials { username, cid, token }` populated at runtime after login.

3. **Login state** (new `clients/bevy_client/src/login.rs`)
   - Bevy `State` enum gains `AppState::Login | AppState::Game`.
   - egui panel: single text input (username) + Enter button.
   - On submit: POST `{auth_addr}/ingame/auto_login` with JSON `{username}`. On 200, store credentials in a resource and transition to `AppState::Game`. On error, show inline error; stay in Login.
   - Disable button while request in flight.

4. **App wiring** (`clients/bevy_client/src/app.rs`)
   - Register `AppState`, add `EguiPlugin`, mount Login systems on `OnEnter(Login)`, existing networking systems gated on `AppState::Game`.
   - Network thread must not spawn until credentials present.

5. **Headless adaptation** (`clients/bevy_client/src/headless.rs`, `src/main.rs`)
   - Add CLI `--username <name>` flag; when present, bypass Login scene and do the same HTTP call synchronously before starting the network thread.
   - Drop requirement for `BEVY_CLIENT_USERNAME/CID/TOKEN` env vars. Still accept `BEVY_CLIENT_AUTH_ADDR` + `BEVY_CLIENT_GATE_ADDR`.

6. **Docs** (`clients/bevy_client/README.md`)
   - Replace "source .demo/human-client.ps1" flow with "set two env vars and run".

## Acceptance

- `docker compose up -d` with `DEV_AUTO_LOGIN=true` in `.env`.
- From host, `curl -X POST -H 'Content-Type: application/json' -d '{"username":"alice"}' http://127.0.0.1:4000/ingame/auto_login` returns `{"token":"...","cid":<int>,"username":"alice"}`.
- Second call with same username returns same cid (character row re-used).
- `cargo run` starts bevy_client, login screen accepts "alice", Enter transitions to game, character appears at spawn.
- Second instance with "bob" connects; both clients see each other's AOI events.
- Prod build with `MIX_ENV=prod` and `DEV_AUTO_LOGIN=true` refuses to start.
- All existing `mix test` continues to pass.

## Out of scope

- Client-side validation of username (length/charset).
- Persistence of last-used username.
- UI polish beyond a single input + button.
