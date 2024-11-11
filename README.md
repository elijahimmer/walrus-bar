# Walrus Bar
A `zwlr-layer-shell-unstable-v1` Status bar for Wayland.
If you don't know what that means, it just means it's a status bar for linux
that shows the time, workspaces, etc.

This should work for most any compositor, and please submit any 
bug reports if it is found to not work on one of them.

## Features
A Clock, Battery, Brightness, and Workspaces widgets are all done.

Sofar this only has Hyprland workspace support, but more should be relatively easy to add.
Just submit a bug report and ask for it, or make a PR and add it (look at [#Contributing](#Contributing))

The Battery widget uses the `/sys/class/power_supply/BAT0` directory for information by default, but can be specified.
The Brightness widget uses the `/sys/class/backlight/intel_backlight` directory for information by default, but can be specified.

## Building
**If you find any dependencies I am missing here, please submit a bug report about it.**
I recommend nix for managing the dependencies, but if you cannot use it, or just don't want to,
all the required build dependencies should be (exact versions not needed):

- pkg-config 0.29.* (you likely already have this)
- Zig 0.13.*
- wayland-client 1.23.*
- wayland-scanner 1.23.*

Everything else should be bundled in, or managed by the Zig compiler.

### Build Instructions:
If you have nix installed, with a flake compatible system, run
```sh
nix build
```

If not, after you acquire the needed dependencies (listed above), run
```sh
zig build --release=safe
```

I recommend compiling with `--release=safe`, but you can also do `--release=fast` or `--release=small`
to optimize for speed and binary size respectively.

## Configuration
Every option is available via the CLI args, but that can get annoying so you can also specify a configuration file.
By default, it looks for the file at `$XDG_CONFIG_HOME/.config/walrus-bar/config.ini`, but the path
can be specified by the `--config-file=PATH` CLI argument.

For options try `walrus-bar --help`

Any widgets that don't get compiled in won't appear in the `--help` menu, nor will it be checked
in the config file. You may see warning saying a setting is not found if the widget is disabled, which you can ignore.

## Performance
As of 0.1.4, the slowest part of this is the overhead of the Wayland connections,
but multiple outputs and HI-DPI outputs have yet to be thoroughly tested.

Normally this idles 0.0% to 0.1% CPU usage, and ~4 Mib of memory (much of which is the font).
If you load a custom font (which is not yet supported), it will take up more.

## Contributing
Any and all (in good faith) contributions are welcome, be they PRs, bug reports, or some third thing I forgot about.
I will try my best to get back to any bug reports, PRs, and questions. I will also try to provide feedback on what possible issues are with any
PR, before they are merged.

If you have any features you want supported, just ask.
Just don't expect it to be done in general or at any short timespan.

Look at [CONTRIBUTING.md](CONTRIBUTING.md) for more details.

## Versioning
The versioning currently, as it is pre-release is `0.MAJOR.MINOR`
Where Major is breaking changes, and minor is backwards compatible.
This will be followed loosely until the project is more established.

But once this is stable (likely not for a while), it will follow [Semantic Versioning 2.0](https://semver.org/)
Until them, it is just Semver shifted over one.

## Fonts
By default this embeds the Fira Nerd Font Mono font into the program,
which is licensed separately (see [#Dependencies](#Dependencies)), but you should be able to
compile in any font that is Unicode compatible.

Runtime font selection via a CLI argument is still planned for whenever I get to it.

## Dependencies
### [Fira Nerd Font Mono](https://www.nerdfonts.com/)
A great font I use for everything (including embedded in this).

Everything in the ./fonts/ directory is related to this font, and I am using it the under [SIL Open Font License, Version 1.1](fonts/LICENSE)
Nothing in this folder is my work.

### [FreeType](https://freetype.org/)
A great library we use them for all the font rendering..
Using this under the [Freetype License](https://freetype.org/license.html)

### [FreeType Zig Bindings](https://github.com/hexops/freetype#e8c5b37f320db03acba410d993441815bc809606)
A fork of FreeType that replaces their several build systems with Zig.
Using this under the [Freetype License](https://freetype.org/license.html)

I included both the core library (FreeType) and this to show where everything originates from.

### [wayland](https://wayland.freedesktop.org/)
This is used for wayland-scanner, libwayland-client. (you know, how it actually displays windows).

Using it under the X11 license, similar to the MIT License.

We also use several different Wayland protocols, which are licensed under MIT.

### [zig-clap](https://github.com/Hejsil/zig-clap/)
A great Command Line Argument Parser.

Using it under MIT

### [zig-wayland](https://codeberg.org/ifreund/zig-wayland)
A great wayland protocol binding generator for zig.

Using it under MIT

## Tools Used
### [Zig](https://ziglang.org/)
A great language that I wanted to use.

Licensed under MIT

### [Nix](https://nixos.org/)
A great tool for building and maintaining packages and dependencies.
(even if not used much here yet)

Licensed under LGPLv2.1

