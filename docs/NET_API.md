# Net API (owner: net-engineer, `src/net/`)

Everything outside `src/net/` talks to the network through these entry points only.
No `@rpc`, `multiplayer.*`, `MultiplayerSpawner` or `MultiplayerSynchronizer` elsewhere.
Transport: Godot high-level multiplayer over `ENetMultiplayerPeer` (ADR 0002), host =
peer 1, up to `Constants.MAX_PLAYERS` (8) seats, join by address:port.

## NetSession (autoload, `class_name NetSessionService`)
- `host(port: int, profile: LobbyProfile) -> Error` — port 0 picks an ephemeral port;
  read it back with `bound_port() -> int`. Host is peer 1 and seat 0.
- `join(address: String, port: int, profile: LobbyProfile) -> Error` — the outcome arrives
  later: `seats_changed` once admitted, `connection_failed(reason)` otherwise.
- `leave() -> void` — closes the session; a client tells the host first so its seat is freed
  at once. A voluntary leave does not emit `disconnected`.
- `is_host() -> bool` (offline counts as hosting), `is_online() -> bool` (host: hosting;
  client: admitted by the host), `local_peer_id() -> int` (1 when offline).
- `seats() -> Array[LobbySeat]` — copy ordered by seat index, host first, max 8;
  `local_seat() -> LobbySeat`.
- `set_ready(ready: bool)`, `set_profile(profile: LobbyProfile)` — name, car, paint, tiers or
  integrity changes; clients ask the host, which re-broadcasts the seat list.
- `request_start(track_id: StringName) -> void` — host only; draws the seed and emits
  `race_requested(track_id, seed)` on every peer, host included.
- `kick(peer_id: int) -> void` — host only; the peer gets `disconnected` with
  `last_reason == REASON_KICKED`.
- `participants_data() -> Array[Dictionary]` — one entry per seat in seat order:
  `id` (peer id), `name`, `car_id`, `paint`, `tiers`, `integrity`, `is_local`. The UI builds
  `RaceConfig` from it (`KIND_LOCAL` for `is_local`, `KIND_REMOTE` otherwise, `online = true`);
  `src/net` cannot reference `RaceConfig` (layer graph: net -> core only).
- `max_seats: int` (default `Constants.MAX_PLAYERS`; tests lower it), `last_reason: String`
  (`REASON_ROOM_FULL`, `REASON_KICKED`, `REASON_UNREACHABLE`, `REASON_HOST_LEFT`).
- signals: `seats_changed(seats: Array)`, `race_requested(track_id, seed)`,
  `connection_failed(reason)`, `disconnected()`, `peer_joined(peer_id)`, `peer_left(peer_id)`.

The host keeps the authoritative seat list and replicates it with a reliable RPC on every
change; clients send their profile on connect. A peer beyond `max_seats` is told
`REASON_ROOM_FULL` and dropped. `peer_disconnected` frees the seat and re-broadcasts;
`server_disconnected` on a client emits `disconnected` and cleans up.

## RaceSync (`class_name RaceSync extends Node`)
Instantiated by the UI (`RaceSync.new()`, it names itself `RaceSync`) as a child of the race
scene when `NetSession.is_online()`, then `attach(race: Node)`. RPCs are routed by node
path, so the race scene and the sync node must sit at the same path on every peer.
- `attach(race: Node)` / `detach()` — connects the duck-typed hooks of
  `docs/ARCHITECTURE.md` "Race scene contract" and calls `race.set_authority(is_host)`.
- `is_authority() -> bool`, `remote_ids() -> Array[int]`,
  `interpolated_state(peer_id: int) -> PackedFloat32Array`.
- Every peer publishes its own `local_state_updated(id, packed)` at 20 Hz (unreliable
  ordered, latest wins); receivers interpolate `z`, `x` and `altitude` between the last two
  packets in `_physics_process` and call `race.set_remote_state(id, packed)` every tick. A
  `z` jump of 5000+ units (lap wrap / respawn) snaps. A peer may only publish its own id;
  the host may publish any id (`multiplayer.get_remote_sender_id()` is checked).
- The host relays `penalty_decided(id, kind, data)` to the owning peer as `apply_penalty(id, kind, data)`
  for remote ids only: the authority applies its own penalties itself. Bump data carries
  signed lateral `push` and `speed_ratio`; recipients never infer direction from position.
- The host forwards `RaceBus.race_phase_changed` and `RaceBus.countdown_tick` as
  `force_phase(phase, seconds_left)` during COUNTDOWN (from `race._countdown_left`),
  and `force_phase(phase, race.race_time)` for other phases (countdown ticks repeat `PHASE_COUNTDOWN`, so
  `force_phase` must be idempotent) and `RaceBus.car_finished` as `force_finish(id, place,
  time)`. Clients never forward RaceBus.
- Host `RaceBus.race_finished(results)` reliably broadcasts the complete table through
  `force_results(results)`. FINISHED phase is not sent separately. Clients end only through
  this event, never their local grace timer. Attach sync before the UI results listener.
- Host `RaceBus.car_crushed(attacker, victim)` reliably broadcasts feedback; clients emit
  that signal and `car_landed(attacker, true)` without damage. Damage travels only in penalties.
  Received bus events are guarded against relay echo (including multi-peer tests in one tree).

## LobbyProfile / LobbySeat (Resources in `src/net/`)
`LobbyProfile`: `name`, `car_id`, `paint`, `tiers` (slot -> tier), `integrity`;
`LobbyProfile.make(name, car_id, paint, tiers, integrity)`, `to_dictionary()`,
`LobbyProfile.from_dictionary(data)` (sanitised: name through `GameSettings.sanitize_name`,
paint/tiers/integrity clamped). `LobbySeat` adds `peer_id`, `seat` (index) and `ready`, with
`apply_profile(profile)`, `profile()` and the same Dictionary round trip. Resources never
cross the wire; only their Dictionaries do.

## UI flow
1. Lobby screen: `NetSession.host(Constants.DEFAULT_PORT, profile)` or
   `NetSession.join(address, port, profile)`; render `seats()` on `seats_changed`; call
   `set_ready` / `set_profile`; the host calls `request_start(track_id)`.
2. On `race_requested(track_id, seed)` every peer builds a `RaceConfig` from
   `participants_data()` (`online = true`, `seed`, `track_id`), instantiates the race scene
   at the same tree path on every peer, adds `RaceSync.new()` under it, calls
   `sync.attach(race)` and then `race.start(config)`.
3. Leave the race / lobby with `NetSession.leave()`; return to the menu on `disconnected`
   and show `last_reason`.

## Testing
Host and client run in one process: each lives under its own scene-tree branch bound to a
`SceneMultiplayer` via `get_tree().set_multiplayer(api, branch_path)`, so a second
`NetSessionService.new()` under the client branch talks to the host branch over real ENet on
`127.0.0.1` with port 0. See `tests/integration/net/`. Godot 4.7.2 passes the channel
count as the inbound bandwidth cap when creating the ENet host; `NetSession` lifts it
(`bandwidth_limit(0, 0)`) right after creation.


RaceHost subscribes to `disconnected` during an online race and removes the subscription
in `leave()`; loss returns to the lobby connect panel with `last_reason` visible.
Lobby profiles include the current car's installed tiers and integrity. Results persist
damage and republish the profile before returning to the room. Solo Race Again builds a
fresh config from the current profile with a new seed. Online pause toggles a notice only.
