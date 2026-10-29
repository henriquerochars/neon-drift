# Neon Drift — Game Design Document

## Fantasy
You are an 80s street racer. Arcade pseudo-3D road, synthwave sunsets, neon billboards,
air thrusters that let your car hop over traffic and a nitro that paints the road blue.

## Loop
Title → Main menu → (Solo race | Online room | Garage | Options)
Race: 3 laps on a looping track, countdown 3-2-1-GO, position is track distance.
Results: place, time, earnings. Earnings buy parts in the Garage; parts change stats.

## Cars (`data/cars/*.tres`)
| id | name | archetype | top speed | accel | handling | nitro | thrusters | armour |
|---|---|---|---|---|---|---|---|---|
| vortex | Vortex | balanced wedge coupe | 3 | 3 | 3 | 3 | 3 | 3 |
| bruiser | Bruiser | heavy muscle | 5 | 2 | 1 | 2 | 2 | 5 |
| hornet | Hornet | nimble hatch | 2 | 4 | 5 | 2 | 3 | 2 |
| phantom | Phantom | nitro specialist | 4 | 3 | 2 | 5 | 2 | 2 |
| mirage | Mirage | jump specialist | 3 | 3 | 3 | 2 | 5 | 1 |
Each stat is a 1-5 rank mapped to physical values in `data/balance/physics.csv`.

## Tuning (`data/parts/*.tres`)
Slots: engine (top speed), turbo (acceleration), tires (handling), nitro_tank (nitro
capacity), thrusters (jump height / airtime), armour (integrity). Each slot has tiers
1-3. A part adds a flat bonus to the base stat. Paint: one of 8 palette colours, applied
as a hue shift to the body colour. Repair restores integrity for a price.

## Nitro
Gauge 0-100. Fills slowly while on the road, faster while drafting behind a car.
Activating costs the whole gauge above a minimum of 25 and gives `nitro_duration`
seconds of `nitro_speed_bonus`. Cannot activate while airborne.

## Air thrusters (jump)
Press jump with enough `thruster_charge` → vertical arc, `jump_height`, `jump_airtime`.
While airborne steering is halved and nitro is unavailable. On landing:
- on empty road: short landing wobble;
- on top of another car: the car underneath is crushed (speed -60%, integrity -20) and
  the jumper takes a hard landing (speed -35%, integrity -10). "Landing on someone hurts
  you too" is the assumption taken from the brief.
Integrity 0 → the car limps (max speed -40%) until repaired in the garage.

## Collisions
Side contact with a car: both bounce laterally, speed -15%. Roadside objects: speed -50%
and lateral push. Off-road: strong deceleration.

## Online
One host, up to 8 seats. Lobby shows name, car, paint, ready. Host picks the track and
starts. Each peer owns its car state; the host owns the race clock, finish order and
crush/collision verdicts. Join by address:port (NAT traversal is backlog).

## Options
Master, music and SFX volume; fullscreen; integer scale; vsync; show FPS; player name;
input scheme summary (keyboard, gamepad). Persisted in `user://settings.cfg`.

## Audio
Synthwave chiptune: menu theme, two race themes, results jingle. SFX: engine loop
(pitch by speed), nitro ignite, nitro loop, thruster jump, landing, crush, side bump,
offroad rumble, countdown beep, go, lap, finish, menu move, menu confirm, buy.

## Definition of Done (MVP)
- 5 cars, 3 tracks (Coast, Sunset City, Desert Night), 3 laps, 7 AI rivals in solo.
- Garage: buy parts in 6 slots × 3 tiers, paint, repair; persists in `user://profile.json`.
- Nitro and jump with VFX and SFX; crush and hard-landing rules above.
- Online room: host/join, 8 seats, lobby sync, synchronised countdown and race results.
- Menu, options, HUD (speed, nitro, thrusters, lap, position, minimap bar), results.
