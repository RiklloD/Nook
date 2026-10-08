# Nook

An Alcove-style notch for what you actually use: **Spotify, YouTube and other sites (any browser),
T3 Code, ChatGPT/Codex, Hermes, Claude Code and OpenCode**. Native Swift, no dependencies, event-driven.

## Flow

| Moment | What the notch does |
| --- | --- |
| **Glance** | Closed, it wraps the camera with "wings" showing exactly one thing, by priority (below). Nothing going on: it disappears into the camera. |
| **Get told** | Song change: the title drops down for 2.6 s. Agent asking for input: a card drops down for 4.5 s; click it to jump to that thread, or hover to open the full panel. Agent finished: no card, the wings swell once. |
| **Act** | Hover: it swells with a haptic tick and opens after ~0.1 s (turn off "Open on Hover" to open by click instead). It opens to the tab matching the priority. Move away or click elsewhere to close. |
| **Switch tabs** | Two-finger swipe left/right on the open panel: it follows your fingers and snaps to the other tab, like swiping between Spaces. Vertical scrolling still scrolls the agents list. |
| **Media tab** | Artwork (16:9 for browser video), title, scrubbable progress, controls. Browser video gets ±10 s instead of next/previous. Click artwork to open the player. |
| **Websites** | Browsers only tell macOS the title and channel, so Nook finds the matching tab: Zen/Firefox from their open tabs (session file) and, for a page opened since that was saved, their history; Safari/Chrome/Arc via AppleScript (macOS asks once). A loose title match only counts when it points at a single page. Nook then shows the site's icon and name and the video's thumbnail (YouTube's own, Twitch's live frame, otherwise the page's `og:image`). |
| **Agents tab** | Needs-you first, then failed/done (kept 20 min, longer until you've seen them), then working with live duration. Click a row to open it: ChatGPT and Hermes open the exact thread, CLI sessions their terminal tab or editor window, T3 comes to the front (it has no thread links). Hover a finished or waiting row to dismiss it. |

### Priority (closed notch, peeks and default tab)

1. **An agent needs you**: app icon + pulsing orange badge (count if several). Stays until answered or
   until you click it; a later question in the same thread shows again.
2. **An agent finished and you haven't hovered the notch since**: app icon + green check (red ✕ if failed).
3. **Media playing**: artwork + equalizer tinted with the artwork's colour.
4. **Finishes you've seen but not clicked**: they come back when the media pauses.
5. **Agents working**: app icon + spinner (count if several).
6. **Nothing**: invisible.

With several agents, each distinct app gets its own logo in the wings.

Song-change peeks only appear when music is what the notch is showing; an agent needing you is never covered by a song.

Opening Nook again (Tinycast, Spotlight, Finder) while it runs opens the panel; it closes after 5 s if you don't move onto it.
Opening it once more while the panel shows opens **Settings** (Launch at Login, Open on Hover, Quit).
Right-click the notch for the same switches plus **Settings…**.

Nook turns on Launch at Login the first time it runs; after that the switch is yours.

## Why it's light

- **Media is event-driven.** macOS 15.4+ only answers Now Playing queries from Apple-signed
  processes, so `Helper/NookMedia.m` runs inside `/usr/bin/perl` (exits with Nook). It pushes a
  JSON line only when something changes. Artwork is sent once per track and the position is extrapolated locally.
  While something plays it re-reads every 3 s, because a closed tab or quit player doesn't always say it stopped.
- **Agents are event-driven.** The apps keep their SQLite files open, and FSEvents only reports writes on
  close, so each database's main file and `-wal` are watched with kqueue. Only the source that changed is re-read
  (read-only), at most once a second while an agent streams. `-shm` isn't watched because our own reads touch it.
  While something is working or waiting on you, a 30 s safety re-read of just those sources catches crashes and
  expired leases, and one timer fires when a finish ages out or an inbox record expires.
- **Loops run in Core Animation.** The equalizer, spinner and pulse are CALayer animations rendered by the
  window server, so SwiftUI doesn't redraw every frame. The progress clock ticks only while the panel is open and playing.
- One fixed transparent panel; clicks outside the black shape fall through to the windows underneath.

## Build & run

```sh
./build.sh && open build.noindex/Nook.app    # try it
./install.sh                         # /Applications (or ~/Applications) + start it
./install.sh --claude                # also add the Claude Code hooks (they run the installed Nook.app)
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
| Hermes | turn leases in `~/.hermes/state.db` and every profile's `~/.hermes/profiles/<name>/state.db` | lease released; failed unless the last message is the final answer | `hermes-plugin/nook` (approvals, `clarify`) |
| Claude Code | hooks (`./install.sh --claude`) run `Nook --claude-hook`, which keeps only the session, event, folder and transcript path | `Stop` / `StopFailure` | approval and question notifications |
| OpenCode | `~/.local/share/opencode/opencode.db` user message after the last idle | `idle` message outcome | not saved on disk |
| Anything else | JSON files in `~/Library/Application Support/Nook/inbox/` | | |

Inbox format: `{"app","title","state":"needs_input|working|done|failed","detail","threadId","openURL","bundleId","updatedAt","expiresAt"}`
(`app` and `state` required; times in Unix seconds). Delete the file to clear it, or set `expiresAt`. The inbox is
owner-only (0700), and `openURL` can't be a `file://` URL. A new `updatedAt` on a `needs_input` record is a new question.

Clicking a CLI session (Codex, Claude Code, Hermes, OpenCode) goes to where it runs. Nook takes the
CLI's process (the hook's parent for Claude Code; otherwise the process running in the session's
folder), follows its parent processes up to the app, and then selects the Terminal/iTerm tab by tty,
focuses the VS Code/Cursor/Windsurf window holding that folder, or brings any other app (Ghostty, Yab,
Claude) to the front. Sessions T3 Code drives are listed once, under T3.

## Limits

- These are private storage formats; an app update can break a source. Run with `NOOK_DEBUG=1` to see failed reads.
- A Codex or OpenCode turn whose session hasn't been written for 6 hours is taken as abandoned.
- Previews are only fetched from public http(s) sites (never this Mac or the local network, redirects included),
  with size limits, no cookies and nothing cached on disk.
- Spotify playing on another device (Spotify Connect) isn't visible, only playback on this Mac.
