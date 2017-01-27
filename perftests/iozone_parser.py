'''
Module to parse iozone output reports and produce CSV files with
descriptive row and column labels.

Requirement: iozone should have been invoked with -R option, to produce tables like there:
"Writer report"
        "4"
"16"   173944 
"32"   235549 
"64"   340306 

"Re-writer report"
        "4"
"16"   516994 
"32"   562037 
"64"   653436 

Given the name of the report such as 'Writer', this parser will extract data under that report,
replace the row and column labels with descriptive names like "16KB file" / "1GB file" and "4KB".
All KB/s data values are converted to MB/s
All microseconds data values are converted to secs

Usage:
-----
$ python iozone_parser.py <iozone output file> <report name> <csv output file>
example:
$ python iozone_parser.py iozone.txt Writer iozone_write_tests.csv
'''

from __future__ import print_function

import sys
import re
import argparse
import csv

# Generated from curl "http://www.iozone.org/src/current/iozone.c" | grep -E '"\\n%c(.+) report%c\\n"' 
report_types = ['Writer', 'Re-writer', 'Reader', 'Re-Reader', 
                'Random read', 'Random write', 
                'Backward read', 'Record rewrite', 'Stride read', 
                'Fwrite', 'Re-Fwrite', 'Fread', 'Re-Fread', 
                'Pwrite', 'Re-Pwrite', 'Pread', 'Re-Pread', 
                'Pwritev', 'Re-Pwritev', 'Preadv', 'Re-Preadv']

def generate_csv(opts):
    # Read iozone report
    iozone_report = read_iozone_report(opts.iozone_report_file)
    
    # print(iozone_report)
    
    # Extract requested report data if available.
    report_data = find_report(iozone_report, opts.report_type)
    if not report_data:
        print("Error: %s report not found in %s" % (opts.report_type, opts.iozone_report_file))
        return False
    
    #print(report_data)
    
    # Extract other information like units.
    units = extract_units(iozone_report)
    if not units:
        print("Error: Unable to find units of reported values")
        return False
        
    #print(units)
   
    # Transform report data to CSV.
    csv_output = transform(report_data, units)
    if not csv_output:
        print("Error: Unable to transform data to CSV. Possibly empty data")
        return False
        
    #print(csv_output)
    
    # Write CSV
    with open(opts.csv_file, 'w') as f:
        f.write(csv_output)
        
    # Verify CSV.
    try:
        with open(opts.csv_file, 'rb') as f:
            reader = csv.reader(f)
            for row in reader:
                pass
    except csv.Error:
        print("Error: Something wrong in output CSV. Possibly iozone output format has changed.")
        return False
    
    print("Generated %s" % (opts.csv_file))
    return True


def read_iozone_report(iozone_report_file):
    
    with open(iozone_report_file, 'r') as f:
        iozone_report = f.read()
        
    return iozone_report



def find_report(iozone_report, report_type):
    # Find sections which look like this:
    # ...
    # "Writer report"
    #    "4"
    # ...
    # The report data spans from this point to either start of next report,
    # of if there is no next report to EOF.
    
    pattern = '^\"%s report\"$' % (report_type)
    m = re.search(pattern, iozone_report, re.MULTILINE)
    if not m:
        return None
    report_start = m.end()
    
    next_report = re.search('^\".+ report\"$', iozone_report[report_start:], re.MULTILINE)
    #print(iozone_report[report_start + next_report.start() : report_start + next_report.end()])
    report_end = report_start + next_report.start() if next_report else -1
    
    return iozone_report[report_start:report_end]



def extract_units(iozone_report):
    
    # We need the units of reported values, so we can convert correctly.
    # iozone reports units in a line like this:
    #   Output is in Kbytes/sec
    #   Output is in operations per second.
    #   Output is in microseconds per operation.
    #   Output is in ops/sec
    #   Output is in microseconds/op
    # This parser searches for lines with "Output is in" and then searches (case insensitive)
    # for kbytes, operations|ops, microseconds
    m = re.search('.+Output is in (.+)$', iozone_report, re.MULTILINE)
    if not m:
        return None
        
    units_str = m.groups()[0].lower()
    if 'kbytes' in units_str:
        return 'kb'
        
    elif 'microseconds' in units_str:
        return 'microseconds'
        
    elif any(s in units_str for s in ['operations', 'ops']):
        return 'ops'
    
    return None



def transform(report_data, units):
    '''
    report_data is the data section extracted from the full report, of the form:
                "4"  "8"  "16"  "32"  "64"  "128"  "256"  "512"  "1024"  "2048"  "4096"  "8192"  "16384"
        "4096"   503811  526137  541732  481150  531937  501282  426799  463809  502632  488970  486285 
        "8192"   475423  524729  519430  542732  507058  476829  463582  485424  464529  465057  489812  450059 
        "16384"   468813  513894  540830  543740  511709  503023  487563  461496  488592  473226  489500  478505  501317        ..
        ..
        ..
    
    '''
    # First line tells us how many data columns there are.
    # Subsequent lines will be "<Filesize>" followed by max that many data columns.
    # But if file size is less than record length, there won't be any values. So number of columns
    # need not be same in every row.
    # Columns can be split on whitespaces.
    lines = [line.strip() for line in report_data.splitlines() if line.strip()]
    if not lines:
        return None
        
    # Get header row, and modify column headers to strip out double quotes
    # and append a KB or MB depending on value < or >= 1024
    header = lines[0].split()
    header_values = [int(col.strip('"')) for col in header]
    header = ['%d KB'%(col) if col<1024 else '%d MB'%(col/1024) for col in header_values]
    header.insert(0, 'filesize')
    header_row = ','.join(header)
    
    csv_output = header_row + '\n'        
    
    for dataline in lines[1:]:
        values = dataline.split()
        filesize = int(values[0].strip('"'))
        if filesize < 1024:
            filesize = '%d KB'%(filesize)
            
        elif filesize < 1024 * 1024:
            filesize = '%d MB'%(filesize/1024)
            
        else:
            filesize = '%d GB'%(filesize/(1024*1024))
        values[0] = filesize
        
        if units == 'kb':
            # Convert to MB
            values[1:] = [float(int(v)/1024.0) for v in values[1:]]
        
        values_row = ','.join([str(v) for v in values])
        
        # Rows which have file size less than record lengths won't have 
        # any columns above file size.
        # So add as many commas as required to match header row.
        values_row += ',' * (len(header) - len(values))
    
        csv_output += values_row + '\n'
    
    return csv_output
    
    

def parse_options():
    parser = argparse.ArgumentParser(description='Convert iozone output reports to CSV reports')
    
    parser.add_argument('iozone_report_file', metavar=' IOZONE-REPORT-FILE ', 
                        help='Iozone report file generated with -R option')
                        

    parser.add_argument('report_type', metavar=" 'REPORT-TYPE' ", choices = report_types,
                        help='Name of the report.\n'  + str(report_types))

    parser.add_argument('csv_file', metavar=' CSV-FILE ', 
                        help='CSV file to generate')
                        
    args = parser.parse_args()
    return args


    
if __name__ == '__main__':
    opts = parse_options()
    # print(opts)
    
    success = generate_csv(opts)
    
    sys.exit(0 if success else 1)

