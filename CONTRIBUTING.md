# Contibuting
Any and all (in good faith) contributions are welcome, be they PRs, Issues, etc.
I will try my best to get back to any issues, PRs, and questions. I will also try to provide feedback on what possible issues are with any
PR, before they are merged.

If you have any features you want supported, just ask.
Just don't expect it to be done in general or at any short timespan.

## Style
In general, try to follow NASA's The Power of 10: Rules for Developing Safety-Critical Code

At the moment, we are going against 9, but I may eventually fix that.

### Loops:
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

