# Nook

An Alcove-style notch for what you actually use: **Spotify, YouTube (any browser), T3 Code,
ChatGPT and Hermes**. Native Swift, no dependencies, ~19 MB of memory, no polling.

## Flow

| Moment | What the notch does |
| --- | --- |
| **Glance** | Closed, it wraps the camera with "wings" showing exactly one thing, by priority (below). Nothing going on: it disappears into the camera. |
| **Get told** | Song change: the title drops down for 2.6 s. Agent finished or asking for input: a card drops down for 4.5 s; click it to jump to that thread, or hover to open the full panel. |
| **Act** | Hover: it swells with a haptic tick and opens after ~0.1 s (turn off "Open on Hover" to open by click instead). It opens to the tab matching the priority. Move away or click elsewhere to close. |
| **Switch tabs** | Two-finger swipe left/right on the open panel: it follows your fingers and snaps to the other tab, like swiping between Spaces. Vertical scrolling still scrolls the agents list. |
| **Media tab** | Artwork (16:9 for browser video), title, scrubbable progress, controls. Browser video gets ±10 s instead of next/previous. Click artwork to open the player. |
| **YouTube** | Browsers only tell macOS the title and channel, so Nook finds the matching tab: Zen/Firefox from their session file (no permission needed), Safari/Chrome/Arc via AppleScript (macOS asks once). It fetches the 15 KB thumbnail once per video and shows the YouTube logo in the closed notch and on the thumbnail. A just-opened video can take up to ~15 s, because that's how often Zen saves its session. |
| **Agents tab** | Needs-you first, then failed/done (kept 20 min), then working with live duration. Click a row to open it (ChatGPT opens the exact thread; T3 and Hermes come to the front since they have no thread links). Hover a finished row to dismiss it. |

### Priority (closed notch, peeks and default tab)

1. **An agent needs you**: app icon + pulsing orange badge (count if several). Stays until answered.
2. **An agent just finished**: app icon + green check (red ✕ if failed). Shown for 5 min or until you open the agents tab.
3. **Media playing**: artwork + equalizer tinted with the artwork's colour.
4. **Agents working**: app icon + spinner (count if several).
5. **Nothing**: invisible.

Song-change peeks only appear when music is what the notch is showing; an agent needing you is never covered by a song.

Opening Nook again (Tinycast, Spotlight, Finder) while it runs opens the panel; it closes after 5 s if you don't move onto it.

Right-click the notch for **Open on Hover**, **Launch at Login** and **Quit**.

## Why it's light

- **Media is event-driven.** macOS 15.4+ only answers Now Playing queries from Apple-signed
  processes, so `Helper/NookMedia.m` runs inside `/usr/bin/perl` (~0 CPU, exits with Nook). It pushes a
  JSON line only when something changes. Artwork is sent once per track and the position is extrapolated locally.
- **Agents are event-driven.** The apps keep their SQLite files open, and FSEvents only reports writes on
  close, so each database's main file and `-wal` are watched with kqueue. Only the source that changed is re-read
  (read-only), at most once a second while an agent streams. `-shm` isn't watched because our own reads touch it.
  While something is "working", a 30 s safety re-read catches crashes and expired leases.
- **Loops run in Core Animation.** The equalizer, spinner and pulse are CALayer animations rendered by the
  window server, so SwiftUI doesn't redraw every frame. The progress clock ticks only while the panel is open and playing.
- One fixed transparent panel; clicks outside the black shape fall through to the windows underneath.

## Build & run

```sh
./build.sh && open build.noindex/Nook.app    # try it
./install.sh                         # ~/Applications + start it
./install.sh --hermes                # also copy the Hermes plugin, then: hermes plugins enable nook
```

Requires Xcode (for SwiftUI's macros); no project file.

## Debugging

`NOOK_DEBUG=1 build.noindex/Nook.app/Contents/MacOS/Nook` logs every re-read and what each source returned.

## Sources

| Source | Working | Done / failed | Needs you |
| --- | --- | --- | --- |
| T3 Code | `~/.t3/userdata/statev2.sqlite` runs | same | pending questions / approvals |
| ChatGPT (Codex) | `~/.codex` rollout `task_started` | `task_complete` | not saved on disk |
| Hermes | `~/.hermes/state.db` turn leases | lease released | `hermes-plugin/nook` (approvals, `clarify`) |
| Anything else | JSON files in `~/Library/Application Support/Nook/inbox/` | | |

Inbox format: `{"app","title","state":"needs_input|working|done|failed","detail","threadId","openURL","bundleId","updatedAt","expiresAt"}`.
Delete the file to clear it.

## Limits

- These are private storage formats; an app update can break a source.
- Spotify playing on another device (Spotify Connect) isn't visible, only playback on this Mac.
