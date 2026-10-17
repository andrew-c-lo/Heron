# Screen kind (on-device model)

Can Apple's on-device model tell what kind of screen a stuck screen is (store, results, loading, battle, menu, map,
dialog, other), in any app? If it could, “what kind of screen is this” would say more than where to tap: never tap a
store, wait on loading, and so on. `ShadowAdvisor.screenKind` asks it. The answer is recorded beside every stuck
screen (shadow mode) and nothing acts on it yet.

## Run

```bash
bench/screenkind/run.sh [file=kind ...]
```

The truth comes from the notes on the labelled stuck screens (`bench/unstuck/data/labels.json`, local), mapped to
kinds by keyword. Extra screens can be added as `file=kind`. It needs macOS 27 with Apple Intelligence on.

## Results (2026-10-17, `results/screenkind-2026-10-17T08-02-05Z.txt`)

These are 51 screens: the 48 labelled ones, plus two live store screens and one live stage list.

- **Accuracy:** 37/51, 0.69 s a screen.
- **Store:** 3 found, 0 missed, 0 false alarms on the 48 others. With only 3 positives, the false-alarm rate could
  still be up to about 7%. Checks run on every stuck screen, so that would end runs needlessly.
- **Errors:**
  - battle effects called “results” or “loading” (9);
  - the stage list called “results” (3).

  The second error rules it out for spotting the end of the line.

## Decision

It stays in shadow mode. The price check (`StuckGuard.looksLikeShop`) remains the store guard. Re-run as stuck screens
accumulate. Store precision on more than a handful of positives is what would let it act.
