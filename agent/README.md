# Agent control (TerminalGravity fork)

This fork lets an agent use or check a specific Ghostty tab by its tab ID,
on macOS and on Linux (Omarchy).

## Get a tab ID

- Right-click the tab and click **Copy Tab ID**. The ID looks like
  `tab-72473fe00` (macOS) or `tab-5609566314d0` (Linux).
- On macOS, `gtab id` prints the ID of the tab it runs in.
- `gtab list` prints every tab: ID, `*` for the selected tab, title,
  working directory.

An ID stays the same while the tab is open. A tab gets a new ID when
Ghostty restarts.

## Use a tab

```sh
gtab read  tab-72473fe00            # text visible now
gtab read  tab-72473fe00 --all -n 40  # last 40 lines, including scrollback
gtab send  tab-72473fe00 'npm test' --enter
gtab key   tab-72473fe00 ctrl-c
gtab focus tab-72473fe00
```

`send` pastes the text. `key` accepts: enter, tab, escape, up, down, left,
right, backspace, ctrl-c, ctrl-d, ctrl-l.

## How it works

- macOS: Ghostty's AppleScript dictionary. The fork adds the read-only
  terminal properties `screen contents` and `visible contents`.
- Linux: each Ghostty process registers `com.mitchellh.ghostty.Control1`
  at `/com/mitchellh/ghostty/Control` on the session bus and owns
  `com.mitchellh.ghostty.Control.p<pid>`. Methods: `ListTabs`,
  `ReadText(id, scrollback)`, `SendText(id, text, raw)`, `Focus(id)`.
  Raw text uses Zig string escapes (`\r`, `\x03`).

Any process of the same user can call these interfaces. That is the same
trust level as AppleScript on macOS.

## Update to a new Ghostty release

1. `git fetch upstream --tags && git rebase vX.Y.Z` on `jack/copy-tab-id`.
2. Use the Zig version in `build.zig.zon` (`minimum_zig_version`).
3. macOS (on the Mac, needs Xcode): `zig build -Doptimize=ReleaseFast -p zig-out-release`,
   then replace `/Applications/Ghostty.app`. Quitting Ghostty closes every tab.
4. Omarchy: update `pkgver`, `_zigver` and the Zig checksums in
   `dist/omarchy/PKGBUILD`, then `makepkg -f` and `sudo pacman -U`.
   Open windows keep running.
