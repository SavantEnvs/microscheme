/*
 * mayhem/microscheme_wrapper_main.c -- self-contained writable-scratch fix for the microscheme
 * fuzz target, WITHOUT a Mayhemfile `cwd:` key.
 *
 * Root cause (confirmed empirically, see mayhem/Mayhemfile comment + docs/netnew-worker-prompt.md
 * SS6d): microscheme derives its output filename from the INPUT filename (strip dir + extension,
 * append ".s") and fopen()s it relative to the process's CURRENT WORKING DIRECTORY (src/main.c) --
 * there is no flag to redirect it. Mayhem's image is read-only during coverage collection, so the
 * process needs to be running with cwd already pointed at a writable location (e.g. /tmp).
 *
 * The Mayhemfile previously set a per-cmd `cwd: /dev/shm` to get that writable cwd. That is WRONG
 * for a raw (non-libfuzzer), process-per-input executable target on this Mayhem version: it makes
 * mayhem-fuzz itself enter a restart loop (rc 254), NOT the target -- confirmed both by direct
 * reproduction (the target runs cleanly rc=0/1 over every seed, under --read-only --tmpfs /tmp,
 * with NO cwd key at all -- see the Mayhemfile header) and by a fleet-wide pattern: every other raw
 * file-input target in this tree that sets a per-cmd `cwd:` (asn1c/asn1c, compiler/pawncc,
 * abc/demo, svf/saber) is ALSO stuck at edges=0/broken, while the raw targets that avoid `cwd:`
 * entirely (armips, dasm, chaos) are confirmed green. `cwd:` under `cmds:` works fine for
 * `libfuzzer: true` targets (many confirmed green in this tree) -- it is specifically the raw
 * process-per-input supervision path that chokes on it.
 *
 * ROUND 2: dropping `cwd:` alone was NOT sufficient -- a cloud run still rc-254 restart-looped
 * with this wrapper in place plus a Mayhemfile-level `filepath: /tmp/in.ms`. The second gap: no
 * confirmed-green raw file-input target in this tree pins `filepath:` under /tmp (armips uses
 * `/input.asm`, hh-suite/hhmake uses `/test.fa`, pawn/pawncc -- the closest analog, another
 * single-file compiler CLI -- uses `/test.p`), and the two closest analogs of all, dasm and chaos,
 * set no `filepath:` at all (bare `@@`). The Mayhemfile now matches dasm/chaos exactly: no
 * `filepath:`, bare `@@`. This wrapper's chdir("/tmp") is unaffected either way -- it only needs
 * the process's cwd writable for the *output* .s file; fopen() of the absolute `@@` input path
 * doesn't care what the cwd is.
 *
 * Fix: do the chdir INSIDE the binary instead of asking Mayhem's supervisor to do it. mayhem/build.sh
 * compiles all of microscheme's own sources with `-Dmain=microscheme_original_main` (there is exactly
 * one `main` in src/main.c, so this is a plain, fully-additive preprocessor rename -- no upstream
 * file is edited), and this file supplies the REAL `main()`: chdir("/tmp") once, unconditionally,
 * before handing off to the renamed original. Mirrors the exact same pattern already proven in this
 * tree for chaos's hang bound (mayhem/chaos_watchdog_main.c, `-Dmain=chaos_original_main`).
 */
#include <stdio.h>
#include <unistd.h>

extern int microscheme_original_main(int argc, char **argv);

int main(int argc, char **argv)
{
    if (chdir("/tmp") != 0)
    {
        perror("mayhem: chdir(/tmp)");
        return 1;
    }

    return microscheme_original_main(argc, argv);
}
