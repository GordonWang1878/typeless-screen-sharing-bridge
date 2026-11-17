# Changelog

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
