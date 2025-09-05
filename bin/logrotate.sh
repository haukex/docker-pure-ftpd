#!/bin/bash
set -euo pipefail
# Script to rotate the FTP log and compress the old one.
# Maximum log size is configured in the rsyslog config.
# This file is a part of the haukex/docker-pure-ftpd repository.
# Please see the README for author, copyright, and license info.

old_name="/var/log/pure-ftpd/ftpd.log"
new_name="$old_name.$(date +%Y-%m-%d-%H-%M-%S-%N)"

mv -n "$old_name" "$new_name"
chown pure-ftpd "$new_name"
chmod a+r "$new_name"
/usr/bin/gzip -9 "$new_name"

logger -p ftp.info -t logrotate.sh "Rotated $old_name to $new_name.gz"
