# MiaOS

PS5-targeted gaming + desktop distro. Arch base + a few hundred packages,
no upstream-distro lock-in.

## Two modes

`gamer/gamer` auto-logs in on tty1 and reads `/etc/ps5-mode`:

- `gaming` (default) — launches `gamescope --steam -- steam -gamepadui
  -bigpicture`. Boots straight into Steam Big Picture, controller works.
- `desktop` — launches `startplasma-wayland` for a KDE Plasma 6 session.
  Konsole, Dolphin, Kate, Firefox available.

Switch with `desktop-mode` / `gaming-mode` (sudo-NOPASSWD from the `gamer`
user; both are also wired up as Steam library shortcuts).

## Build

`./build_image.sh --distro miaos`

See `image.yaml` for the full package list + post-install setup.
