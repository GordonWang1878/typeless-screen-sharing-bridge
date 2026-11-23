# Changelog

## 1.0.1 — 2026-11-23

- The setup window's home page shows versions: the one just downloaded, and the one installed on
  this Mac and on each Mac you control. When something is older the main button reads
  "Upgrade to …"; when everything is current it reads "Reinstall". Installs now record their
  version (older installs show as "1.0.0 or earlier").
- Added fault diagnosis: when a sentence reaches the remote Mac but Typeless' own paste was not
  stopped (a stray "V"), the log now records `GUARD_MISSED`, and the guard notes why it let
  Typeless' paste through (yes/no answers only). The cause of this fault is not known yet: once,
  macOS kept reporting the guard as allowed while it no longer received anything. The README
  describes how to recover (remove the guard in Device Control and switch it on again); this
  does not prevent the fault from happening again.
- README rewritten as a landing page, in Chinese and English: what it solves (including that
  clicking Copy does not reach the remote Mac until its Screen Sharing window is activated again),
  a three-step picture and screenshots of the setup window, each in light and dark. The pictures
  are left out of the download used by the one-line install.

## 1.0.0 — 2026-11-18

- **A setup window replaces the terminal wizard.** The one-line install builds it on your Mac
  (a progress spinner shows while it does, about 30 s the first time) and brings it to the
  front. Five steps in a sidebar: check this Mac, choose the Mac to control, set it up, set up
  this Mac, try it. Run the line again to add, remove, upgrade or uninstall.
- Each page shows what is happening now: a checklist that ticks as work finishes, an estimated
  progress bar for the longer waits, and a highlighted "your turn" card whenever only you can
  act, with every permission switch ticking live as you turn it on.
- While you allow the receiver on the controlled Mac, a small hint appears on that Mac's screen
  (visible in your Screen Sharing window); a button brings Screen Sharing to the front.
- The Mac's password is typed once in the window, used for that login only and never stored.
  Back returns to the list if you picked the wrong Mac.
- A live test ends the setup, followed by the one thing to remember: if Typeless' copy popup
  stays open, that sentence did not arrive. A chime plays when everything is ready.
- Retry resumes a failed step; problems and hints are shown in place, in Chinese or English.
- Fixed: Macs were not listed between midnight and 10:00 (also in 0.9.x).
- Macs with non-English names get distinct internal names.
- The terminal wizard (`./setup`) remains for coding agents and terminal users.

## 0.9.2 — 2026-11-17

- A Screen Sharing connection made by DNS name (for example a Tailscale name such as
  `studio.tail1234.ts.net`) is recognised by its first label. For Macs on another network,
  pick "enter its address" in the wizard. Not yet tested on such a setup.

## 0.9.1 — 2026-11-17

- Renamed to **Screen Sharing Bridge for Typeless** (repository
  `typeless-screen-sharing-bridge`): it works with Apple's Screen Sharing only, and is not an
  official Typeless product.

## 0.9.0 — 2026-11-17

First release (terminal setup wizard; private preview before 1.0).

- One-line install that starts a setup wizard on the Mac you talk to. Each run adds one Mac you
  control with Screen Sharing: it installs the receiver there over SSH, guides the permission
  switches on both Macs, and ends with a live test. Run it again to add, remove, upgrade or
  uninstall.
- Text dictated with Typeless lands once at the remote cursor, without a stray "V".
- Typeless' copy popup closes only after the sentence was delivered; if it stays open, the
  sentence did not arrive and can be copied by hand.
- Remote Macs are recognised by name, whatever account you log in with.
- Wizard in Chinese or English, following the system language.
