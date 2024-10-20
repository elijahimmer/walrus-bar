#! /usr/bin/env nix-shell 
#! nix-shell -i bash -p flamegraph linuxKernel.packages.linux_xanmod_stable.perf
## TODO: make this generic perf for whatever kernel they are running.

./zig-out/bin/walrus-bar &
let PID=$!

mkdir tmp

sudo perf record -F 1028 -a -g -p $PID -o ./tmp/perf.data
sudo chown $USER ./tmp/perf.data
perf script -i ./tmp/perf.data | stackcollapse-perf.pl > ./tmp/out.perf-folded
flamegraph.pl ./tmp/out.perf-folded > ./tmp/perf.svg
firefox ./tmp/perf.svg

exit
