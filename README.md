# Apple Super Resolution Video Upscaler

A small macOS app that upscales video files 4× using Apple's **Super Resolution** engine from VideoToolbox. Drop a video in, press **Go**, and get a sharper, larger copy next to the original.

- Native SwiftUI app, no third-party dependencies
- Follows the system's light and dark mode
- Keeps the original's audio, orientation and color information
- Writes straight to the final file: no temporary files, no logs

## Install

Download **AppleSuperResolutionVideoUpscaler-1.0.dmg** from the [latest release](https://github.com/Illuminus7/apple-super-resolution-video-upscaler/releases/latest), open it, and drag the app into **Applications**.

The app isn't notarized by Apple, so macOS blocks it the first time. To open it:

1. Try to open the app once, then close the warning.
2. Open **System Settings → Privacy & Security**, scroll to the message about the app, and click **Open Anyway**.

Or, in Terminal, remove the download quarantine flag once:

```bash
xattr -dr com.apple.quarantine "/Applications/Apple Super Resolution Video Upscaler.app"
```

## Requirements

- A Mac with Apple silicon
- macOS 26 or later
- Xcode 26 or later (to build from source)
- Input video up to **1920 × 1080**

## Usage

1. Launch **Apple Super Resolution Video Upscaler**.
2. Drop a video onto the window, or click it to choose a file.
3. Check the input and output sizes shown under the file name.
4. Press **Go** (or Return).
5. Wait for the progress bar to finish. Press **Cancel** to stop; a cancelled run leaves no partial file behind.

When it's done, the file is saved in the same folder as the original, with ` upscaled` added to the name:

| Input | Output |
| --- | --- |
| `Holiday.mov` | `Holiday upscaled.mov` |
| `clip.mp4` | `clip upscaled.mp4` |

If that name already exists, a number is added (`clip upscaled 2.mp4`), so nothing is ever overwritten.

## The model download

Apple's Super Resolution uses a machine-learning model that macOS downloads on demand. The first time you press **Go** on a Mac that doesn't have it yet, the app asks the system to download it. The progress bar shows the download (`Downloading Super Resolution model… N%`), and upscaling starts automatically when it finishes.

- The download needs an internet connection. If it fails, the app shows an error and nothing is written.
- The model is stored and managed by macOS, not by this app. Later runs skip the download.

## What the app does

Each frame goes through this pipeline:

1. **Read** the video with `AVAssetReader`, as 10-bit YUV.
2. **Convert** the frame to RGBA half-float with `VTPixelTransferSession`.
3. **Upscale** it with `VTFrameProcessor` and `VTSuperResolutionScalerConfiguration` (4×).
4. **Convert** the result back to 10-bit YUV.
5. **Encode** it as HEVC Main10 with `AVAssetWriter`.

Audio tracks are copied without re-encoding when the container allows it. Otherwise they are converted to AAC.

### Limits of Apple's Super Resolution

- Only **4×** scaling is available, so 1080p becomes 7680 × 4320 (8K) and 720p becomes 5120 × 2880.
- Input frames can be at most **1920 × 1080**. Larger videos show an error.
- Processing time grows with the length and resolution of the video. Long clips can take a long time.

## Building from source

```bash
./build.sh
```

This script:

1. Generates the app icon (`Resources/AppIcon.icns`) with `Tools/MakeIcon.swift`, if it's missing.
2. Compiles the sources in `Sources/` with `swiftc`.
3. Assembles `Apple Super Resolution Video Upscaler.app`.
4. Ad-hoc signs the bundle.

To open the result, double-click it in Finder, or run:

```bash
open "Apple Super Resolution Video Upscaler.app"
```

## Project layout

```
Sources/
  VideoUpscalerApp.swift   App entry point and window setup
  ContentView.swift        SwiftUI interface and view model
  Upscaler.swift           Read → upscale → encode pipeline
Resources/
  Info.plist               Bundle metadata (macOS 26 minimum)
  AppIcon.icns             App icon
  AppIcon.png              1024 px master of the icon
Tools/
  MakeIcon.swift           Draws the icon and writes the .icns file
build.sh                   Builds the app bundle
```

## The icon

The icon is drawn in code by `Tools/MakeIcon.swift` on Apple's 1024 px icon grid: an 824 px continuous-corner square with a transparent margin, as macOS app icons require. It shows a film frame, half pixelated and half sharp, with a seam between the two and sparkles to suggest enhancement.

## License

No license has been chosen yet. All rights are reserved by the author until one is added.
