#!/bin/bash
set -euo pipefail
# Script called by pure-ftpd when a file is uploaded.
# This file is a part of the haukex/docker-pure-ftpd repository.
# Please see the README for author, copyright, and license info.

# https://github.com/jedisct1/pure-ftpd/blob/30cbb915/README#L1442
# The absolute path of the newly uploaded file is passed as a first argument.
# Some environment variables are also filled with interesting values:
# - UPLOAD_SIZE  : the size of the file, in bytes.
# - UPLOAD_PERMS : the permissions, as an octal value.
# - UPLOAD_UID   : the uid of the owner.
# - UPLOAD_GID   : the group the file belongs to.
# - UPLOAD_USER  : the name of the owner.
# - UPLOAD_GROUP : the group name the file belongs to.
# - UPLOAD_VUSER : the full user name, or the virtual user name. (127 chars max)

upload_log="/srv/ftp/upload.log"
valkey_stream="pure-ftpd.uploads"

now="$(date -Ins)"
new_file="$1"
virtual_user="${UPLOAD_VUSER:-<unknown>}"
file_size="${UPLOAD_SIZE:--1}"

logger -p ftp.info -t uploadscript.sh "[$now] Upload file $new_file size $file_size by $virtual_user"

if [[ -z "${DISABLE_UPLOAD_LOG:-}" ]]; then
    # Open a file descriptor for locking
    exec 200>>"$upload_log"
    # Acquire exclusive lock on the log file
    if flock -w 10 -x 200; then
        # Append log entry
        printf '%s\t%s\t%s\t%s\n' "$now" "$virtual_user" "$file_size" "$new_file" >&200
        # Lock is released automatically when script ends (or FD 200 is closed)
        logger -p ftp.debug -t uploadscript.sh "[$now] Wrote to $upload_log"
    else
        logger -p ftp.error -t uploadscript.sh "[$now] FAILED to acquire flock on $upload_log"
    fi
fi

if [[ -n "${VALKEY_HOST:-}" ]]; then
    if valkey-cli -t 10 -h "$VALKEY_HOST" XADD "$valkey_stream" \* time "$now" user "$virtual_user" size "$file_size" name "$new_file"; then
        logger -p ftp.debug -t uploadscript.sh "[$now] Success: valkey-cli -t 10 -h $VALKEY_HOST XADD $valkey_stream * ..."
    else
        logger -p ftp.warning -t uploadscript.sh "[$now] FAILED: valkey-cli -t 10 -h $VALKEY_HOST XADD $valkey_stream * ..."
    fi
fi
