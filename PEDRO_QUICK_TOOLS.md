# Quick Tools

## Actions

- Native tab: lightning icon, after Shelf. Home and Shelf remain adjacent as in the original app.
- Reads paired hosts and visible apps from Moonlight's existing macOS preferences.
- Launches `Moonlight stream <paired UUID> <app>` using Launch Services arguments.
- Uses at most three equally sized columns, then horizontal scrolling.
- Right-click a host to select another app or a quality profile.
- The MacBook Pro 2012 defaults to H.264, 1280x800, 60 fps, 8 Mbps.
- Other hosts inherit the existing Moonlight settings. Overrides are per host and do not change Moonlight's global preferences.
- A previously launched session is brought forward. If another Moonlight instance is already open, the user chooses whether to return to it or open a connection. Existing streams are never killed.

## Links

- Native tab: link icon, after Clips (internal case remains `pedroCapture`).
- Required HTTP/HTTPS link, optional title and multiline context. The paste icon reads a link only on explicit click and ignores concealed clipboard content.
- Preserves source query strings and fragments. Rejects non-web URLs and embedded credentials. There is no automatic fetching, analysis or categorization.
- Save button / Command-Return writes a unique Markdown file to `~/Documents/Obsidian Vault/inbox/notch`.
- Captures use the vault inbox conventions: `tipo: link`, `projeto: inbox`, `status: pendente`, source `url`, date and `sync: false`; saving does not call Qdrant.
- Existing text-only drafts retain their title and body as optional context. Existing notes remain untouched.
- Drafts survive tab switches and app restarts. Failed saves retain the draft.
- A successful atomic write clears only the matching draft, never new text entered during the write.
- Recent menu opens up to 15 saved notes in Obsidian. The folder button opens the inbox.
- Editing holds the notch open. Escape or the close icon closes it without discarding the draft.
- Only the display under the pointer acquires keyboard focus when tabs are mirrored across monitors.

## Area Screenshot (Clips)

- Camera/viewfinder button in the existing Clips search toolbar; no new tab.
- Runs the native `/usr/sbin/screencapture -i -s -c -x -d` selector: area only, clipboard only, no output filename, no recording or window mode.
- Hides visible mirrored notch windows during selection and restores them after completion, cancellation or launch failure.
- Escape preserves the previous clipboard. Successful captures are ready for native Command-V; nothing is pasted automatically or added to Shelf.
- The existing Clips history observes the copied image normally (including its existing local image cache). No screenshot file is exported to Desktop/Downloads.
- Requests cannot overlap. System capture permissions/errors remain handled by macOS.

## Validation

`Scripts/run-pedro-tests.sh` includes catalogue parsing, unpaired/duplicate hosts, exact CLI argument handling, optional profiles, missing vault, link validation, clipboard protection, URL preservation, optional context, collision protection, legacy draft persistence and failed-save recovery.

## Tab Order

- Daily tools: Home, Shelf, Actions, Clips, Links.
- Indicators: Usage, Alerts, Mac.
- Infrastructure: Status (X99 + NAS), Alienware, Proxmox, Stack.
- Icon sizes and the fixed notch height remain unchanged.

Release builds are installed with an ad-hoc signature. Preserve preferences and keep the previous app in `~/Library/Application Support/PedroEditionBackups`.
