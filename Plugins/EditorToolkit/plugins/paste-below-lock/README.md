# Paste Below Lock

Pasted clips never land above your locked adjustment layers (anything with `lock` in the name). The exception is a clip that was copied from above a lock, which may stay there.

## Why

Final Cut pastes a connected clip into the first free lane, which on a finishing timeline is usually *above* the grade layer, so the pasted shot comes out ungraded. Moving it down by hand after every paste is slow and easy to miss.

## How it works

- On copy/cut it records which locks each clip sat above.
- After the paste, a new clip that ended up above a lock it was *not* above at the source is moved to the lane just above the unlocked clips under the lock.
- If there's no free lane under the lock, only what's actually in the way is pushed up one lane, so the rest of the stacking stays exactly as it was.
- Happens inside Final Cut's own Paste action: one undo step.

## Requires

Nothing. Uses the same `lock` naming as Grade Lock.

## Install

```sh
./install.sh paste-below-lock
```

Then restart Final Cut Pro. Remove with `./install.sh --uninstall paste-below-lock`. Log: `~/Library/Logs/SpliceKit/`.
