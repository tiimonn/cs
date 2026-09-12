# CS2 Demo Playback: Camera Controls

Demo playback is **not** limited to player POVs — you can detach the camera and fly around the map freely.

## Spectator modes

Press **Space** (jump) during playback to cycle through:

1. First person
2. Third person
3. Free roam

In free roam you move with **WASD**, look with the **mouse**, and pass through walls.

You can also jump straight to free roam via console:

```
spec_mode 6
```

Use **left/right mouse** to cycle between players when in a player-locked mode.

## Useful commands and shortcuts

| Command / Key      | What it does                             |
| ------------------ | ---------------------------------------- |
| `spec_mode 6`      | Switch directly to free roam camera      |
| `sv_specspeed`     | Free camera movement speed (default `3`) |
| `spec_show_xray 1` | See players through walls                |
| **Shift+F2**       | Open the demo playback UI                |
| **Space**          | Cycle spectator modes                    |

Notes:

- Raise `sv_specspeed` for large maps, lower it for precise angle work.
- The playback UI (Shift+F2) handles scrubbing, pausing, and slow motion. Pausing and then flying around is the usual way to inspect a specific moment.
- X-ray can also be toggled from the demo UI, and pairs well with free roam.

## Important caveat: GOTV vs POV demos

Free roam only works properly on **GOTV / server demos**, which record every player.

A **POV demo** recorded client-side with `record` only contains what that one player's client received. If you fly off to another part of the map in a POV demo, other players will appear frozen, missing, or teleporting.

Match demos downloaded from within the game are GOTV, so those are fine.
