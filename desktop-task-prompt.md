# BDPL dashboard — daily update (Claude Code Desktop scheduled task)

Use this file as the prompt for a **Claude Code Desktop scheduled task** (Routines → New
→ Local) that runs every day at 06:00, with the working folder set to this repository.
It does the same thing as `run-weekly.sh` does with the `claude` CLI, for machines where
the CLI cannot authenticate but the Desktop app can.

Follow these steps exactly, in order. Use the Bash tool for every command.

1. **Pre phase.** Run:
   ```bash
   bash ./run-weekly.sh --phase pre
   ```
   It prints a `RUN PARAMETERS` block and a `RUN-VERDICT` line.
   - If the verdict is not `PRE-COMPLETE`, **stop**. Run `tail -40 .weekly-update.log` and
     report what failed. Do not edit anything, do not commit, do not push.

2. **The update.** Read `daily-prompt.md` and do what it says, using the `RUN PARAMETERS`
   block from step 1 as its run parameters (`RUN_MODE`, `TODAY`, `PREV_RUN_DATE`,
   `SEARCH_WINDOW`). `daily-prompt.md` tells you to read `weekly-prompt.md` as the rulebook;
   do that. Finish with its section D10: commit, **do not push**.
   - Budget: about 60 turns in daily mode, 90 in weekly mode. If you are running out, do
     what D6 says: commit what is verified.
   - Never run `./run-weekly.sh` without `--phase` and never call the `claude` command.

3. **Post phase.** Run:
   ```bash
   bash ./run-weekly.sh --phase post
   ```
   This runs every gate, writes the snapshots, commits the generated files and pushes.
   - If the verdict is `COMPLETE`, the dashboard is published.
   - If it is `INCOMPLETE`, run `tail -40 .weekly-update.log`, report the FATAL line, and
     stop. Do **not** push by hand, and do not bypass a gate. The next morning's run starts
     clean: its pre phase discards a half-finished working tree.

4. **Report** in a few lines: the verdict, the counts from D10, today's headline, and
   anything that failed.
