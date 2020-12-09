#!/usr/bin/env python
import re
import sys

include_regex = re.compile('^((?!ntfs|ephemeral|Pre-provisioned|Inline-volume).)*$')
result = [line for line in sys.stdin if include_regex.match(line)]
print(''.join(result))
