# Zig Prompt
A simple wayland prompting utility

## Fonts
By default this embeds the Fira Nerd Font Mono font into the program,
which is licensed separately (see #Dependencies), but you should be able to
compile in any font that is Unicode compatible.

Runtime font selection via a cli arg is still planned for whenever I get to it.

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

### [zig-clap](https://github.com/Hejsil/zig-clap/)
A great Command Line Argument Parser.

Using it under MIT

### [zig-wayland](https://codeberg.org/ifreund/zig-wayland)
A great wayland protocol binding generator for zig.

Using it under MIT

### [wayland](https://wayland.freedesktop.org/)
This is used for wayland-scanner, libwayland-client. (you know, how it actually displays windows).

Using it under the X11 license, similar to the MIT License.

We also use several different Wayland protocols, which are licensed under MIT.

## Tools Used
### [Zig](https://ziglang.org/)
A great language that I wanted to use.

Licensed under MIT

### [Nix](https://nixos.org/)
A great tool for building and maintaining packages and dependencies.
(even if not used much here yet)

Licensed under LGPLv2.1

