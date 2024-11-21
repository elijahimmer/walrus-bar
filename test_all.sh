DIR=/tmp/walrus-bar

mkdir $DIR

echo "
[battery]
directory=./battery

[brightness]
directory=./brightness

" > $DIR/config.ini

./test_brightness.sh
./test_battery.sh
