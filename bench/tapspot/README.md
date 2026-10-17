# Tap-spot safety

“Tap when stuck” taps one spot the macro's owner picked, on whatever screen is showing. On some screens that spot is a
button: in a live run it landed on a store tab in the bottom bar, and only the price check stopped it. This benchmark
measures a replacement that knows no app: **tap only on empty space**.

`StuckGuard.safeSpot` taps the chosen spot when it's empty, otherwise the nearest empty spot, otherwise nothing. A
fingertip-sized square (36 pt) is empty when:

1. no recognised text is within 10 pt of it;
2. its mean edge strength is low (no icon, glyph or border inside it);
3. no hard edge (a brightness step of 0.06 or more) is within the fingertip's reach in any direction;
4. it isn't enclosed: no hard edges within 60 pt on both sides (above and below, or left and right). A button's
   inside is flat, so 1–3 alone miss taps near a wide button's edge, away from its label;
5. it's inside the app's content: flat bands along the window's edges (a mirrored phone's bezel, a letterbox) are
   skipped, up to a fifth of the window per side, so a tap never lands where it can't do anything.

## Run

```bash
bench/tapspot/run.sh
```

`N=300` sets the synthetic set size. Pass `<folder of stuck screens> <x,y,windowW,windowH>` to also list live screens.
`DUMP=<dir>` / `DUMPREAL=<dir>` / `DUMPLIVE=<dir>` write screens with the spots drawn on them. Results go to
`results/` with the machine and commit.

## Sets

- **Synthetic** (exact ground truth): generated screens with known control boxes (text buttons, tab bars with or
  without labels, icon-only buttons, dialogs, “tap to continue” screens), on plain, textured and blurred real
  backgrounds, at phone and desktop sizes. The stuck-tap spot lands anywhere on the window. Thresholds are fitted on
  seed 1 and reported on seed 2, which is held out.
- **Real** (no control boxes): the 48 labelled stuck screens in `bench/unstuck/data` (local), each with its macro's own
  stuck-tap spot. It reports what can be checked: taps on text, taps on a store screen's never-tap buttons, and
  whether “tap anywhere” screens still get a tap.

## Results (2026-10-17, `results/tapspot-2026-10-17T08-13-19Z.txt`)

Held out, 300 synthetic screens: taps that land on a control (95% Wilson intervals).

| Rule | On a control | No tap |
|---|---|---|
| Fixed spot (before) | 12.0% [8.8–16.2] | 0% |
| Empty space, text only | 9.0% [6.3–12.8] | 0% |
| **Empty space (shipped)** | **1.7% [0.7–3.8]** | **0% [0–1.3]** |

The first attempt, edge density alone (`results/tapspot-2026-10-17T07-38-55Z.txt`), barely moved: a button's flat inside
looks empty. Adding the enclosure test and the fingertip-reach test made the difference.

Real stuck screens (48):

- **Taps on text:** 14.6% before, 0% after. One example is the store tab under the spot on the stage-list screen.
- **Moved taps:** the rule moved the tap on 26 screens and never declined to tap.
- **Store screen:** no never-tap button was touched, before or after.
- **“Tap anywhere” screen:** it still gets a tap.

## Limits

- **Large panels:** a panel bigger than the enclosure reach (60 pt each way) can look empty. In one live store screen,
  the rule's spot was on the edge of a large banner. The price check stops before any tap on such screens, so the rule
  is a second line of defence, not the only one.
- **Bias:** the synthetic generator and the rule were written by the same person. The held-out seed guards against
  overfitting the thresholds, not against blind spots both share. The real set has no control boxes yet; labelling a
  few dozen real screens with boxes would close that gap.
- **Data:** the real set comes from two macros of one game.

## Learned rescue taps (`learned.swift`)

When you tap past a stuck screen yourself, Heron keeps the screen and your tap (`RescueCapture`). With **Learn from
stuck screens** on, a later stuck screen of the same macro that matches one of those (feature-print distance under
0.30) gets your tap instead of a blind one. The nearest earlier screen with any outcome decides, so a screen that once
moved on by itself vetoes it.

Measured online, in time order, predicting from earlier screens only (24 screens with an outcome: 9 rescues and 15
that moved on by themselves):

| Threshold | Rescues right | Elsewhere | Not predicted | Unneeded taps |
|---|---|---|---|---|
| 0.25 | 1 | 1 | 7 | 0 |
| **0.30 (shipped)** | **2** | **1** | **6** | **0** |
| 0.35 | 2 | 1 | 6 | 0 |

It's conservative: it acts only on near-identical screens. With 9 rescues so far it rarely fires, and its reach grows
with use. Run it with:

```bash
swiftc -O -o /tmp/learned bench/tapspot/learned.swift && /tmp/learned "$HOME/Library/Application Support/Heron/Evals/unstuck"
```
