<img src="media/logo.png" width="128" align="right" alt="Simple Hunter Timer logo">

# Simple Hunter Timer (SHT)

A simple Auto Shot timer for Classic Era hunters.

One bar fills over each Auto Shot cycle:

- **Green (Move):** reloading. Moving and casting are free.
- **Red zone (Hold still):** Auto Shot is aiming (the last 0.5 s of the cycle, started early by your ping). Moving or casting here delays the shot.
- **Orange flash (Delayed!):** you're moving or casting during the aim, so the shot is being held back. The full 0.5 s aim restarts once you stand still.
- **Grey (Waiting):** the shot is overdue: out of range, not facing the target, or out of ammo.
- **Blue (Ready):** reloaded, with Auto Shot turned off.

A thin **cast lane** above the bar:

- **Cyan:** safe to use instant shots. It dims once you're past the cutoff.
- **Gold:** right after a shot, the moment to start Aimed Shot.

The addon also measures how each ability affects your next Auto Shot on your client (`/sht report`), and updates the cast lane from what it finds.

An optional small bar underneath tracks your melee swing and turns purple when Raptor Strike is queued.

## Appearance

Under Options → AddOns → (this addon) → Appearance: size, font, font size, outline and bar texture. "Match my UI" uses ElvUI's or EllesmereUI's font and bar texture when one of them is loaded, and any font or texture registered with LibSharedMedia can be picked.

Bundles LibStub, CallbackHandler-1.0 and LibSharedMedia-3.0 (LGPL v2.1).

## Commands

- `/sht`: open the options
- `/sht unlock`, `/sht lock`: move the bar (a preview runs while it's unlocked)
- `/sht reset`: put the bar back in the middle of the screen
- `/sht report`: what the addon has measured about each ability
- `/sht resetstats`: clear the measurements

## Install

Download `SimpleHunterTimer-<version>.zip` from the [latest release](../../releases/latest) and extract it into
`World of Warcraft\_classic_era_\Interface\AddOns`, so you end up with `AddOns\SimpleHunterTimer\SimpleHunterTimer.toc`.

## License

MIT, see [LICENSE](LICENSE). Bundled libraries (LibStub, CallbackHandler-1.0, LibSharedMedia-3.0) keep their own licenses.
