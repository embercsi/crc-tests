#!/bin/bash
set -e
set -x
set -o pipefail

count=${1:-1}
parallel=${2:-0}

# Filter out the tests we don't care about to make the test run faster
./extended-platform-tests run openshift/csi --dry-run | ./filter-tests.py > tests.txt
# Now use the tests to create a suite
./extended-platform-tests run openshift/csi --count $count --max-parallel-tests $parallel --file tests.txt
