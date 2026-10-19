# Additions inspired by Vorssaint

The existing Codex app-server reader, agent hooks, clipboard, Shelf, status,
phone integration and music remain in place.

## Dock previews

Hover a running app's icon in the macOS Dock for about half a second. A separate
panel beside the Dock shows that app's windows. Click a thumbnail to activate
its window. There is no window-preview tab in the notch. Bottom, left and right
Dock positions and multiple screens use the icon's screen coordinates.

Accessibility is needed to recognize the Dock icon and raise windows. Screen
Recording is needed for images. The menu-bar menu contains the enable switch
and permission action. Only standard app windows are listed, once per window;
invisible helpers are excluded. Visible and minimized windows are supported.
Images stay in memory, at most 24 thumbnails of at most 560 x 360 pixels, and
are discarded on dismissal. Capture stops on screen lock. Windows macOS does
not expose or cannot capture show an unavailable message, never an icon posing
as a preview. Capture uses Vorssaint's dynamically resolved WindowServer method
on a serial background queue, with ScreenCaptureKit as a fallback. The private
WindowServer symbols may be unavailable on future macOS releases. An ambiguous window match
activates the app instead of raising a different window.

## Mixer

The Mixer tab controls each audio app from 0 to 200 percent, mute and per-app
output routing. It uses CoreAudio process taps and private aggregate devices;
no audio driver is installed. At 100 percent on the system output, the original
audio stays untouched. Audio remains local and is never saved to a recording.
The OS may ask for system audio capture permission on the first adjustment.

Volumes and routes persist locally. Disappearing output devices fall back to
the system output. A failed tap or stalled rendering restores the original
path and reports an error. Restore 100% clears saved routes and levels.
Vertical scrolling in the Mixer tab does not trigger the notch close gesture.
Zoom, Teams, Logic and Ableton retain their own audio handling. AirPlay-specific
streaming is not included; routes use CoreAudio output devices.

## AI history

Usos > Histórico adds Today/7 days/30 days counters grouped by agent, model or
project for Claude Code, Codex and OpenCode. API-equivalent USD values are
estimates and are separate from subscription quota or actual invoices. Models
without a matching price show unpriced usage instead of an invented amount.
Optional price-list updates fetch a public JSON list and send no usage.

The incremental reader retains only counters and metadata, not conversation
text. Its local cache lets subsequent launches resume reads. Local Claude
Desktop usage is a fallback when the existing API fails; estimated reset
times are descriptive and never automatically zero quota. OpenCode sessions
are read-only snapshots from its database and open the OpenCode app; there
are no OpenCode approval hooks or exact-session deep links.

## Compact account limits

Usos > Uso shows Claude, Codex and Gemini in three equal cards without scrolling.
Gemini reads only the native Usage Limits settings window through Accessibility;
it does not open or navigate Gemini or traverse conversation content. The two
quota percentages and displayed reset descriptions are cached locally. Closing
that settings window retains the observation as stale; no quota is guessed from
API tokens, and inferred resets never zero the cached Gemini values. Reopen
Gemini > Settings > Usage limits to refresh the observation.

## Attribution

The AgentUsage reader/pricing/cache modules, MixerRender, BoostLimiter and the
adapted TapGainEngine and WindowServer capture adapter originate from Vorssaint, copyright 2026 Vorssaint,
GPL-3.0-or-later. Upstream source commit:
aa6ddcb901acb0a61f6bfc9ed4753c6fbffcf958.
https://github.com/vorssaint/vorssaint-utils

Original copyright and SPDX headers are retained. This repository already
contains GPL v3. No Vorssaint logo, name or visual identity is used by the app.
