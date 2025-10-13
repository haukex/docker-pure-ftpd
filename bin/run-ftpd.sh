#!/bin/bash
set -meuxo pipefail
# Init script for this pure-ftpd container that starts all necessary processes.
# This file is a part of the haukex/docker-pure-ftpd repository.
# Please see the README for author, copyright, and license info.

# set -m: Job control is enabled, as per:
# https://docs.docker.com/config/containers/multi-service_container/
# IMPORTANT: need to run container with --init option

# NOTE running rsyslogd this way appears to be better:
# https://gist.github.com/haukex/1b3bfa8686b5bed18fd52ed13d99ceb7
rsyslogd -n &

# generate the default snakeoil SSL certificates
make-ssl-cert generate-default-snakeoil --force-overwrite

/usr/local/bin/user_init.sh

# ensure the upload.log can be written to - the uploadscript, which isn't run as root,
# may not have write permissions if /srv/ftp is mounted to the Docker host
touch /srv/ftp/upload.log
chown -c pure-ftpd /srv/ftp/upload.log

# docs say it's important to start pure-ftpd before pure-uploadscript
pure-ftpd /etc/pure-ftpd/pure-ftpd.conf
# wait for the named pipe to appear before starting uploadscript
while [[ ! -e /var/run/pure-ftpd.upload.pipe ]]; do sleep 0.2; done
pure-uploadscript -B -u "$(id -u pure-ftpd)" -g "$(id -g pure-ftpd)" -r /usr/local/bin/uploadscript.sh
# note: pure-ftpd runs as root, workers and pure-uploadscript as uid=pure-ftpd gid=pure-ftpd

set +x
logger -p ftp.notice -t pure-ftpd "A log message \"Unable to find the 'ftp' account\" can be ignored."
# Readme says: "If a 'ftp' user exists and its home directory exists,
# Pure-FTPd will accept anonymous login, as 'ftp' or 'anonymous'."

if [[ -n "${DISABLE_UPLOAD_LOG:-}" ]]; then
    if [[ -z "${VALKEY_HOST:-}" ]]; then
        echo "WARNING: Upload log file and Valkey are disabled, there will be no upload logging!" >&2
    else
        echo "NOTICE: Upload log will go to Valkey, not to file." >&2
    fi
fi
if [[ -n "${DISABLE_LOG_FILE:-}" ]]; then
    if [[ -z "${VALKEY_HOST:-}" ]]; then
        echo "WARNING: Log file and Valkey are disabled, there will be no FTP server logging!" >&2
    else
        echo "NOTICE: FTP server log output will go to Valkey, not to file." >&2
    fi
fi

# everything else is in the background; put log output in foreground
tail -n+0 -F /var/log/pure-ftpd/ftpd.log
