# Icon

The icon is the same glyph as the menu bar item — SF Symbol `arrow.triangle.branch`, a trunk
diverging into two arrows — on a **transparent** background. An earlier illustrated version
(a link entering one of three windows) was dropped: it turned to mush at 16px, which is exactly
the size that matters most for a menu bar agent and a Safari extension row.

```bash
swift Icon/generate-icon.swift /tmp/ssicon
```

Then copy into `SafariSelector/Assets.xcassets/AppIcon.appiconset/` (app) and
`SafariSelector Extension/Resources/images/` (the icon Safari shows in Settings → Extensions).
Both use the same artwork deliberately, so the extension is recognisably part of the app.

The glyph is tinted a fixed blue rather than left as a template: a static PNG cannot adapt to
light and dark the way the menu bar's template image does, so the colour is chosen to hold up
against both.

The extension's `images` folder is a **folder reference** in the Xcode project, so new sizes are
picked up without touching `project.pbxproj`.
