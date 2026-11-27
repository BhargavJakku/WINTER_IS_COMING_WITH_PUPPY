# ❄︎ WinterIsComing · Pet & Me edition ❄︎

A little snowfall for your Mac desktop, now with you and your pet living on the snow 🐶☃️

Snow drifts down and settles on your windows, the Dock and the bottom of the screen. Roll it into snowballs, stack them into a snowman, hang some fairy lights, and watch you and your pet hang out by the campfire under a twinkling Christmas tree.

![Pet & Me: you, your beagle, a campfire and a Christmas tree on the snow](docs/pet-and-me.png)

This is a fork of [yike-shi/WINTER_IS_COMING](https://github.com/yike-shi/WINTER_IS_COMING), which made the snow, snowballs, snowmen and fairy lights. This edition adds the Pet & Me companions, the campfire, the Christmas tree and a few quality-of-life touches. It is Mac only; for Windows, use the original project.

## 🎁 Download

| | |
|---|---|
| **Mac** | [WinterIsComing-mac zip](https://github.com/BhargavJakku/WINTER_IS_COMING_WITH_PUPPY/releases/latest) · unzip, move it to Applications, open it |

On the release page, grab the zip with the app's name (not the "Source code" ones).

**The first time you open it**, your Mac may stop it, because the app isn't signed with a paid developer account yet: click **Done**, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Just once, and you're all set.

For snow on the Dock too, allow **WinterIsComing** in **System Settings → Privacy & Security → Accessibility**.

Don't worry, the app never connects to the internet, and all of its code is right here 💙

## ✨ What you can do

**The snow** (from the original app)

- **Watch it snow**: flakes drift down in three soft layers and pile up on your windows and the ground
- **Drag a window**: the snow on top slides right off
- **Roll a snowball**: move your mouse sideways over the snow, no clicking needed
- **Push it**: roll one snowball into another and give it a nudge
- **Carry it**: hold the left mouse button on a snowball and take it anywhere
- **Build a snowman**: stack three snowballs and he comes to life with a carrot nose ⛄. In this edition he gets one of six outfits at random: top hat, cozy beanie with mittens, earmuffs, Santa, backwards cap or wizard with a broom
- **Hang fairy lights**: turn them on from the menu and watch them swing into place

**Pet & Me** (new in this edition)

- **You and your pet** walk around on the ground snow, leaving little footprints
- **Pet your pet**: click it ❤️ · click twice quickly and it howls 🎶
- **Call it over**: click yourself and your pet comes running for a cuddle
- **Fetch**: every so often you throw a snowball and your pet fetches it, and if you throw one with the mouse, it chases that too
- **Snowman trouble**: a few seconds after you finish a snowman, your pet knocks it over 😈
- **Campfire time** 🔥: now and then you both sit by the fire for a couple of minutes and your pet dozes off. Click the fire to start it right away. It melts the snow around it, and any snowball you roll into it
- **Christmas tree** 🎄: a third of your screen tall, with twinkling lights and a sparkling star
- **Naps**: leave the mouse alone for a minute and you both doze off; move it and you wake up
- **Wind moods** 🌬️: the wind drifts at random between a gentle breeze, a moderate wind and short strong gusts (about one a minute on average). When a gust hits, you wrap up in a flapping striped scarf and your pet puts on its red knit sweater, and you take them off about 20 seconds after it calms down

**Little extras**

- Deeper snow on the ground, with some already there when the app starts
- An auto-hiding Dock keeps its snow and pops up already snowy, and if it pops up under you or your pet, you ride on top of it
- Smooth fading when you swipe between Spaces and full-screen apps
- **Snow Amount → None**: just you and your pet, no falling snow
- **Performance** (Battery Saver / Balanced / High Quality) and **Reduce Motion**, right in the ❄︎ menu

Everything lives in the ❄︎ menu in the menu bar: pause, snow amount, performance, reduce motion, **Pet & Me**, **Campfire**, **Christmas Tree**, fairy lights, clear snow, and how to play.

## 🔋 Light on your Mac

Made to run all day on an 8 GB laptop:

- You, your pet, the tree and the campfire are drawn once when the app starts (a few milliseconds, a few MB of memory) and then just moved around. No images, video or heavy effects
- **Performance** in the ❄︎ menu: **Battery Saver** (20 frames per second), **Balanced** (30, the default) or **High Quality** (60). Each one also sets how often the app checks where your windows are
- **Reduce Motion**: at most 30 frames per second, fewer flakes, only gentle wind, no zoomies, a calmer fire and tree
- While you nap, the frame rate halves and window checks slow down. It does the same in Low Power Mode
- Everything stops drawing while your display sleeps or the snow is paused

## 🛠️ Build it yourself

Needs `swiftc` (run `xcode-select --install` if you don't have it).

```sh
git clone https://github.com/BhargavJakku/WINTER_IS_COMING_WITH_PUPPY.git
cd WINTER_IS_COMING_WITH_PUPPY
zsh build.sh            # run it
zsh make_app.sh 1.0     # or package it as an .app (the zip in dist/ is what goes on Releases)
```

When you run it with `build.sh`, the Accessibility permission for Dock snow belongs to **Terminal**.

## 🎨 Make it yours

- **Settings**: the snow settings live at the top of `WinterIsComing.swift` (`Cfg`), and the Pet & Me settings right below the "Pet & me" heading (`Pals`): walking speeds, how long until a nap, how often you throw snowballs, how long your pet lets a snowman stand. Change a number and run it again
- **Your look and your pet's**: see **Put yourself and your pet in it** below
- **Wind**: for more or fewer strong gusts, change `0.78` in `stepWind` (lower = more gusts, e.g. `0.60`; higher = fewer, e.g. `0.90`)
- **The howl**: replace `assets/howl.wav` with a recording of your own pet (`howl.m4a`, `.mp3`, `.wav` or `.aiff` all work)

## 🐾 Put yourself and your pet in it (with Claude)

You don't have to draw anything. Claude looks at your photos and writes a short **recipe** of colors, and the app draws you and your pet from it in the same smooth sticker style.

**1. Ask Claude for your recipe.** Go to [claude.ai](https://claude.ai), attach 2–4 photos (you from head to toe, and your pet from the side if you can), and paste this prompt:

````text
I use the WinterIsComing "Pet & Me" Mac app, which draws me and my pet as cute,
smooth sticker-style cartoons on the snow. The shapes are fixed (a person in a
beanie and puffer jacket, and a floppy-eared dog); the colors come from this
Swift "recipe". Look at my attached photos and fill it in.

Rules:
- Every color is a hex string like "#A0522D".
- skin: my skin tone. hair: my hair color.
- hat: my beanie color (from the photos, or one that suits me).
- jacket, collar, pants, boots: from my winter clothes in the photos, or colors that go well together.
- coat: my pet's main fur color (body, legs, muzzle).
- markings: the color of its head patches, thigh/shoulder patches and tail.
- ears: its ear color (a little darker than markings looks best).
- saddle: the dark patch on its back; if it has none, use the same color as coat.
- blaze: true if it has a light stripe down the middle of its face, otherwise false.
- meName: my first name. petName: my pet's name.

Reply with ONLY the filled-in code block, nothing else:

```swift
struct PalsRecipe {
    var meName = ""
    var skin = "#"
    var hair = "#"
    var hat = "#"          // beanie
    var jacket = "#"
    var collar = "#"
    var pants = "#"
    var boots = "#"

    var petName = ""             // shown in the speech bubbles
    var coat = "#"               // main fur: body, legs, muzzle
    var markings = "#"           // head, thigh and shoulder patches, tail
    var ears = "#"
    var saddle = "#"             // the dark patch on the back
    var blaze = true             // light stripe down the middle of the face
}
```
````

**2. Paste it into the code.** Open `WinterIsComing.swift` in any text editor, search for `struct PalsRecipe` (⌘F), and replace that whole block, from `struct PalsRecipe {` down to its closing `}`, with the one Claude gave you.

**3. Build it.**

```sh
zsh build.sh            # try it out
zsh make_app.sh 1.0     # then make your own app for Applications
```

**What changes:** all the colors (skin, hair, beanie, jacket, collar, pants, boots, your pet's coat, markings, ears and back patch), the face stripe, and the names in the speech bubbles. **What stays the same for now:** the shapes, so everyone gets curly hair under a beanie and a floppy-eared, beagle-shaped pet. More hair styles, ears, tails and pets are planned.

Not quite right? Change a hex color by hand, or ask Claude something like "make the jacket darker" or "the ears should be black" and paste the new recipe in again.

## 💙 Credits & License

Original WinterIsComing by [yike-shi](https://github.com/yike-shi/WINTER_IS_COMING). Pet & Me edition by [BhargavJakku](https://github.com/BhargavJakku).
Wind moods ported from, and the snowman-outfit and performance-profile ideas inspired by, [251701054/WINTER-IS-COMMING-VER2](https://github.com/251701054/WINTER-IS-COMMING-VER2) (MIT).

[MIT](LICENSE) · Made with 💙 and a little help from Claude
