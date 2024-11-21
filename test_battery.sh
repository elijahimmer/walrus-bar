DIR=/tmp/walrus-bar/battery

mkdir $DIR

echo 50 > $DIR/energy_now
echo 100 > $DIR/energy_full
echo discharging > $DIR/status
