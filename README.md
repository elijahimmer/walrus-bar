# Walrus Bar
My third attempt at a wlroots/hyprland status bar.

## Contributing
Any and all (in good faith) contributions are welcome, be they PRs, Issues, etc.
I will try my best to get back to any issues, PRs, and questions.
I will also try to provide feedback on what possible issues are with any
PR, before they are merged.

If you have any features you want supported, just ask.
Just don't expect it to be done in general or at any short timespan.

### Style
In general, try to follow NASA's The Power of 10: Rules for Developing Safety-Critical Code

At the moment, we are going against 9, but I may eventually fix that.

#### Loops:
NASA's The Power of 10: Rules for Developing Safety-Critical Code
> 2. All loops must have fixed bounds. This prevents runaway code.

Every loops that should be finite needs a bound.
For loops inherently have one, but any while loop whose condition is not the bound,
they need a finite bound.

The only exception are times when they should actually be indefinite,
such as the main dispatch loop.

So these are fine
```zig
// for loop
for (slice) |_| {...}

// index going up
var idx = lower_bound;
while (idx > upper_bound) : (idx -= 1) {...}

// index going down
var idx = upper_bound;
while (idx > lower_bound) : (idx -= 1) {...}

// iterator
var iter = ...;
var loop_count = 0;

while (iter.next()) |_| : (loop_count += 1) {
    assert(loop_count < upper_bound);
    ...
}

// boolean loops with bounds
var running = true;
var loop_count = 0;
while (running) : (loop_count += 1) {...}
```

and these are not allowed (unless excepted above).
```zig
// iterators without bounds
var iter = ...;

while (iter.next()) |_| {...}

// boolean loops without bounds
while (running) {...}
```

Still use iterators and boolean based loops, but ensure they don't loop indefinitely.

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

