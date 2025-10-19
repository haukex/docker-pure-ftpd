#!/bin/bash
set -euo pipefail
# Script to generate Pure-FTPd users from the Docker secret.
# This file is a part of the haukex/docker-pure-ftpd repository.
# Please see the README for author, copyright, and license info.

secret_file="/run/secrets/ftp-passwd"
passwd_file="/etc/pure-ftpd/pure.passwd"
db_file="/etc/pure-ftpd/puredb.pdb"
base_path="/srv/ftp"
ftp_user="pure-ftpd"
ftp_group="pure-ftpd"

while IFS= read -r line; do
    user="${line%%:*}"
    pass="${line#*:}"
    if [[ ! "$user" =~ ^[a-z_][a-z_.0-9]+$ ]]; then
        echo "Bad username <<$user>>" >&2
        exit 1
    fi
    if [[ ! "$pass" =~ ^[^\ ].{6,}[^\ ]$ ]]; then
        echo "Bad password for user $user" >&2
        exit 1
    fi
    home="$base_path/$user"
    echo "##### user=$user home=$home"
    mkdir -vp "$home"
    chmod -c 2775 "$home"
    chown -Rc "$ftp_user:$ftp_group" "$home"
    find "$home" -type d -exec chmod -c a+rx,u+w,o-w '{}' + -o -exec chmod -c a+r,u+w,o-w '{}' +
    printf '%s\n%s\n' "$pass" "$pass" | pure-pw useradd "$user" -f "$passwd_file" -u "$ftp_user" -d "$home"
done < "$secret_file"

echo "##### Creating DB..."
pure-pw mkdb "$db_file" -f "$passwd_file"
