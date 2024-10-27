#! /usr/bin/env nix-shell 
#! nix-shell -i bash -p flamegraph linuxKernel.packages.linux_xanmod_stable.perf
## TODO: make this generic perf for whatever kernel they are running.

mkdir tmp

./zig-out/bin/walrus-bar $@ &
let PID=$!

sleep 5

sudo perf record -F 512 -a -g -p $PID -o ./tmp/perf.data &

sleep 60

kill $PID

fg

sudo chown $USER ./tmp/perf.data
perf script -i ./tmp/perf.data | stackcollapse-perf.pl > ./tmp/out.perf-folded
flamegraph.pl ./tmp/out.perf-folded > ./tmp/perf.svg
firefox ./tmp/perf.svg

exit
