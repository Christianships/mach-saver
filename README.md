# mach-saver

Screensavers for **MACH**, my macOS desktop setup. It's the sibling of
[mach-boot](https://github.com/Christianships/mach-boot): mach-boot plays at
login, mach-saver plays while you're away.

**Mach Saver** is a menu bar app that works like Amphetamine. It keeps your Mac
awake while an agent (Claude Code, Codex, Gemini, …) is working and,
once you step away, covers the screen with the active screensaver. Any key or
mouse move brings you back.

![Afterburner](docs/afterburner.png)

*`afterburner`: a braille jet filling the screen with MACH in large letters
across its middle. Like Omarchy's screensaver, MACH plays one
[terminaltexteffects](https://github.com/ChrisBuilds/terminaltexteffects)-style
effect after another at random: decrypt, beams, rain, slide, expand,
scattered, middle-out, print, unstable, burn, waves, matrix, spray, crumble
and sweep. `AFTERBURNER_EFFECT=<name>` starts on a given one.*

## Quick start

```sh
make install          # build, copy to ~/Applications, link the mach-saver command
mach-saver show       # show the screensaver now
```

Click the flame in the menu bar (or open **Mach Saver** from Spotlight or
Finder) for the panel; right-click the flame for the menu.

## Commands

| Command | What it does |
|---|---|
| `mach-saver show` | Show the screensaver now |
| `mach-saver start` | Start a session: screensaver up and Mac awake, agents or not, until you dismiss it |
| `mach-saver stop` | End the session |
| `mach-saver toggle` | Start or end a session |
| `mach-saver list` | List screensavers; `*` marks the active one |
| `mach-saver use <name>` | Switch the active screensaver |

The panel (styled after [MouseSkins](https://github.com/Christianships/MouseSkins))
drops down from the flame. **Home** has the screensaver running live with
whether it's keeping you awake and why, plus the colour, keep-awake mode and
idle delay; **Agents** edits which programs count as agents; **Settings** has
launch at login, lock and quit. The panel is its own short-lived process, so
the menu bar app stays small; they talk over distributed notifications.

In AeroSpace I bind it to Super+|:

```toml
ctrl-shift-backslash = 'exec-and-forget open -g mach-saver://show'
```

## How it decides

The screensaver only comes up two ways:

1. **You call it**: `mach-saver://show` (the AeroSpace binding above) or
   `mach-saver show`/`start`. It stays up, and your Mac awake, until you come
   back and dismiss it. Opening the app just opens the panel.
2. **An agent is working and you've stepped away**: every 10 seconds it looks
   for processes started as one of `agentNames`
   (`defaults read com.christianaguilar.mach-saver agentNames`) and checks
   whether they're busy: using 4% or more of a core, counting the tools and
   builds they've started. An agent sitting idle at its prompt uses about 1-2%.
   While one is working (and for 90 seconds after, to ride out pauses) it holds
   a `PreventUserIdleDisplaySleep` assertion, like `caffeinate -d`. After
   `idleMinutes` (default 2) with no keyboard or mouse input, the screensaver
   covers every display, and resets macOS's idle timer while it's up so the
   system screen saver doesn't start on top.

Otherwise it holds nothing: with no agent working, macOS sleeps and locks as
usual, even with agent windows open. When the agents finish, it takes the
screensaver down and lets go.

In the background it checks in every 5 seconds and scans agents every 10;
the screensaver draws from the display's refresh at up to 30fps and stops
drawing when the display sleeps.

While it's keeping you awake your Mac won't auto-lock. Use Lock Screen in the
menu (or Ctrl-Cmd-Q) when you walk away.

## Adding a screensaver

Each screensaver is a folder under `screensavers/`:

```
screensavers/<name>/
  <Name>.swift      a ScreensaverView subclass + a static `screensaver`
  *.txt, *.png …    assets, bundled into Resources/<name>/
```

1. Subclass `ScreensaverView`: override `advance(_ dt:)` to step the animation
   and `draw(_:)` to render it. The app handles windows, timing and dismissal.
2. Give it a `static let screensaver = Screensaver(id:title:make:options:)`.
3. Add it to `Screensavers.all` in `App/Screensaver.swift`.
4. `make snapshot` renders `docs/<name>.png` to check it without taking over the screen.

## Afterburner

- The jet is `screensavers/afterburner/jet.txt`, braille generated from
  `tools/jet-source.png` with `make jet`. The same file is my fastfetch logo.
- Its menu has Fire Color (Purple, Classic Fire, Mono) and Logo, which takes
  any fastfetch-style text logo (braille or ASCII; `$1` colour markers are ignored).
