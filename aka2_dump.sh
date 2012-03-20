#!/bin/bash

perl -n -e 'm|Joins: (\S+) \((\S+)\)| && print "$2 $1\n";' $@ | sort | uniq
