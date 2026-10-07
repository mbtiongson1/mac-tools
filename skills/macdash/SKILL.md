---
name: macdash
description: "Launch the macOS system dashboard in a visible Herdr terminal pane. Use when the user asks to run, show, or monitor macdash live."
---

# macdash

Launches `/Users/marcotiongson/macdash` in a visible Herdr pane. The dashboard is interactive (`q` quits; `r` resets graphs; `+`/`-` adjust refresh speed).

## Run live in Herdr

1. Verify Herdr context before controlling panes:

   ```sh
   test "${HERDR_ENV:-}" = 1
   ```

   If false, stop and explain this session is not inside Herdr.

2. Inspect caller layout and split direction to use, preserving the caller's working directory and focus:

   ```sh
   herdr pane layout --pane "$HERDR_PANE_ID"
   ```

   Split right when the caller area is wide; split down when narrow/tall. Create a sibling with `--no-focus`.

3. Start macdash in the new pane:

   ```sh
   herdr pane split --current --direction right --cwd /Users/marcotiongson --no-focus
   herdr pane run <new-pane-id> "/Users/marcotiongson/macdash"
   ```

   Use the returned `.result.pane.pane_id`; do not guess IDs. For an accessible dashboard, a pane height of roughly 20 rows is sufficient. If splitting is impractical, use the nearest suitable existing shell pane only with explicit user direction.

4. Read the pane output to verify it launched:

   ```sh
   herdr pane read <new-pane-id> --source visible --lines 40
   ```

   Keep user focus in the original pane. The dashboard runs interactively until the user quits it. Do not use `--once` for a live view.

## Install / files

The launcher expects `macdash.py` beside it. Both are installed in `/Users/marcotiongson`. The standalone source is under `Documents/Codex/.../outputs/`. If the launcher reports a missing script, check both paths and copy the Python script alongside the launcher.
