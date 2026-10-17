# Lumio

<img src="Resources/Brand/mark.png" alt="" width="96">

Lumio is a local macOS 15+ screen recorder and editor built with SwiftUI, ScreenCaptureKit and
AVFoundation. Everything runs on the machine it is installed on: there is no hosted service, no account
and no runtime package dependency. The source here is the whole application.

## Build and install

Requirements: macOS 15 or newer, Xcode Command Line Tools, Python 3 (used by the build scripts).

```sh
./scripts/install.sh      # builds, signs and copies to /Applications
open /Applications/Lumio.app
```

`scripts/build.sh` alone builds into `~/Library/Caches/Lumio/Build.noindex` without installing.

On macOS 26 and newer the SwiftUI macro plugin that `@State` needs ships with Xcode rather than with the
Command Line Tools. When it is missing the build falls back to the previous SDK automatically; nothing
needs to be set by hand.

### Signing, and why it matters here

The build signs the app so that macOS keeps the screen-recording, camera and microphone permission you
granted. Without a certificate it signs ad hoc, which works but changes the app's identity on every
build, so the permissions have to be granted again each time. To make a local certificate once:

```sh
# Keychain Access → Certificate Assistant → Create a Certificate…
#   Name: Lumio Local Code Signing   Type: Code Signing   Self-signed
# then put the keychain and its password in ~/Library/Application Support/Lumio/Signing
```

### Artwork that is not in this repository

Some things Lumio can draw with are other people's work and are not redistributed here:

- `Resources/Cursors/Magnific/` — stock cursor vectors, attribution and sources in the folder's
  `MAGNIFIC-ATTRIBUTION.md`.
- `Resources/Cursors/CustomCursor/` — fan-art cursor packs; the sources and the rights holders are
  listed in `CUSTOM-CURSOR-SOURCES.md`.
- `Resources/Wallpapers/` and `Resources/Audio/` — background images and the bundled music beds
  (`scripts/generate-audio.py` regenerates the music, which is synthesised rather than sampled).

Lumio builds and runs without any of them; those cursor styles simply fall back to the drawn cursors and
the wallpaper picker is empty. Drop your own files into those folders to fill them.

## Tests

```sh
./scripts/build.sh
APP=~/Library/Caches/Lumio/Build.noindex/Lumio.app/Contents/MacOS/Lumio
mkdir -p /tmp/lumio-check && "$APP" --make-sample /tmp/lumio-check   # writes the one input the suite needs
"$APP" --verify /tmp/lumio-check                                     # ~95 checks, exits non-zero on failure
```

The suite renders and reads back real frames, so it catches what unit tests on their own would not. Other
entry points: `--verify-live` (preview latency), `--verify-focus`, `--verify-editing`, `--verify-effects`,
`--verify-privacy`, and `--verify-stress` with `LUMIO_STRESS_SEED` / `LUMIO_STRESS_STEPS` for a seeded run
of random edits.

## Licence

MIT, see `LICENSE`. The artwork listed above is not covered by it and belongs to its own rights holders.

Lumio opens with a draggable capture bar and remains available from its menu bar icon. It records a display, window or selected region at 30/60 fps with optional system audio, a selected microphone and a camera, or the screen of an iPhone or iPad connected by cable. Captures and screenshots open directly in the editor.

## Recording

- Pause and resume with ⌃⌥P or the recording bar; paused time is cut automatically when the recording opens.
- Stop with ⌃⌥S from any app. Restart or discard a take from the recording bar (the file moves to the Trash).
- The countdown can be cancelled before capture starts.
- The camera records to its own `.camera.mov` next to the screen recording, with a floating round preview. Its start offset is saved in a `.camera.json` sidecar so it stays in sync in the editor.
- The microphone records to its own `.mic.m4a` with a `.mic.json` offset, so voice and system audio have separate volumes and voice enhancement never touches system sound.
- Device mode records a cable-connected iPhone or iPad screen with its sound to a `.mov`, and opens it with a matching device frame and canvas. Pause works natively; Smart Retake is for screen recordings.
- Captures wider than 4096 pixels (for example 5K Retina) use HEVC, because H.264 hardware encoding stops at 4096. HEVC can also be chosen for every recording.
- Desktop icons can be hidden while recording.
- Pointer, keyboard, retake and pause data are written on the recording file's clock, including when macOS ends the capture from the menu bar.

## Editor

The primary inspector shows nine equally sized sections: Background, Design, Zoom, Cursor, Audio, Captions, Camera, Transcript and Shortcuts. Background opens by default; Design keeps Padding, Corners and Shadow directly accessible. Glow starts disabled. Additional tools remain under More tools.

Visual controls update the existing player's video composition immediately, including a paused frame. They do not replace its media, seek, or wait for a debounced timeline rebuild. Changed caption and shortcut artwork is invalidated; appearance controls retain cached motion paths and automatic zoom identities. Media, timing and audio changes still prepare the corresponding timeline asynchronously.

- Independent, non-destructive video clips with blade, trim, restore and free positioning tools.
- Add another recording to the end of the timeline (timeline toolbar, or ⋯ → Add Recording to Timeline…). It plays from its own file and keeps its own sound; pointer, keyboard, camera and microphone data belong to the recording the editor was opened with. Projects remember the added files.
- Copy, cut, paste, duplicate and delete any timeline item (zoom, caption, clip or audio) with ⌘C, ⌘X, ⌘V, ⌘D and Delete, or from its right-click menu. Paste lands at the playhead and moves the playhead to the end of the pasted item, so repeated pastes line up. The clipboard lasts for the session, so items can be pasted into another recording.
- Per-clip speed from 0.25× to 4×; later clips, zooms, captions and added audio move with the new length.
- Editable manual and automatic zoom clips. Automatic framing groups nearby activity into resting targets, anticipates movement between regions, and resets at source discontinuities. Converted automatic blocks retain cursor follow; manual targets stay fixed unless Follow Cursor is enabled. Cursor and camera motion use a shared 60 Hz presentation clock in preview and export.
- Cursor motion, click effects and motion blur. Recorded pointer shapes (arrow, I-beam, hands, crosshair, resize) are detected from the system cursor.
- Fourteen cursor styles: one color-adjustable white outline, one solid black arrow, six Custom Cursor fan-art packs and six artwork styles.
- Editable captions with five visual presets and on-device speech recognition (SpeechAnalyzer on macOS 26, chunked SFSpeechRecognizer before that).
- Edit by transcript: select words and remove them from the video.
- Camera background (Camera → Background): blur or remove what is behind the person with Apple's on-device person segmentation. A frame with nobody in it is left untouched, and a removed background drops the frame and rounded corners so only the person remains.
- Camera layouts, device frames, video transforms, backgrounds, 203 offline wallpapers, glow and canvas controls. A floating camera fades while the cursor passes under it.
- Crop after recording (Video → Crop): the preview, export, zoom targets and cursor all use the cropped view.
- Auto Reframe for vertical and square canvases: the video fills the frame and pans with the cursor, blending into zooms. It turns on when a landscape recording is placed on a 9:16, 4:5 or 1:1 canvas.
- Enhance Voice (Audio): removes background noise with Apple's on-device voice isolation, levels loudness to about -20 dBFS and limits peaks. The isolation unit delays audio by about 90 ms without reporting it; Lumio measures the delay on each file and removes it. Results are cached in `~/Library/Caches/Lumio/Voice`.
- Voiceover recording at the playhead, five original offline music loops, imported audio, per-track volume/mute controls and voice ducking.
- Recorded keyboard shortcut overlays with Flat/Glass styles, duration, size, padding, opacity, position and alignment controls.
- The recording's own sound is drawn under the video as a loudness envelope, so cuts can be placed on what is heard.
- Markers (M, or the timeline toolbar) sit on the ruler, can be dragged, named and colored, and `,` / `.` jump between them. Export Chapters writes the `0:00 Name` list YouTube and podcast players read.
- Export → Made for…: ready-made settings for YouTube 1080p and 4K, TikTok/Reels/Shorts, Instagram Feed, LinkedIn and X, and a looping GIF. A wide recording is reframed automatically when the canvas is tall.
- `.lumio` projects preserve timeline, speed, zoom, cursor, camera, caption, audio and keyboard settings.

Screen Recording permission is required for capture. Microphone and Camera permissions are requested only when those inputs are used. Keyboard activity capture needs macOS Input Monitoring permission.

## Export

- MP4 or MOV, H.264 or HEVC, 24/30/60 fps, 720p to 4K, watermark-free, with mixed audio.
- Looping GIF (up to 3 minutes), PNG for images and SRT subtitles for captions.
- Export progress with Cancel, and an option to copy the exported file to the clipboard.
- Share the last export from the editor header with AirDrop, Messages, Mail and other macOS share services. Lumio has no hosting service, so it does not create web links.

## Privacy

Keyboard capture keeps only shortcuts (⌘ or ⌃ combinations, Esc and ⌥ with navigation keys). Ordinary typing is stored as timing alone, never as characters, so typed text and passwords are not written to disk.

## Verification

The suite writes its outputs into the folder it is given, so run it on a copy of the fixtures:

```sh
mkdir -p /tmp/lumio-verify && cp Tests/Fixtures/sample.mp4 /tmp/lumio-verify/
/Applications/Lumio.app/Contents/MacOS/Lumio --verify /tmp/lumio-verify
```

The live preview check additionally measures actual rendered intermediate frames during 60 slider changes, tests the paused playhead and uninterrupted playback, and checks artwork invalidation and media timeline replacement for speed changes:

```sh
/Applications/Lumio.app/Contents/MacOS/Lumio --verify-live /tmp/lumio-verify
```

Supply a three-second `sample.mp4` with audio. The suite covers editor handoff, independent cuts, exact blade coordinates, clip speed, zooms, typing zooms, crop, auto reframe, cursor art and shape detection, captions, transcript cuts, camera layouts and camera sync, separate microphone tracks, voice enhancement (noise reduction and delay compensation), device frames, mixed audio, click audio, keyboard overlays and privacy, pause sidecars, project persistence, export formats and cancellation, and decoded MP4/MOV/GIF/PNG output.

To check the camera background treatment on a real camera clip (it needs a person in view):

```sh
/Applications/Lumio.app/Contents/MacOS/Lumio --verify-camera /path/to/camera.mov
```

It samples five frames, says whether a person was found in each and writes a `.background.png` next to the video.

To check transcription, generate speech and run:

```sh
say -o /tmp/lumio-verify/speech.aiff "This short recording checks captions."
/Applications/Lumio.app/Contents/MacOS/Lumio --verify-transcription /tmp/lumio-verify/speech.aiff
```

## Stable local installation

Launch Lumio from `/Applications/Lumio.app`. Quit it and rerun `./scripts/install.sh` to update. `scripts/sign.py` uses the local certificate in `~/Library/Application Support/Lumio/Signing` when one is
there and signs ad hoc when it is not; macOS permission identity depends on keeping that keychain in
place. The private key is not stored in this source folder.

## Version Shelf

Use the stack icon in the editor toolbar or the Versions inspector to save named edits. Each version preserves the timeline, look, zooms, cursor settings, camera, captions, audio and keyboard overlay style. Switching versions automatically keeps the current experiment if it is not already saved, and supports Undo. Save the .lumio project to retain the shelf across launches. The shelf holds up to 24 versions and never evicts one automatically. Media remains referenced at its original path.

## Smart Retake

While recording, choose a 5, 10, 20 or 30 second lookback and press Control–Option–R (or Retake in the recording bar). Repeat the action, then press again to finish. Stopping the recording also finishes an active retake. This marks a time range; it does not detect sentence boundaries.

The Retakes inspector offers raw previews of both attempts and editable source times. Use Retake removes the original attempt; Keep Original removes the retry. All matching source occurrences are cut and the timeline closes across video, camera, cursor, keyboard, zooms, captions and added audio. Undo restores the complete edit, and Version Shelf can preserve alternatives. Original media is never overwritten. Mark at Playhead supports existing recordings. Save the .lumio project to persist adjusted markers and choices; captured markers also live in a .retakes.json sidecar beside the recording.

## Smart Cleanup

The Cleanup inspector scans the original audio for pauses using adjustable sensitivity, minimum duration and preserved breathing room. It can also find common English and Turkish filler words after captions have been generated. Every candidate is shown with its exact time and stays selectable; Lumio never cuts merely because a scan finished.

Applying reviewed suggestions closes timeline gaps and keeps clips, zooms, captions, caption words and added audio aligned. Undo restores the full edit, while the raw recording remains untouched.

The editor opens on Background, with six labeled sections: Background, Zoom, Cursor, Audio, Captions and Camera. Wallpaper, gradient, color and image backgrounds are at the top; padding, corners, shadow and frame/crop controls are in Layout & frame. Glow starts off. The previous saved default is updated once, while saved project looks and later explicitly saved defaults retain their settings. More tools keeps advanced workflows available. The timeline hides empty caption, keyboard and audio tracks, while Split and Add zoom stay visible. Export starts from its own button, with format, codec, frame rate and resolution in the adjacent settings menu. Motion paths and automatic block identities are cached while playback advances.

## Motion verification

`--verify-editing` checks motion across 30/120 Hz mouse traces, camera steadiness, cache reuse and invalidation, editable zoom targets, clip boundaries and a decoded 720p/60 fps export. These checks do not establish sustained preview frame rate on every machine.
