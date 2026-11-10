# Loupe Photos

A fast, private photo library for the Mac — in the spirit of Apple's Aperture.
Everything happens on your Mac: nothing is uploaded, no account, no subscription.

## What it does

- **Library for big collections** — tested with 120,000+ photos: opens in under a second, smooth grid at every size.
- **Browse your way** — Browser, Viewer, Split view, Compare, Survey, Days / Weeks / Months / Years, Calendar and Map.
- **Organise** — folders, albums, smart collections, nested keywords, ratings, flags, colour labels, Quick Collection,
  and a Library Filter (text, attributes, metadata columns) like Lightroom Classic's.
- **People** — finds faces and learns who's who (AuraFace, on the Neural Engine), with a Review window to confirm suggestions.
- **Search in plain words** — names, places, dates, stars, what's in the picture (Apple's scene labels) and text in photos.
- **Places** — photos on a map, place names looked up automatically.
- **Metadata** — full IPTC, metadata presets, batch change and time shift, XMP sidecars or embedded XMP.
- **Develop** — Aperture-style adjustments (white balance, exposure, enhance, highlights & shadows, sharpen, noise,
  vignette, black & white), crop with composition guides and straightening, before / after, presets, undo.
  Your originals are never changed.
- **RAW** — Apple's RAW engine (including RAW 9 on macOS 27), and **Camera Match**: your RAWs start out looking like
  the JPEG your camera showed on its screen.
- **Export** — presets, sizes, formats, watermark, metadata control.

## Install

1. Download the latest `Loupe Photos x.y.zip` from **[Releases](../../releases)** and unzip it.
2. Drag **Loupe Photos** into your **Applications** folder.
3. Open it. macOS will say it can't verify the app (it isn't notarised — that needs a paid Apple account).
   Click **Done**.
4. Open **System Settings ▸ Privacy & Security**, scroll down, and click **Open Anyway** next to "Loupe Photos was blocked".
   Confirm with your password or Touch ID, then **Open Anyway** once more.

From then on it opens normally (repeat steps 3–4 after each new version).

*Alternative (Terminal):* `xattr -dr com.apple.quarantine "/Applications/Loupe Photos.app"`

Requires macOS 14 or later on an Apple silicon Mac (macOS 27 for RAW 9).

## Build it yourself

Open `LoupePhotos.xcodeproj` in Xcode and press Run. No other downloads needed.

## Licence

MIT — see [LICENSE](LICENSE). Third-party parts: see [NOTICE](NOTICE.md).
