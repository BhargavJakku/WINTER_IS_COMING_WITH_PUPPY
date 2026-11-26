# ❄︎ WinterIsComing

Quiet snowfall for your desktop, on Mac and Windows. Snow settles on your windows, the Dock and the taskbar, and you can roll it into snowballs and build a small snowman ☃️

<!-- ![demo](docs/demo.gif) -->

## Download

| | |
|---|---|
| **Mac** | [WinterIsComing-mac-v1.0.zip](https://github.com/yike-shi/WINTER_IS_COMING/releases/latest) · unzip, move it to Applications, open it |
| **Windows** (beta) | [WinterIsComing-windows-v0.1-beta.zip](https://github.com/yike-shi/WINTER_IS_COMING/releases/tag/windows-v0.1) · unzip, open `WinterIsComing.exe` |

On the release page, download the zip with the app's name, not the "Source code" files.

**The first time you open it**, your computer may stop it, because the app isn't signed with a paid developer account yet:

- **Mac**: click **Done**, then go to **System Settings → Privacy & Security** and click **Open Anyway**. You only need to do this once.
- **Windows**: click **More info → Run anyway**.

The app doesn't connect to the internet, and all of its code is in this repository.

## What you can do

- **Watch it snow**: flakes drift down in three layers and pile up on your windows
- **Drag a window**: the snow on top slides off
- **Roll a snowball**: move your mouse sideways over the snow
- **Push it**: roll one snowball into another
- **Carry it**: hold the left mouse button on a snowball and drag
- **Build a snowman**: stack three snowballs
- **Hang fairy lights**: turn them on from the menu ✨

Everything else is in the ❄︎ menu: in the menu bar on Mac, in the system tray on Windows (click **^** if you don't see it). There you can pause, change the amount of snow, clear it, or see how to play again.

On Mac, to get snow on the Dock too, allow **WinterIsComing** in System Settings → Privacy & Security → Accessibility.

## Build from source

**Mac** (needs `swiftc`; run `xcode-select --install` if you don't have it)

```sh
git clone https://github.com/yike-shi/WINTER_IS_COMING.git
cd WINTER_IS_COMING
zsh build.sh            # run it
zsh make_app.sh 1.0     # or package it as an .app
```

**Windows** (needs the [.NET 8 SDK](https://dotnet.microsoft.com/download))

```sh
cd WINTER_IS_COMING/windows
dotnet run -c Release
```

All the settings (how much snow falls, how fast, how big a snowball can get) are at the top of `WinterIsComing.swift` and `windows/Program.cs`.

## License

[MIT](LICENSE) · Made with 💙 and a little help from Claude
