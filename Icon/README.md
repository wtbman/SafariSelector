# Icon

`generate-icon.swift` renders every size of the SafariSelector icon with CoreGraphics —
a link arriving from the left and entering the selected one of three windows.

```bash
swift Icon/generate-icon.swift /tmp/ssicon
```

Then copy into `SafariSelector/Assets.xcassets/AppIcon.appiconset/` (app) and
`SafariSelector Extension/Resources/images/` (the icon Safari shows in Settings → Extensions).
Both use the same artwork deliberately, so the extension is recognisably part of the app.

The extension's `images` folder is a **folder reference** in the Xcode project, so new sizes are
picked up without touching `project.pbxproj`.
