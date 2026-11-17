# Installing Screen Sharing Bridge for Typeless for a user (instructions for coding agents)

Goal: the user dictates with Typeless on one Mac (the **sender**) and the text lands in the Mac
shown in a Screen Sharing window (a **receiver**). Every Mac involved needs this installed.

## Preferred: let the user run the wizard

Ask the user to run this in Terminal **on the Mac they talk to only**, and to answer its questions.
Each run adds one controlled Mac and installs the receiver there over SSH:

```bash
curl -fsSL https://raw.githubusercontent.com/GordonWang1878/typeless-screen-sharing-bridge/main/install.sh | bash
```

The wizard is interactive (pick a Mac, its password once, permission switches, final test). Running
it yourself only works if you can hand the user a real terminal.

## If you must drive it step by step

Work from a checkout (`git clone https://github.com/GordonWang1878/typeless-screen-sharing-bridge`), as the
logged-in user, no sudo. The engine is `install/typeless-bridge.sh`.

1. **Receiver Mac**
   - Remote Login must be on: System Settings → General → Sharing → Remote Login (the user turns it on).
   - `install/typeless-bridge.sh install --receiver`
   - Ask the user to add `~/Library/Application Support/TypelessRemoteBridge/Apps/TypelessBridgeReceiver.app`
     in System Settings → Privacy & Security → Device Control and switch it on.
     You can help with `open -R "<that app>"` and
     `open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"`.
   - `install/typeless-bridge.sh status` must show `receiver health: {"status":"ready"}`.
   - Note its host key fingerprint: `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`.
2. **Sender Mac** (Typeless installed and signed in; Command Line Tools: `xcode-select --install`)
   - For each receiver pick a name (lowercase letters, digits, `-`) and have the **user** run
     `install/typeless-bridge.sh pair NAME USER@HOST --fingerprint SHA256:...` with the fingerprint
     from step 1. It asks for the receiver's password once; the user types it, not you.
   - `install/typeless-bridge.sh install --sender NAME1,NAME2`
   - The user adds `TypelessBridgeGuard.app` and `TypelessBridgeProbe.app` in Device Control.
   - `install/typeless-bridge.sh status`; `~/Library/Logs/TypelessRemoteBridge/sender.log` shows
     `PILOT_READY`.
3. **Test**: the user opens the Screen Sharing window of a receiver, clicks into a text field and
   dictates. `sender.log` should show `TARGET NAME`, `RESULT paste-sent-unconfirmed`, `POPUP_CLOSED`.

To upgrade: pull, then `uninstall` and `install` again with the same options. Changed apps must be
removed from Device Control with "−" and added again.

## Do not

- Grant permissions, edit the TCC database or click in System Settings on the user's behalf.
- Type the user's password for them.
- Open Typeless' database, recordings or settings, or put transcripts in logs or arguments.
- Run a second sender on the same Mac (it would paste twice).
