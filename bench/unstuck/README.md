# Unstuck eval

What should an automation do when none of its steps match the screen? Heron's answer used to be one fixed
"stuck tap". This eval scores alternatives on real stuck screens.

## Data (local only, `data/`, gitignored)

- `screens/`: stuck screens saved by Heron while macros ran (real app screenshots, kept off the public repo).
- `labels.json`: the right outcome per screen: `target` (tap a specific thing), `anywhere`, `wait` (an animation
  that finishes by itself; a tap is harmless), `none` (tapping would be unsafe, e.g. a shop with prices), `stop`
  (the macro's goal is reached: the run should end). `alt` records the answer under a different macro intent.
- `macros/`: frozen copies of the macros the screens came from (their pictures, steps and goals).
- The **practice set** (48 screens, labelled by hand) was used while building the strategies. The **fresh set**
  (`set: fresh`) is collected by Heron while playing (`run.sh collect`): your own click after it got stuck
  ("rescue") or a step firing soon after with no help ("resolved"). Only fresh results are unbiased.

## Strategies

| name | what it does |
|---|---|
| `fixed` | today's behaviour: the macro's stuck-tap spot |
| `wait` | never tap |
| `repeat-stop` | the stuck tap, but stop when the previous stuck screen looked the same |
| `repeat-stop-3`, `guarded` | as shipped in Heron: stop after two taps in a row left the screen unchanged; `guarded` also never taps a screen showing 2+ prices (42/48: taps 4/6, finished runs 7/11, shop refused) |
| `memory` | repeat what was right on an almost identical earlier screen (Vision feature-print distance < 0.30) |
| `model-point`, `model-choose` | Apple's on-device model (macOS 27, image input) names a position / a thing to tap from the text and step pictures on screen, given the macro's goal |
| `model-memory` | `model-choose` plus what happened on the 3 most similar earlier screens |
| `knn-fixed` | ablation: knn decides whether to tap; the location is the fixed stuck-tap spot (45/48, but only because that spot happens to sit near the dice here) |
| `knn`, `logreg` | learned classifiers on the feature-print vector (k-nearest neighbours; Create ML logistic regression), retrained on earlier screens only (rolling evaluation) |

Retrieval and training only ever see screens from **before** the one being decided, so nothing leaks from the future.

## Results so far (practice set, 2026-10-17, Apple M5 Pro, macOS 27.2)

| strategy | right / 48 | needs a tap /6 | finished run /11 | shop | unsafe taps | time |
|---|---|---|---|---|---|---|
| fixed | 34 | 4 | 0 | no | 0 | – |
| wait | 42 | 0 | 11 | yes | 0 | – |
| repeat-stop | 42 | 4 | 8 | no | 0 | – |
| model-choose | 41 | 2 | 8 | yes | 0 | 1.4 s |
| model-memory | 43 | 1 | 11 | yes | 0 | 1.6 s |
| knn | 44 | 2 | 11 | yes | 0 | ~0 s |
| logreg | 44 | 2 | 11 | yes | 0 | 0.8 s (incl. retraining) |

Paired bootstrap (10,000 resamples): every learned or rule-based strategy beats `fixed` (logreg +10 screens,
95% CI +3 to +17). Differences among the better strategies are within noise (logreg vs repeat-stop +2, CI −3 to
+7; logreg vs model-memory +1, CI −2 to +4). Conclusion so far: the cheap learned classifier matches the language
model at a fraction of the cost; which is best is for the fresh set to decide.

## Run

```
bench/unstuck/run.sh collect            # add screens Heron captured while playing
bench/unstuck/run.sh candidates         # text and step-picture candidates per screen
bench/unstuck/run.sh eval fixed repeat-stop knn logreg model-memory
EVAL_SET=fresh bench/unstuck/run.sh eval …   # the unbiased number
```

Results are written to `results/` (local) with the machine, OS and commit.
