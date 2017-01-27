#!/bin/bash

# Script for comprehensive iozone tests.
#
# Runs iozone with [regular | sync | direct] options.
# Runs with speed, multi-threaded throughput, IOPS and response time results.
# Records start time and end time for each run, so that time variability of
# system can be evaluated.
#
# Since excel report has shortcomings like - values are reported in fixed units like KB/s 
# or microseconds, and column and row labels are not descriptive - it's not generated.
# Instead output is run through a custom python parser which extracts report information, 
# , cleans up its row and column information, and generates ready-to-process CSV files.

# Note for read and random tests:
# For read test to work, a previous iozone write test should have produced a "iozone.tmp"
# in current dir. Since iozone read is very sensitive to file size and contents of this temp file,
# the simplest way to do this is to run write test too when running read or random tests.

# Multi process throughput mode on single machine:
# iozone's throughput mode behavior is:
# - All the access mode flags like -o, -+D, -+r, -I are allowed
# - Reporting in microsecs/op (ie, -N) is NOT supported.
# - All the usual tests can be specified. In addition, "-i 8" random mix of readers+writers is a special test.
# - Auto flags like record length and file sze range are not allowed
# - A throughput test has to be done at specific -r size and -s size. If nothing is specified,
#      it uses 512 KB file with 4 KB record size.
# - Can specify range of concurrent access threads using -l and -u
# - Specify -C to see bytes transferred by each process.
# - Can't specify target path using -f, but should use -F and specify as many paths as -u. 
#       example: -F ~/tmp/iozoneth{1,2,3}.tmp
#   If by chance -F specifies less files than max number of processes, iozone refuses to 
#   start testing with "not enough filenames for 2 streams"
#   Since each -F file will be -s GB, ensure that the target device has (-u x -s) free space
#   before starting.
# - -U unmount and remount between tests CANNOT be specified in throughput mode.      
#
# This script overcomes shortcomings of iozone's multi-process throughput mode:
#   - Allows a range of values for file sizes and record lengths, and iterates through them
#   - Specify only the target path. This script will create required number of tmp files there.


print_usage() {
    echo
    echo 'Usage:'
    echo
    echo 'iozone_tests.sh  <TARGET-PATH> <REPORTS-DIRECTORY>  ALL|WRITE|READ|RANDOM|MULTI|DIST [OPTIONAL FLAGS]'
    echo
    echo '  <TARGET-PATH> -> A directory on target device where temp file is created for testing.'
    echo '  <REPORTS-DIRECTORY> -> Directory where output and conf files should be stored.'
    echo '  ALL|WRITE|READ|RANDOM|MULTI||DIST -> Type of tests to run. '
    echo '      WRITE|READ|RANDOM are single stream tests.'
    echo '      SINGLE runs all these 3 single stream tests.'
    echo '      MULTI runs multi process tests on local machine.'
    echo '      DIST runs MULTI tests on multiple machines, including optionally on local machine,'
    echo '           and downloads their reports.'
    echo
    echo 'OPTIONAL FLAGS:'
    echo '  numruns=NUMBER-OF-RUNS -> Repeat specified type of tests # times'
    echo '  runwait=SECONDS -> Interval between runs, in seconds. Useful for studying'
    echo '      variability with time in cloud environments.'
    echo
    echo '  filesizes=MIN-MAX] -> Specify file sizes as a range separated by hyphen. example: filesizes=16m-1g'
    echo '  filesizes=s1,s2,...] -> Specify set of file sizes, comma separated. example: filesizes=10m,15g'
    echo
    echo '  blocksizes=MIN-MAX -> Specify block sizes as a range separated by hyphen. example: blocksizes=16m-1g'
    echo '  blocksizes=s1,s2,... -> Specify set of block sizes, comma separated. example: blocksizes=100,3m'
    echo
    echo '  numprocs=MIN[-MAX] -> Specify process count range for MULTI and DIST modes. These many processes'
    echo '      are started on local machine in MULTI or on each specified testing machine in DIST.'
    echo
    echo '  machines=[user1@]IP1,[user2@]IP2,... -> Specify machines for DIST distributed testing. '
    echo '      The script executes itself on each of these machines over SSH.'
    echo '      The machine running the script should have passwordless public key SSH access to them.'
    echo
    echo '  remotereports=<REMOTE-REPORTS-DIRECTORY -> In DIST mode, the directory where the remote machines should save'
    echo '      their reports to. Set this if <REPORTS-DIRECTORY> is not a convenient path on the remote machines.'
    echo
    echo '  unmount=MOUNT-POINT -> Mount point of device where TARGET-PATH exists. '
    echo '      If specified, its unmounted and remounted before every test to ensure cache clearance. Default: undefined,not unmounted'
    echo '      Not used in MULTI mode.'
    echo
    echo '  checkperiod=SECONDS -> In DIST mode, time to wait between checking if tests have completed on all machines.'
    echo '      Set to small value for short tests and large value for long tests.'
    echo
    echo '  nolocal -> Do not run tests on local machine.'
    echo
    echo '  noconfirm -> Do not ask for user confirmation to start the tests.'
    echo
    echo '  terminate -> Special flag to tell tests that have already started to terminate themselves cleanly.'
    echo '      To terminate any running tests, run the script again with ./iostests.sh terminate'
    echo '      This is cleaner and more convenient than killing processes on local and remote machines.'
    echo
    echo '  dryrun -> All logic is run but iozone is not actually called. Dumps the command lines used '
    echo '      for launching iozone. Useful for examining reports and finding problems'
    echo '      before starting a long run.'
}

TERMINATE_FILE="./.iostests_terminate"

# $@ -> Args received by script
parse_args() {
    
    if [ "$1" == 'terminate' ]; then
        echo 'Tests will terminate shortly'
        do_terminate
        exit 0
    fi
    
    
    if [ "x$1" == "x" ]; then
        echo "TARGET-PATH not given."
        print_usage
        exit 1
    fi

    if [ "x$2" == "x" ]; then
        echo "REPORTS-DIR not given."
        print_usage
        exit 1
    fi

    if [ "x$3" == "x" ]; then
        echo "TEST-TYPE not given."
        print_usage
        exit 1
    fi
    
    target_path="$1"
    
    reports_dir="$2"
    mkdir -p "$reports_dir"

    test_type=$(echo "$3"|tr [:upper:] [:lower:])
    
    case "$test_type" in 
      read|write|random|single|multi|dist ) 
        ;;
        
      * ) 
        echo "Invalid test type: $test_type"
        exit 1
        ;;
    esac

    
    local filesize_given=0
    local blocksize_given=0
    
    # IMPORTANT NOTE ABOUT ARRAYS: Don't export any of the arrays, just declare them.
    # Turns out that bash does not support exporting arrays. However, just defining them
    # without export still makes them available to other functions in ths file.
    
    for arg in "${@:4}"
    do
        argname=$(echo "$arg" | cut -d '=' -f1)
        argval="$(echo "$arg" | cut -d '=' -f2)"
        case "$argname" in
            filesizes )
                filesize_given=1
                
                # Check if it's a range like "s1-s2" range or a set like "s1,s2,...".
                if [[ $argval =~ .+-.+ ]]; then

                    # Instead of writing laborious code to expand a range, just tell
                    # user to give all values explicitly.
                    if [[ "$test_type" == 'multi' || "$test_type" == 'dist' ]]; then
                        echo "For MULTI and DIST, give filesizes as a comma separated list. example: filesizes=512m,1g,2g,4g,..."
                        exit 1
                    fi
                    
                    # Export range as an array of 2 values. Get the values later
                    # on with $filesize_range[0] and $filesize_range[1]
                    filesize_range=($(echo "$argval"|tr '-' ' '))
                else
                    # Export range as an array of 1 or more values. Get the values later
                    # on with $filesize_set[0], [1], ...
                    filesize_set=($(echo "$argval"|tr ',' ' '))
                fi
                ;;

            blocksizes )
                blocksize_given=1
                
                # Check if it's a range like "s1-s2" range or a set like "s1,s2,...".
                if [[ $argval =~ .+-.+ ]]; then
                
                    # Instead of writing laborious code to expand a range, just tell
                    # user to give all values explicitly.
                    if [[ "$test_type" == 'multi' || "$test_type" == 'dist' ]]; then
                        echo "For MULTI and DIST, give blocksizes as a comma separated list. example: blocksizes=1m,2m,4m,..."
                        exit 1
                    fi
                    
                    # Export range as an array of 2 values. Get the values later
                    # on with $blocksize_range[0] and $blocksize_range[1]
                    blocksize_range=($(echo "$argval"|tr '-' ' '))
                else
                    # Export range as an array of 1 or more values. Get the values later
                    # on with $blocksize_range[0], [1], ...
                    blocksize_set=($(echo "$argval"|tr ',' ' '))
                fi
                ;;
                
            numprocs )
                local procs=($(echo "$argval"|tr '-' ' '))
                min_procs=${procs[0]}
                max_procs=${procs[1]}
                if [ -z "$max_procs" ]; then
                    max_procs=$min_procs
                fi
                ;;
                
            machines )
                machines=($(echo "$argval"|tr ',' ' '))
                ;;
                
            remotereports )
                # In DIST mode, workers save their reports in this directory
                # instead of REPORTS-DIR.
                remote_reports_dir="$argval"
                ;;
                
            numruns )
                numruns=$argval
                ;;
                
            runwait )
                runwait=$argval
                ;;

            unmount )
                unmount_path="$argval"
                echo "'$unmount_path' will be unmounted between each and every test."
                ;;
                
            checkperiod )
                checkperiod=$argval
                ;;
                
            noconfirm )
                noconfirm=true
                ;;
                
            startat )
                # Internal flag sent to remote workers in distributed mode.
                # The script starts only at specified time. Time specified should be epoch time (date +%s)
                startat=$argval
                ;;
                
            machineindex )
                # Internal flag sent to remote workers in distributed mode.
                # This value is included in tmp file paths so that each process on each machine
                # operates on a separate file on the shared path.
                machineindex=$argval
                ;;
                
            nolocal )
                nolocal=true
                ;;
                
            dryrun )
                dryrun=true
                ;;
                
            * )
                echo "Ignoring unknown argument: $argname"
                ;;
        esac
    done
    
    # Save the list of optional parameters as received. In DIST mode, they are passed
    # verbatim to all workers.
    parameters="${@:4}"
    echo "Parameters: $parameters"
    
    # Set defaults for all variables.
    
    # Since we're testing big data, file sizes are varied from (half of system RAM) to
    # MAX-FILE-SIZE. Block sizes in auto mode are varied from the typical 64KB upto max 16MB.
    # Detect system RAM. This will be in KB.
    if [ $filesize_given -eq 0 ]; then
        system_ram=$(grep MemTotal /proc/meminfo | awk '{print $2}')

        local min_file_size=$((system_ram / 2))
        local max_file_size=$((system_ram * 8))
        printf "Setting default file sizes from half of RAM to 8xRAM: "
        printf "$(awk "BEGIN{print $min_file_size / (1024 * 1024)}") GB - $(awk "BEGIN{print $max_file_size / (1024 * 1024)}") GB\n"
            
        filesize_range=($min_file_size $max_file_size)
    fi

    if [ $blocksize_given -eq 0 ]; then
        local min_block_size=64
        local max_block_size=16m
        echo "Setting default block sizes: $min_block_size - $max_block_size"
        blocksize_range=($min_block_size $max_block_size)
    fi
    
    if [ -z "$remote_reports_dir" ]; then
        remote_reports_dir="$reports_dir"
    fi
    
    if [ -z $min_procs ]; then
        min_procs=1
    fi

    if [ -z $max_procs ]; then
        max_procs=$min_procs
    fi

    if [ -z $numruns ]; then
        numruns=1
    fi

    if [ -z $runwait ]; then
        # Set default runwait to 15 minutes
        runwait=900
    fi
    
    if [ -z $checkperiod ]; then
        checkperiod=60
    fi
}


run_tests() {
    
    for current_run in $(seq $numruns); do
    
        if is_terminated; then
            echo "Tests terminated"
            break
        fi
    
        printf "\n\n\n\n\nRUN #$current_run ****** \n\n\n\n\n"
        
        echo "Writing reports to: $reports_dir/$current_run"
        mkdir -p "$reports_dir/$current_run"

        case "$test_type" in 
          read ) 
            read_tests
            ;;
            
          write ) 
            write_tests
            ;;
            
          random ) 
            random_tests
            ;;
            
          single ) 
            write_tests
            read_tests
            random_tests
            ;;
            
          multi ) 
            multi_stream_tests
            ;;

          all ) 
            write_tests
            read_tests
            random_tests
            multi_stream_tests
            ;;
            
          dist ) 
            distributed_tests
            ;;

        esac
        
        if [ $current_run -lt $numruns ]; then
        
            if is_terminated; then
                echo "Tests terminated"
                break
            fi
            
            echo "Waiting for $runwait seconds before next run"
            sleep $runwait
        fi
    done
}



########################### WRITE TESTS ############################



write_tests() {
    
    printf "\n\n\nWRITE TESTS ***\n\n\n"

    if is_terminated; then
        echo "Tests terminated"
        return
    fi 
    

    # Single stream write throughput tests with values in KB/s
    run_test 's-w-thru-reg' \
        'single stream write throughput test in regular mode' \
        single_stream_write_regular_mode

    run_test 's-w-thru-sync' \
        'single stream write throughput test in full sync mode' \
        single_stream_write_sync_mode

    run_test 's-w-thru-dsync' \
        'single stream write throughput test in data sync mode' \
        single_stream_write_dsync_mode

    run_test 's-w-thru-dir' \
        'single stream write throughput test in direct I/O mode' \
        single_stream_write_direct_mode



    # Single stream write IOPS tests with values in operations per sec
    run_test 's-w-ops-reg' \
        'single stream write IOPS test in regular mode' \
        single_stream_write_regular_mode "-O"

    run_test 's-w-ops-sync' \
        'single stream write IOPS test in full sync mode' \
        single_stream_write_sync_mode "-O"

    run_test 's-w-ops-dsync' \
        'single stream write IOPS test in data sync mode' \
        single_stream_write_dsync_mode "-O"

    run_test 's-w-ops-dir' \
        'single stream write IOPS test in direct I/O mode' \
        single_stream_write_direct_mode "-O"


    # Single stream write response time tests with values in microsecs
    run_test 's-w-resp-reg' \
        'single stream write response time test in regular mode' \
        single_stream_write_regular_mode "-N"

    run_test 's-w-resp-sync' \
        'single stream write response time in full sync mode' \
        single_stream_write_sync_mode "-N"

    run_test 's-w-resp-dsync' \
        'single stream write response time in data sync mode' \
        single_stream_write_dsync_mode "-N"

    run_test 's-w-resp-dir' \
        'single stream write response time in direct I/O mode' \
        single_stream_write_direct_mode "-N"
}



# $1: Report type option. 
#       Nothing => kB/s
#       -N => microsecs/op 
#       -O => operations per sec
single_stream_write_regular_mode() {
    # Run single stream, write-only test with regular file mode.
    run_iozone_auto "-i 0 $1"
}


# $1: Report type option. 
#       Nothing => kB/s
#       -N => microsecs/op 
#       -O => operations per sec
single_stream_write_sync_mode() {

    # Run single stream, write-only test with sync file mode.
    # In sync mode, writes go to kernel cache, but
    # sync also ensures both data and file integrity completion by flushing
    # both data and metadata changes to disk.
    run_iozone_auto "-i 0 -o $1"
}


# $1: Report type option. 
#       Nothing => kB/s
#       -N => microsecs/op 
#       -O => operations per sec
single_stream_write_dsync_mode() {
    
    # Run single stream, write-only test with dsync mode.
    # In dsync mode, writes go to kernel cache, but
    # dsync ensures data integrity completion by flushing
    # all data changes to disk immediately.
    # But it does not ensure file integrity completion unless required
    # by a read request.
    run_iozone_auto "-i 0 -+D $1"
}


# $1: Report type option. 
#       Nothing => kB/s
#       -N => microsecs/op 
#       -O => operations per sec
single_stream_write_direct_mode() {
    
    # Run single stream, write-only test with direct mode.
    # In direct mode, writes bypass kernel cache and are written
    # directly to the device.
    run_iozone_auto "-i 0 -I $1"
}





########################### READ TESTS ############################





read_tests() {
    printf "\n\n\nREAD TESTS ***\n\n\n"   
    
    if is_terminated; then
        echo "Tests terminated"
        return
    fi 
    
    # Single stream read throughput tests with values in KB/s
    run_test 's-r-thru-reg' \
        'single stream read throughput test in regular mode' \
        single_stream_read_regular_mode

    run_test 's-r-thru-sync' \
        'single stream read throughput test in full sync mode' \
        single_stream_read_sync_mode

    run_test 's-r-thru-dsync' \
        'single stream read throughput test in data sync mode' \
        single_stream_read_dsync_mode

    run_test 's-r-thru-dir' \
        'single stream read throughput test in direct I/O mode' \
        single_stream_read_direct_mode



    # Single stream read IOPS tests with values in operations per sec
    run_test 's-r-ops-reg' \
        'single stream read IOPS test in regular mode' \
        single_stream_read_regular_mode "-O"

    run_test 's-r-ops-sync' \
        'single stream read IOPS test in full sync mode' \
        single_stream_read_sync_mode "-O"

    run_test 's-r-ops-dsync' \
        'single stream read IOPS test in data sync mode' \
        single_stream_read_dsync_mode "-O"

    run_test 's-r-ops-dir' \
        'single stream read IOPS test in direct I/O mode' \
        single_stream_read_direct_mode "-O"


    # Single stream read response time tests with values in microsecs
    run_test 's-r-resp-reg' \
        'single stream read response time test in regular mode' \
        single_stream_read_regular_mode "-N"

    run_test 's-r-resp-sync' \
        'single stream read response time in full sync mode' \
        single_stream_read_sync_mode "-N"

    run_test 's-r-resp-dsync' \
        'single stream read response time in data sync mode' \
        single_stream_read_dsync_mode "-N"

    run_test 's-r-resp-dir' \
        'single stream read response time in direct I/O mode' \
        single_stream_read_direct_mode "-N"
}


# $1: Report type option. 
#       Nothing => kB/s
#       -N => microsecs/op 
#       -O => operations per sec
single_stream_read_regular_mode() {
    # Run single stream, read after write (iozone requires that write should be done before read) test with regular file mode.
    drop_cache
    run_iozone_auto "-i 0 -i 1 $1"
}


# $1: Report type option. 
#       Nothing => kB/s
#       -N => microsecs/op 
#       -O => operations per sec
single_stream_read_sync_mode() {

    # Run single stream, read after write (iozone requires that write should be done before read) test with sync file mode.
    # In sync mode, reads go to kernel cache, but
    # sync also ensures both data and file integrity completion by flushing
    # both data and metadata changes to disk.
    drop_cache
    run_iozone_auto "-i 0 -i 1 -o -+r $1"
}


# $1: Report type option. 
#       Nothing => kB/s
#       -N => microsecs/op 
#       -O => operations per sec
single_stream_read_dsync_mode() {
    
    # Run single stream, read after write (iozone requires that write should be done before read) test with dsync mode.
    # In dsync mode, reads go to kernel cache, but
    # dsync ensures data integrity completion by flushing
    # all data changes to disk immediately.
    # But it does not ensure file integrity completion unless required
    # by a read request.
    drop_cache
    run_iozone_auto "-i 0 -i 1 -+D $1"
}


# $1: Report type option. 
#       Nothing => kB/s
#       -N => microsecs/op 
#       -O => operations per sec
single_stream_read_direct_mode() {
    
    # Run single stream, read after write (iozone requires that write should be done before read) test with direct mode.
    # In direct mode, reads bypass kernel cache and are written
    # directly to the device.
    drop_cache
    run_iozone_auto "-i 0 -i 1 -I $1"
}






########################### RANDOM R/W TESTS ############################





random_tests() {
    printf "\n\n\nRANDOM TESTS ***\n\n\n"    
    
    if is_terminated; then
        echo "Tests terminated"
        return
    fi 
    
    
    # Single stream random throughput tests with values in KB/s
    run_test 's-rnd-thru-reg' \
        'single stream random throughput test in regular mode' \
        single_stream_random_regular_mode

    run_test 's-rnd-thru-sync' \
        'single stream random throughput test in full sync mode' \
        single_stream_random_sync_mode

    run_test 's-rnd-thru-dsync' \
        'single stream random throughput test in data sync mode' \
        single_stream_random_dsync_mode

    run_test 's-rnd-thru-dir' \
        'single stream random throughput test in direct I/O mode' \
        single_stream_random_direct_mode



    # Single stream random IOPS tests with values in operations per sec
    run_test 's-rnd-ops-reg' \
        'single stream random IOPS test in regular mode' \
        single_stream_random_regular_mode "-O"

    run_test 's-rnd-ops-sync' \
        'single stream random IOPS test in full sync mode' \
        single_stream_random_sync_mode "-O"

    run_test 's-rnd-ops-dsync' \
        'single stream random IOPS test in data sync mode' \
        single_stream_random_dsync_mode "-O"

    run_test 's-rnd-ops-dir' \
        'single stream random IOPS test in direct I/O mode' \
        single_stream_random_direct_mode "-O"


    # Single stream random response time tests with values in microsecs
    run_test 's-rnd-resp-reg' \
        'single stream random response time test in regular mode' \
        single_stream_random_regular_mode "-N"

    run_test 's-rnd-resp-sync' \
        'single stream random response time in full sync mode' \
        single_stream_random_sync_mode "-N"

    run_test 's-rnd-resp-dsync' \
        'single stream random response time in data sync mode' \
        single_stream_random_dsync_mode "-N"

    run_test 's-rnd-resp-dir' \
        'single stream random response time in direct I/O mode' \
        single_stream_random_direct_mode "-N"
}




# $1: Report type option. 
#       Nothing => kB/s
#       -N => microsecs/op 
#       -O => operations per sec
single_stream_random_regular_mode() {
    # Run single stream, random r/W after write (iozone requires that write should be done before random) test with regular file mode.
    drop_cache
    run_iozone_auto "-i 0 -i 2 $1"
}


# $1: Report type option. 
#       Nothing => kB/s
#       -N => microsecs/op 
#       -O => operations per sec
single_stream_random_sync_mode() {

    # Run single stream, random R/W after write (iozone requires that write should be done before random) test with sync file mode.
    # In sync mode, random R/W go to kernel cache, but
    # sync also ensures both data and file integrity completion by flushing
    # both data and metadata changes to disk.
    drop_cache
    run_iozone_auto "-i 0 -i 2 -o -+r $1"
}


# $1: Report type option. 
#       Nothing => kB/s
#       -N => microsecs/op 
#       -O => operations per sec
single_stream_random_dsync_mode() {
    
    # Run single stream, random after write (iozone requires that write should be done before random) test with dsync mode.
    # In dsync mode, random R/W go to kernel cache, but
    # dsync ensures data integrity completion by flushing
    # all data changes to disk immediately.
    # But it does not ensure file integrity completion unless required
    # by a random request.
    drop_cache
    run_iozone_auto "-i 0 -i 2 -+D $1"
}


# $1: Report type option. 
#       Nothing => kB/s
#       -N => microsecs/op 
#       -O => operations per sec
single_stream_random_direct_mode() {
    
    # Run single stream, random after write (iozone requires that write should be done before random) test with direct mode.
    # In direct mode, random R/W bypass kernel cache and are written
    # directly to the device.
    drop_cache
    run_iozone_auto "-i 0 -i 2 -I $1"
}






########################### MULTI-PROCESS THROUGHPUT TESTS ############################





multi_stream_tests() {
    printf "\n\n\nMULTI PROCESS THROUGHPUT TESTS ***\n\n\n"    

    if is_terminated; then
        echo "Tests terminated"
        return
    fi 
    

    # Since iozone does not support range of file sizes and block sizes
    # for multiprocess tests, we need to iterate through them explicitly.
    
    # for each file size
    for temp_filesize in "${filesize_set[@]}"
    do
        
        for temp_blocksize in "${blocksize_set[@]}"
        do
            printf "\n\n\nFile: $temp_filesize, Block: $temp_blocksize tests ***\n\n\n"
            
            local options="-s $temp_filesize -r $temp_blocksize"

            # Run throughput tests with different file modes, and report
            # in KB/sec.
            run_test 'm-thru-reg' \
               'multi stream throughput test in regular mode' \
                run_iozone_multi "$options"
                
            run_test 'm-thru-sync' \
                'multi stream throughput test in full sync mode' \
                run_iozone_multi "$options -o -+r"

            run_test 'm-thru-dsync' \
                'multi stream throughput test in data sync mode' \
                run_iozone_multi "$options -+D"

            run_test 'm-thru-dir' \
                'multi stream throughput test in direct I/O mode' \
                run_iozone_multi "$options -I"

            # Run IOPS tests with different file modes, and report
            # in IOPS/sec.
            run_test 'm-ops-reg' \
               'multi stream IOPS test in regular mode' \
                run_iozone_multi "$options -O"
                
            run_test 'm-ops-sync' \
                'multi stream IOPS test in full sync mode' \
                run_iozone_multi "$options -o -+r -O"

            run_test 'm-ops-dsync' \
                'multi stream IOPS test in data sync mode' \
                run_iozone_multi "$options -+D -O"

            run_test 'm-ops-dir' \
                'multi stream IOPS test in direct I/O mode' \
                run_iozone_multi "$options -I -O"

            # Reporting in response time units is not supported by iozone
            # in this mode.
        done
    done
}










########################### DISTRIBUTED TESTS ############################





distributed_tests() {
    printf "\n\n\nDISTRIBUTED MULTI PROCESS THROUGHPUT TESTS ***\n\n\n"    

    if is_terminated; then
        echo "Tests terminated"
        return
    fi 
    

    # Run this script on remote machines in multi mode with the same parameters
    # received.
    #   iotests.sh <TARGET> <REPORTS> MULTI numprocs= filesizes= blocksizes=

    # If there are no machines specified, these tests are run only locally.
    # If there are machines specified, this runs on them as well as locally.
    
    # SCP and SSH can be a lot faster by persisting connections. Since
    # the tests can take a decent time, we'll persist connections for upto 1 hour.
    local fast_ssh_options='-o ControlMaster=auto -o ControlPath=/tmp/ssh%r@%h-%p -o ControlPersist=3600'
    
    local num_remote=0
    if [ ! -z "$machines" ]; then
        num_remote=${#machines[@]}

        # Copy this script to each machine.
        for machine in "${machines[@]}"
        do
            if is_terminated; then
                echo "Tests terminated"
                return
            fi 
        
            echo "Copying script to $machine"
            scp $fast_ssh_options "${BASH_SOURCE[0]}"  "$machine:."
        done
    fi
    
        
    # Target path handling: In dist mode, every worker machine is launching
    # multiple processes that are reading and writing to temp files on a shared storage path. 
    # Since the storage path is shared, we have to ensure every process across
    # all machines use unique temp file names. So temp files can't be named the usual
    # "iozone<PROCESS#>.tmp", but require an additional field - perhaps the machine index
    # so it becomes "iozone<MACHINE#>-<PROCESS#>.tmp"
    
    local local_cmdline="./iozone_tests.sh $target_path $reports_dir MULTI noconfirm $parameters"
    local remote_cmdline="./iozone_tests.sh $target_path $remote_reports_dir MULTI noconfirm $parameters"


    # If we assume connecting and launching process takes 8 secs per remote machine,
    # then we can set startat flag so that all machines try to start tests nearly at the same time.
    if [ $num_remote -ge 0 ]; then
        local current_epoch=$(date +%s)
        local startat=$(( $current_epoch + 8 * $num_remote ))
        local_cmdline="$local_cmdline startat=$startat"
        remote_cmdline="$remote_cmdline startat=$startat"
    fi
    
    if is_terminated; then
        echo "Tests terminated"
        return
    fi 
    
    # Remote scripts should be launched with & to send them to background, and with nohup 
    # so that SSH sessions can immediately exit without terminating the remote scripts.
    # This script can then continue its logic, reopening SSH sessions periodically to check if tests have completed.
    
    # Launch iotests.sh on local machine, and store its PID.
    # The redirections here do not affect the script's ability to redirect its output
    # to report files.
    local temp_cmdline
    if [ -z "$nolocal" ]; then
        printf "\n\nStarting tests on local machine"
        temp_cmdline="$local_cmdline machineindex=0"
        local local_pid
        $temp_cmdline < /dev/null &
        local_pid=$!
    fi

    # Launch iotests.sh on remote machines and store their PIDs.
    # Termination handling: 
    #   - If tests are not at all started on a machine,
    #     then don't start them, but add 0 PID so that machine count and PID count
    #     are consistent.
    #   - If tests are already started on a machine, then tell it to terminate
    #     itself via SSH.
    local remote_pids
    if [ $num_remote -ge 0 ]; then
    
        local machine_index=1
        for machine in "${machines[@]}"
        do
            echo "Starting tests on $machine"

            # On each machine
            # Give each machine a unique index so that tmp file names of processes 
            # running on different machines don't collide.
            temp_cmdline="$remote_cmdline machineindex=$machine_index"
            
            # Start iotests.sh in multi mode with same process count, file sizes and block size parameters,
            # and store PID. 
            local remote_pid
            if is_terminated; then
                echo "Tests terminated. Not starting tests on $machine"
                remote_pid=0
            else
                # Slash(\) before $! is necessary here to prevent local bash thinking it's a local variable
                # and substituting its value, instead of sending it verbatim to remote machine.
                remote_pid=$(ssh $fast_ssh_options "$machine" "mkdir -p $remote_reports_dir; nohup $temp_cmdline \
                    < /dev/null > "$remote_reports_dir/iozone_tests.log" 2> /dev/null & echo \$!")
                echo "Running on $machine with PID $remote_pid"
            fi
            
            # List of remote PIDs will be in same order as list of machines.
            remote_pids="$remote_pids $remote_pid"
            
            machine_index=$((machine_index+1))
        done
    fi
    
    
    remote_pids=($remote_pids)
    echo "Remote PIDs: ${remote_pids[@]}"
    echo "# of remote PIDs: ${#remote_pids[@]}"
    
    echo "Tests started on all machines"
    
    local temp
    
    # For each PID, periodically SSH into machine and see if PID is still running.
    # Once any PID is completed, use rsync to download all report files.
    while true; do
    
        sleep $checkperiod
        
        printf "\n\nChecking if tests have completed...\n\n"
        
        local all_completed=true
        
        # First check if tests on local machine have completed, and if so,
        # set local PID to 0 to stop further checks.
        # kill -0 does not actually kill, but does return 0 or 1 if PID is running or not.
        # Redirect its stdout and stderr, otherwise it prints out an error if PID is not found.
        if [ -z "$nolocal" ]; then
            if [ $local_pid -ne 0 ]; then
                temp=$(kill -0 $local_pid > /dev/null 2> /dev/null)
                if [ $? -eq 0 ]; then
                    echo "Tests still running on local machine"
                    all_completed=false
                else
                    echo "Completed on local machine"
                    local_pid=0
                fi
            fi
        fi
        
        if [ $num_remote -ge 0 ]; then
            local idx=0
            
            local pid_status
            
            for idx in $(seq 0 $((num_remote-1)))
            do
                local machine="${machines[$idx]}"
                
                local remote_pid=${remote_pids[$idx]}
                
                echo "Checking remote PID on $machine: $remote_pid"
                
                if [ $remote_pid -eq 0 ]; then
                    echo "Tests already completed on $machine"
                    continue
                fi

                # Just tell remote machine to terminate itself, and wait for
                # its PID to end like usual.
                if is_terminated; then
                    echo "Informing $machine to terminate itself"
                    ssh $fast_ssh_options "$machine" "./iozone_tests.sh terminate"
                fi 
    
                
                printf "Checking if tests completed on $machine..."
                ssh $fast_ssh_options "$machine" "kill -0 $remote_pid > /dev/null 2> /dev/null"
                pid_status=$?
                if [ $pid_status -eq 1 ]; then
                    printf 'YES\n'
                    remote_pids[$idx]=0
                    
                    echo "Updated Remote PIDs: ${remote_pids[@]}"
                    
                    # Download reports and store in "$reports_dir/$machine"
                    echo "Downloading reports to $reports_dir/$machine..."
                    local destdir="$reports_dir/$machine"
                    mkdir -p "$destdir"
                    rsync -av "$machine:$remote_reports_dir/" "$reports_dir/$machine"
                    echo "Downloaded"
                    
                else
                    printf 'NO\n'
                    all_completed=false
                fi
            done
        fi
        
        if is_terminated; then
            echo "Terminating distributed tests"
            break
        fi 
        
        if [ "$all_completed" == "false" ]; then
            printf "\nWaiting $checkperiod seconds for completion\n"
        else
            printf "\n\n\nDISTRIBUTED TESTS COMPLETED ****\n\n\n"
            break
        fi
    done
    
}





#################################################################################





# $1: label for test
# $2: description for test (displayed to user)
# $3: test function to call
# $4: additional options to pass to $3
run_test() {
    
    if is_terminated; then
        echo "Tests terminated"
        return
    fi 
    
    
    echo "Start: $2"
    local start_ts=$(date +%Y-%m-%d-%H-%M-%S)
    local report_file="$reports_dir/$current_run/ioz-$1-$start_ts.out"
    local test_info_file="$reports_dir/$current_run/ioz-$1-$start_ts.conf"
    
    # Run the test by calling specified function
    $3 "$4" | tee "$report_file"
    
    local end_ts=$(date +%Y-%m-%d-%H-%M-%S)
    echo "path=$target_path" > "$test_info_file"
    echo "start=$start_ts" >> "$test_info_file"
    echo "end=$end_ts" >> "$test_info_file"
    
    echo "End: $2"
    echo
}


# $1: Additional options
run_iozone_auto() {
    
    local options="-a -c -e $1 -R -f $target_path/iozone.tmp"
    if [ ! -z "$filesize_range" ]; then
        options="$options -n ${filesize_range[0]} -g ${filesize_range[1]}"
    else
        for sz in ${filesize_set[*]}
        do
            options="$options -s $sz"
        done
    fi
    
    if [ ! -z "$blocksize_range" ]; then
        options="$options -y ${blocksize_range[0]} -q ${blocksize_range[1]}"
    else
        for sz in ${blocksize_set[*]}
        do
            options="$options -r $sz"
        done
    fi
    
    if [ ! -z "$unmount_path" ]; then
        options="$options -U $unmount_path"
    fi
    
    if [ ! -z "$dryrun" ]; then
        echo "Dry run: Running iozone with options:$options"
        
        sleep 5
    else
        
        # WARN: Don't put $options in double quotes here. If that's done, it's sent as a 
        # single argument and iozone fails with unrecognized option null.
        
        iozone $options
    fi
    
    
}


# $1: Additional options
run_iozone_multi() {
    
    local tempfiles
    for idx in $(seq $max_procs)
    do
        tempfiles="$tempfiles $target_path/iozone$machineindex-$idx.tmp"
    done
    
    local options="-l $min_procs -u $max_procs -i 0 -i 1 -i 2 -i 8 -C -c -e $1 -R -F $tempfiles"
    
    if [ ! -z "$dryrun" ]; then
        echo "Dry run: Running iozone with options:$options"
        
        sleep 5
    else
        
        # WARN: Don't put $options in double quotes here. If that's done, it's sent as a 
        # single argument and iozone fails with unrecognized option null.
        
        iozone $options
    fi
}

drop_cache() {
    echo 3 > /proc/sys/vm/drop_caches
}


sleep_till_startat_time() {
    if [ ! -z "$startat" ]; then

        current_epoch=$(date +%s)
        
        sleep_seconds=$(( $startat - $current_epoch ))

        sleep $sleep_seconds
    fi
}

do_terminate() {
    # Termination works by writing a special hidden file to executing directory.
    # Each of the test groups check for it before starting and don't run their tests
    # if found.
    #
    # IMPORTANT: The termination file deletion is done only by the main script
    # Testing functions SHOULD NOT exit the script or delete the termination file.
    #
    # If a test group has already started, each of the tests in the group also check for
    # it and don't run their tests if found.
    # In distributed mode, each of the worker machines is also told to terminate itself.
    
    # TODO: There is one unsolved problem in termination handling in distributed
    #   mode. On local machine when running in dist mode without nolocal flag, 
    #   there are 2 processes running this script - one is the master process which
    #   was called with DIST, and other is the slave process it starts locally
    #   with MULTI. 
    #   Now, if user wishes to terminate tests and issues a 'iozone_tests.sh terminate',
    #   it creates a special hidden file that other iozone_tests processes look for and
    #   terminate themselves cleanly.
    #   In this case, *both* processes - master and slave - will find its presence since both are looking in
    #   the same location. The local slave process will terminate its tests, and delete
    #   the special terminate file. Potentially, the master process executing distributed logic
    #   will no longer find the special terminate file and continue, possibly without having informed
    #   some of the remote slaves to terminate themselves.
    #
    #   Possible Solutions: Since root cause is the use of a common terminate file by 2 processes
    #     (could be >2 too, if one of the machines is localhost or local IP address), perhaps
    #     solution is to use multiple PID specific terminate files only in dist mode. The terminate
    #     process can create a master special file and exit. The DIST master looks for it, and informs
    #     remote workers to terminate using a special cmd line that creates a remotePID special terminate
    #     file per worker. Each worker then looks for its own PID special file. If found, it knows it's
    #     running as a slave and deletes only its own PID file. If not found, it knows it's running in
    #     normal MULTI mode and deletes the regular special file.
    
    touch "$TERMINATE_FILE"
}

is_terminated() {
    if [ -f "$TERMINATE_FILE" ]; then
        return 0
    fi
    return 1
}

done_termination() {
    if [ -f "$TERMINATE_FILE" ]; then
        rm "$TERMINATE_FILE"
    fi
}



########################### MAIN ############################


parse_args "$@"

sleep_till_startat_time

if [ -z "$noconfirm" ]; then
    read -p "Start testing (y/n)?" choice
    case "$choice" in 
      y|Y ) 
        run_tests
        ;;
        
      n|N ) 
        exit 0
        ;;
        
      * ) 
        echo "invalid"
        exit 1
        ;;
    esac

else
    run_tests
fi

    
# In case termination file is present, delete it here so that future runs
# are not affected.
done_termination

