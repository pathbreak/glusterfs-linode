#!/bin/bash

# Tests sequential single threaded read/write throughput and latency,
# with different flags such as direct, dsync, sync, fsync, fdatasync.
# Uses fullblock for all tests.
#
# For throughput write tests, use count=1 so that just 1 single block is read and writtem,
# and test block sizes from 64K to >RAM.
dd_out=$(dd if="$1" of="$2" bs=$3 count=$4 iflag=fullblock oflag=sync 2>&1|grep copied|cut -d ',' -f2,3)
ts=$(date +%H:%M:%S)
record="$ts,$dd_out"

# For read tests, first drop cached data.
echo 3 > /proc/sys/vm/drop_caches
