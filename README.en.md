# Screen Sharing Bridge for Typeless

English · [中文](README.md)

When you control another Mac with Screen Sharing, dictate with Typeless on your own Mac and the
text lands in a text field on **the remote Mac**, exactly once and without a stray "V".

## Install

Only on **the Mac you talk to** (the one with Typeless): open Terminal, paste this line and follow the prompts:

```bash
curl -fsSL https://raw.githubusercontent.com/GordonWang1878/typeless-screen-sharing-bridge/main/install.sh | bash
```

The setup wizard:

1. lists the Macs with Screen Sharing on your network; you pick the one to control;
2. asks for that Mac's login password once and installs the receiver there for you (nothing to
   install on that Mac yourself);
3. walks you through the permission switches macOS requires: the remote one in your Screen
   Sharing window, the local ones here, with a live ✓;
4. finally asks you to say something and confirms it arrived.

Each run adds one Mac. To control another one, remove one, upgrade or uninstall, run the same
line again.

You can also let your coding agent (Claude Code, Codex, …) do it: give it [AGENTS.md](AGENTS.md).

## Requirements

- macOS and Typeless (signed in on the Mac you talk to)
- Apple's built-in Screen Sharing to control the other Macs
- All Macs on the same local network; the Macs you control need Remote Login on (the wizard
  tells you how)

## What it is like

- With a Screen Sharing window of a controlled Mac in front, dictate as usual: the text appears at
  the remote cursor and Typeless' "Copy last transcript" popup closes by itself.
- **If the popup stays open, that sentence did not arrive**: click Copy and paste it yourself,
  just as Typeless asks you to on a single Mac.
- When Screen Sharing is not in front, nothing changes.

## FAQ

**Is it safe?** Text only travels over encrypted SSH between your own Macs, never through a third
party, and is never logged. Pairing uses a dedicated key and asks you to compare a pairing code, so
you cannot pair with the wrong machine.

**Why do I have to grant permission by hand?** macOS only lets you, not a program, allow apps to
press keys and read window information.

**One Mac is not recognised?** The bridge recognises a Mac by the name of its Screen Sharing
connection, which is that Mac's name. If you renamed a saved connection, rename it back.

**How do I uninstall?** Run the install line again and choose uninstall.

## More

- [How it works, logs and known limitations](docs/details.md)
- Manual install and development: see the header of `install/typeless-bridge.sh`; run the tests with
  `python3 -m unittest discover -s tests`

## License

[MIT](LICENSE). Not affiliated with Typeless.
