//! agate's C-level macOS framework imports, consolidated into one `@cImport`
//! (mirrors Ghostty's `pkg/macos/main.zig`: one translation unit, one source
//! of truth for the raw decls).
//!
//! Only the modern, self-contained frameworks are imported here. The
//! Accessibility (AX) API is *not* — its headers transitively pull in the
//! Carbon-era `CoreServices` umbrella (`<AE/AE.h>` &c.) which Zig's translate-c
//! cannot resolve against the SDK's nested sub-frameworks. The AX API is small
//! and stable, so we hand-declare it as `extern` decls in `ax.zig` instead
//! (linking ApplicationServices resolves the symbols). Ghostty avoids the
//! ApplicationServices umbrella for the same reason.
//! The CoreGraphics umbrella (`CoreGraphics/CoreGraphics.h`) also defeats
//! translate-c (clang block `^` syntax in CGPath, array nullability in
//! CGColorSpace/CGFont). We only need CG geometry here, so we include just
//! `CGGeometry.h` (CGRect/CGPoint/CGSize + dictionary conversion). The
//! window-server query lives in `CGWindow.h`, which transitively drags in
//! those broken headers, so it is hand-declared in `cg.zig`.
pub const c = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("CoreGraphics/CGGeometry.h");
});
