<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Heron icon">
</p>

<h1 align="center">Heron</h1>

<p align="center">
  <b>The free Mac auto clicker that can see your screen.</b><br>
  Click on a timer, replay what you did, or click a button or a word the moment it shows up.
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#everything-it-does">Everything it does</a> ·
  <a href="#private-by-default">Privacy</a>
</p>

<p align="center">
  <img alt="macOS 14 or later" src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white">
  <img alt="License: GPL-3.0" src="https://img.shields.io/badge/license-GPL--3.0-blue">
  <img alt="Free" src="https://img.shields.io/badge/price-free-34C759">
</p>

<p align="center">
  <img src="docs/screenshots/chain.png" width="880" alt="A macro that finds pictures and the word “Claim” in a window and clicks them, with each step's settings beside the list">
</p>

## Why Heron

**It sees the screen.** Point it at a picture or a word in any window, like a Close button or “Claim”, and it
clicks it the moment it appears, wherever it appears. Words are read on your Mac with Apple's built-in text
recognition.

**Record once, see what you did.** A recording shows up as numbered taps and swipes on top of the window,
with a timeline, instead of hundreds of raw events. Drag a tap to move it.

**Runs in the background.** Switch on a macro that clicks pop-ups whenever they show up, while another
macro plays or you keep working.

**A proper auto clicker too.** Set the speed, press a hotkey, done. Simple mode shrinks it to a small strip
that stays on top.

**Free, private and made for the Mac.** No account, no subscription, no network code. Everything stays on
your Mac.

<table>
  <tr>
    <td><img src="docs/screenshots/visual.png" alt="A recording shown as numbered taps, a swipe and a color check on a phone screen, with a timeline"></td>
    <td><img src="docs/screenshots/background.png" alt="A background macro that clicks Skip whenever it appears, with its switch in the macro list"></td>
  </tr>
  <tr>
    <td align="center">Recordings as a map</td>
    <td align="center">Background macros</td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/auto-clicker.png" alt="The auto clicker with a large speed readout and its settings"></td>
    <td><img src="docs/screenshots/simple.png" alt="Simple mode: a small strip with the speed and a Start button"></td>
  </tr>
  <tr>
    <td align="center">Auto clicker</td>
    <td align="center">Simple mode</td>
  </tr>
</table>

## Install

**[Download the latest release](https://github.com/andrew-c-lo/Heron/releases/latest)**, unzip it and drag
Heron to Applications. It runs on Apple silicon and Intel Macs with macOS 14 or later.

Heron isn't notarized by Apple, so the first time you open it macOS asks first: open it once, then
go to **System Settings › Privacy & Security** and click **Open Anyway** next to “Heron was blocked”.
After that, allow the permissions it asks for. A banner links to the right place in System Settings.

<details>
<summary>Build it yourself instead</summary>

It takes about a minute with Apple's free command line tools:

```bash
xcode-select --install     # once, if you don't have the command line tools
git clone https://github.com/andrew-c-lo/Heron.git
cd Heron
scripts/setup-signing.sh   # once: a personal signing certificate, so permissions survive rebuilds
./build.sh install         # builds Heron.app and copies it to /Applications
```

</details>

## Everything it does

<details>
<summary><b>Auto clicker</b></summary>

- Set the speed in clicks a second, or an exact interval in milliseconds
- Left, right or middle button; single, double or triple clicks; hold each click
- Click wherever the pointer is, or cycle through spots you pick by hovering and pressing a hotkey
- Stop after a number of clicks, after some time, or when you press the hotkey
- Vary the timing a little so the rhythm isn't exact
- Only click when the color at a spot matches, picked with the eyedropper or typed as a hex code
- Simple mode: a small strip with just the speed and Start that stays above other windows

</details>

<details>
<summary><b>Record and build macros</b></summary>

- Record mouse moves, clicks, drags, scrolls and keystrokes, or just one app's window
- Or build one step by step: Click, Type, Wait, Find Picture and Find Text are one click each, and the
  selected step's settings show beside the list
- See a macro three ways: a map of the window with every tap, a readable list (“Tap”, “Swipe up”,
  “Type “hello””), or every raw event
- Switch any step off without deleting it
- Replay at any speed, once, a number of times, until stopped or for a set time, with a random pause
  between rounds
- Undo and redo for every edit, and global hotkeys for everything, including a panic stop

</details>

<details>
<summary><b>Finding pictures and words</b></summary>

- A picture step waits for a picture to appear in the window, then clicks it wherever it is. It can also
  just wait for it, or wait until it's gone
- A text step does the same for words, read on your Mac
- Pick pictures by drawing a box on a screenshot, with zoom and pixel-precise handles
- Limit any search to an area of the window, so it's faster and ignores look-alikes elsewhere
- Keep clicking until it's gone, wait before clicking, click at an offset, and choose what happens if it
  never shows up
- Run steps in order, or all at once: every picture is watched together and whichever appears gets clicked
- Test Now shows whether it's on screen right now and how close the match is

</details>

<details>
<summary><b>Background macros</b></summary>

- Any macro can keep running in the background with its own on/off switch, alongside whatever else is
  playing
- “Watch for something” starts one: a picture or some words to click whenever they show up
- Optionally stop after a number of clicks

</details>

<details>
<summary><b>Clicking that stays out of your way</b></summary>

- Jump & return: the cursor jumps to each click and straight back, and waits until you've stopped moving
  the mouse
- Background delivery for apps that accept it, without moving the cursor at all
- Positions are relative to the app's window, so moving the window doesn't break anything
- Optional click spread: each click lands at a random spot near its target, and clicks on a found picture
  always stay inside it
- Optional double-click everywhere: every single click is sent as a double click
- A notification if something stops on its own while you're in another app

</details>

## Private by default

Heron runs entirely on your Mac. It has no accounts, no analytics and no network code at all, and
text recognition happens on-device. Macros are readable `.json` files in
`~/Library/Application Support/Heron` that you can back up, edit or share.

It asks only for the permissions a feature needs:

| Permission | Used for |
|---|---|
| Accessibility | Clicking, moving the mouse and typing |
| Input Monitoring | Recording your mouse and keyboard |
| Screen Recording *(optional)* | Color checks, finding pictures and words, and the map view. Only the target window is read, and nothing is saved except the pictures you pick |

## When something misbehaves

- **A permission stopped working after an update**: remove Heron from that list in System Settings
  › Privacy & Security and add it again
- **The cursor didn't come back after a click**: every jump and return is logged in
  `~/Library/Application Support/Heron/jump-log.txt`
- **A picture isn't found**: use **Test Now** to see how close the match is, crop the picture more tightly,
  or lower the match strictness a little

## Contributing

Issues and pull requests are welcome. `Tests/qa/run.sh` runs the tests (the screenshot cropper, click
spread, double-click, and finding pictures and words), and `scripts/make-demo.sh --screenshots`
regenerates the screenshots on this page from neutral demo data. `scripts/qa-sweep.sh` captures every page at three window sizes in light and dark for a visual check, and
`scripts/release.sh` builds the app for
both kinds of Mac and publishes a release with the notes in `docs/release-notes/`.

## License

GPL 3.0. See [LICENSE](LICENSE).

<p align="center">Made by <a href="https://github.com/andrew-c-lo">@andrew-c-lo</a></p>
