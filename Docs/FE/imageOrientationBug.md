# Bug: Wound Photos Can Be Silently Rotated Before Reaching the Vision Model

Last updated: 2026-07-18

## Summary

`UIImage+Attachment.swift` (`attachmentJPEGData`) does not correct for camera
orientation before encoding chat image attachments. For a large share of real
photos — specifically any photo whose *corrected* longest side is ≤ 1024px —
the function ships the **raw, unrotated pixel buffer** to the vision-language
model (VLM), not the upright image the user actually sees on screen. The VLM
then confidently analyzes a sideways or upside-down photo as if it were
upright.

This matters more than a typical cosmetic image bug because this app uses the
VLM to analyze **wound / stoma photos** for infection signs (redness
location, swelling, discharge). A model that's "confidently correct about the
wrong (rotated) image" is a silent accuracy failure, not a crash — it won't
show up in testing unless someone specifically checks rotated photos, but in
the field, patients photographing a wound on their own body (e.g. an
abdominal stoma site) at an angle is a completely normal, expected case, not
an edge case.

This was verified empirically on-device (iPad Simulator, iOS 26.4), not just
reasoned about from documentation — see "How this was verified" below.

## Where the bug is

**File:** `App/Frontend/VVM/Chat/UIImage+Attachment.swift`

```swift
extension UIImage {
    func attachmentJPEGData(maxDimension: CGFloat = 1024, quality: CGFloat = 0.8) -> Data? {
        let longestSide = max(size.width, size.height) * scale          // line 14
        guard longestSide > maxDimension else {
            return jpegData(compressionQuality: quality)                 // line 16 — BUG: path 1
        }

        let ratio = maxDimension / longestSide
        let targetSize = CGSize(width: size.width * scale * ratio, height: size.height * scale * ratio)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))            // line 23 — BUG: path 2 (partially)
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
```

There are two related but distinct bugs here, and it's important to understand
both because they don't share the same fix location:

### Bug 1 (the one that actually bites in practice): the early-return path

`UIImage.jpegData(compressionQuality:)` does **not** bake the image's
`imageOrientation` into the encoded pixel data. It encodes the *raw* pixel
buffer as-is (e.g. 3024×4032 sensor-space, or whatever the camera produced)
and — at best — writes an EXIF orientation tag alongside it for viewers that
choose to honor it. It does not physically rotate the pixels.

Most iOS viewers (Photos app, `UIImageView`, Preview) *do* read that EXIF tag
and display the photo upright, which is exactly why this bug is invisible in
casual testing — if you eyeball the photo in the app's own image preview, it
looks fine. But once that same JPEG data is handed to an ML model's image
preprocessing pipeline, there is no guarantee the model's image loader honors
EXIF orientation the same way — many ML/vision preprocessing stacks
(including common ones used by MLX-VLM-style pipelines) load raw pixel
buffers and ignore EXIF metadata entirely, because EXIF-aware decoding is a
extra step that isn't part of a bare bitmap decode. In that case, the model
sees the photo exactly as the sensor captured it: sideways or upside-down.

### Bug 2: the resize path's size check

Even when the resize branch does run, the *decision* of whether to resize is
based on `size` (line 14), which for a `.right`/`.left`/`.down`-oriented
image already reflects the corrected, upright dimensions (UIKit swaps width/
height for you when orientation is rotated 90°). That part is actually
correct on its own. The problem is that **the early-return path bypasses the
one line (`draw(in:)`) that would have corrected the orientation**, so any
photo that doesn't need resizing (i.e., most photos, since 1024px is a small
cap relative to a 12MP+ camera photo minus this being about whether it's
*already* ≤1024, which will still occur for e.g. photos re-shared from
Messages, screenshots, or already-compressed images) skips orientation
correction entirely.

**In short:** the `draw(in:)` call is the only place in this function that
corrects orientation, and it's only reached when the photo is *already*
small — but small photos are exactly as likely to be sideways as large ones.
Any photo (regardless of size) that came from the camera with a
non-`.up` `imageOrientation` is at risk.

## How this was verified

Rather than relying on Apple's documentation (which is easy to
misread here — `draw(in:)` *does* respect orientation, but
`jpegData(compressionQuality:)` alone does not, and it's easy to assume they
behave the same way), this was checked with a real on-device test.

**Test setup:** built a synthetic `UIImage` — a 100×200 raw pixel buffer,
red on the top half, blue on the bottom half — then tagged it with
`imageOrientation = .right`, simulating a common real-world case (e.g. the
phone/iPad held in portrait while the sensor itself captured landscape,
which is how `.right`/`.left` orientation tags typically arise from
`UIImagePickerController`/camera capture). This is the same shape of image
`attachmentJPEGData` receives from `CameraImagePicker.swift`.

Ran `attachmentJPEGData(maxDimension: 1024, quality: 0.9)` on this image via
`xcodebuild test` on an iPad Pro 11" (M5) simulator, then decoded the
resulting JPEG bytes back into a `CGImage` and read raw pixel bytes directly
(bypassing any orientation-aware convenience APIs, to see exactly what was
encoded).

**Result:**
- Output pixel buffer was **100×200** (the raw sensor-space dimensions),
  not **200×100** (the corrected, upright dimensions implied by the `.right`
  tag and by `tagged.size`).
- The top-left pixel of the decoded output was solid red
  (`RGB = 254, 0, 0`) — i.e., still exactly where it was in the raw,
  *unrotated* buffer. If orientation had been corrected, red would have
  moved to a different position in the upright frame.

This isolates the defect to `UIImage.jpegData(compressionQuality:)` itself
(the exact call at line 16) — confirmed by testing that call in isolation,
separately from the rest of `attachmentJPEGData`, with the same result. For
contrast, calling `draw(in:)` into a `UIGraphicsImageRenderer` at the
*corrected* size (i.e., exactly what happens in the resize branch, line 23)
**does** correctly rotate the pixels — that path is fine on its own; it's
only unreachable for photos that don't trigger a resize.

## Why this matters for this specific app

- The project's core success criterion is **non-hallucinatory, accurate
  feedback on wound photos** (stomach tube sites, infection signs). A model
  that describes "swelling near the top of the wound" when the photo was
  actually upside-down and the swelling is near the bottom is a direct
  accuracy failure traceable to this bug, not a model quality issue — no
  amount of prompt engineering or model upgrade fixes this, because the
  model never sees the correct image.
- The target users are patients who are elderly, post-surgery, or
  self-photographing a body area they can't easily see directly (e.g. a
  stoma site) — awkward angles and non-standard phone/iPad orientation
  during capture are the **expected common case** here, not a rare edge
  case.
- This bug is silent by construction: previews inside the app itself likely
  render correctly (because SwiftUI/`UIImageView`-style display paths do
  honor `imageOrientation`), so it will not be caught by "does the photo
  look right in the chat bubble" testing. It only manifests in what the
  model actually receives.

## Recommended fix

Normalize orientation **once, unconditionally, before either branch** —
don't gate the correction on whether a resize is needed. Concretely: always
redraw into a `UIGraphicsImageRenderer` sized to the corrected `size`, then
JPEG-encode that result, rather than ever calling `self.jpegData(...)`
directly on the original (possibly non-`.up`-oriented) `UIImage`.

Sketch (frontend team should adapt to match code style, not copy verbatim):

```swift
func attachmentJPEGData(maxDimension: CGFloat = 1024, quality: CGFloat = 0.8) -> Data? {
    let longestSide = max(size.width, size.height) * scale
    let targetLongestSide = min(longestSide, maxDimension)
    let ratio = targetLongestSide / longestSide
    let targetSize = CGSize(width: size.width * scale * ratio, height: size.height * scale * ratio)

    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let normalized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
        draw(in: CGRect(origin: .zero, size: targetSize))
    }
    return normalized.jpegData(compressionQuality: quality)
}
```

This removes the early-return branch entirely — `draw(in:)` is always used,
so orientation is always corrected, whether or not the image needs
downscaling (when `longestSide <= maxDimension`, `ratio` is `1.0` and the
image is redrawn at its own corrected size, which still fixes orientation
without changing dimensions).

**Before shipping this fix**, the frontend team should:
1. Confirm with a real device (not just simulator) camera capture in at
   least two non-`.up` orientations (e.g. hold the device rotated 90° left
   and 90° right while taking a photo) that the final encoded JPEG is
   pixel-correct, not just EXIF-tag-correct.
2. Spot-check that this doesn't regress performance/memory meaningfully —
   this now always does one `UIGraphicsImageRenderer` pass instead of
   sometimes skipping it, though the cost should be negligible relative to
   JPEG encoding itself.
3. Consider adding a regression test (using the same technique described
   above: a synthetic tagged `UIImage`, encode, decode, check pixel
   positions) to `MobiCureVNTests` so this can't silently regress again.

## Scope note

This document only covers the `attachmentJPEGData` encoding step. It does
not cover whether `CameraImagePicker.swift` or the VLM-side image
preprocessing (MLX-VLM) have any *additional* independent orientation
handling — those weren't in scope for this check. If the VLM's own
preprocessing turns out to separately re-derive orientation from EXIF
metadata (unlikely, but not verified here), that could partially mask this
bug; this shouldn't be assumed without checking, since relying on it would
make the pipeline fragile to any change in the VLM tokenizer/preprocessor
version.
