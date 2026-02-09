# ⚡️ FastTab

A lightning fast Alt+Tab switcher for X11 written in Zig using Raylib.



https://github.com/user-attachments/assets/6327cd4b-4750-40c8-ab30-f8d80463887d



## Features

 - Instant window switching, no more waiting for the switcher to appear
 - UI with window thumbnails, titles, and icons
 - Smooth OpenGL rendering of the switcher UI
 - Lightweight daemon with low CPU and memory usage


## Motivation

I love my KDE Plasma desktop environment, but I find the default "Thumbnail Grid" switcher to be a bit too slow for my taste: sometimes it would take up to a second to appear, which is too long when you want to quickly switch between windows.

I believe this is because the default switcher has a major performance compromise: it generates window thumbnails on the fly when the switcher is invoked.
This _does_ make sense normally because it means that you're not wasting resources generating thumbnails for windows you might never switch to. And most likely, lots of users don't use Alt+Tab that often.

I am, however, in the opposite camp: I Alt+Tab all the time, my computer can handle the extra cpu (very little) and memory (some) no problem, and even a slight delay irritates me.

So I decided to try out writing my own Alt+Tab switcher.

FastTab improves performance in several ways:
 - It runs as a daemon in the background, constantly monitoring windows and maintaining live thumbnails.
 - It uses OpenGL via Raylib for fast rendering of the switcher UI
 - Window thumbnails are rendered entirely on the GPU using GLX texture binding (zero-copy, no CPU overhead).
 - Live thumbnail updates reflect window content changes in real-time without capturing screenshots.
 - It's written in Zig!

## Prerequisites

 - An X11-based desktop environment (e.g. KDE Plasma, Xfce, etc)
 - Hardware-accelerated OpenGL support
 - Rebind the default `Alt+Tab` shortcuts to something else (e.g. `Ctrl+Meta+Tab`, `Ctrl+Meta+Shift+Tab`), to avoid conflicts.  

## Build instructions
1. Make sure you have Zig installed (version 0.14.0 or later)
1. You will also need the following development packages installed:
    - libasound2-dev
    - libgl1-mesa-dev
    - libglu1-mesa-dev
    - libwayland-dev
    - libx11-dev
    - libx11-xcb-dev
    - libxcb-composite0-dev
    - libxcb-damage0-dev
    - libxcb-image0-dev
    - libxcb-keysyms1-dev
    - libxcb-shm0-dev
    - libxcb-util0-dev
    - libxcb1-dev
    - libxcursor-dev
    - libxi-dev
    - libxinerama-dev
    - libxkbcommon-dev
    - libxrandr-dev
    - libglfw3-dev
    - libxcb-keysyms1-dev

    On Debian/Ubuntu, you can install them with `sudo apt install <package-names>`.

1. Clone this repository
1. Run the `setup.sh` script to install Raylib and other dependencies
1. Build the project with `zig build -Drelease-safe`
1. The resulting binary will be located at `./zig-out/bin/fasttab`

## Installation instructions

1. Follow the build instructions to build the project, or grab the latest binary from the [releases page](https://github.com/LBognanni/fasttab/releases/latest)
1. Move the binary somewhere in your PATH (e.g. `/usr/local/bin`)
1. Run `fasttab daemon &` to start the daemon in the background
1. You're done! Try Alt+Tabbing around!


#### ⚠️ DISCLAIMERS
 - Consider this Very Beta. It works for me, but your mileage may vary.
 - Yes I did use AI to help me write a lot of this code. On one hand I would have preferred to write it all myself, but on the other hand I would not have been able to finish it in a reasonable amount of time. So here we are.
