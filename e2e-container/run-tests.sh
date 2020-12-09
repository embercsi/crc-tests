#!/bin/bash
set -e
set -x
set -o pipefail

# Filter out the tests we don't care about to make the test run faster
./extended-platform-tests run openshift/csi --dry-run | ./filter-tests.py > tests.txt
# Now use the tests to create a suite
./extended-platform-tests run openshift/csi --file tests.txt
