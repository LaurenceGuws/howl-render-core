# Style Correction Loop

Owner: `howl-render`

Purpose: keep render cleanup owner-true, small, and continuous.

## Bias Order

1. TigerBeetle principles first.
2. Ghostty embedding shape second.
3. Alacritty simplicity and speed third.

## Loop

1. Read the local rules first.
   - `../AGENTS.md`
   - `../WORKFLOW.md`
   - `../design/style-law.md`
   - `render-translation-sprint.md`

2. Refocus the owner map.
   - Name the true owner.
   - Name the mixed or bucket-shaped seam.
   - Stop if the owner is not clear.

3. Simplify one bounded frontier.
   - Prefer smaller files, smaller functions, and fewer branch mazes.
   - Move behavior toward the smallest true owner.
   - Do not invent umbrella layers.

4. Check the gates.
   - `zig build`
   - `zig build test`
   - `git diff --check`
   - `nu "../style.nu" --touched-files --json`

5. Commit the checkpoint.
   - Keep the commit narrow and truthful.
   - Do not stop just because one checkpoint committed cleanly.

6. Restart the loop.
   - Re-read the owner map.
   - Take the next bounded frontier.
   - Keep driving until the work is not clear.

## Stop Rule

Stop only when ownership, boundary, or proof becomes unclear.
