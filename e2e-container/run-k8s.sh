#!/bin/bash
echo `pwd`
./ginkgo -p -v \
  -focus='External.Storage' \
  -skip='ntfs|ephemeral|Pre-provisioned|Inline-volume|\[Disruptive\]|fsgroupchangepolicy' \
  ./e2e.test \
  -- \
  -repo-root=/home/vagrant \
  -storage.testdriver=$TEST_CSI_DRIVER_FILES
