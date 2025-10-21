#!/bin/bash
set -meuo pipefail
# Init script for this pure-ftpd container that starts all necessary processes.
# This file is a part of the haukex/docker-pure-ftpd repository.
# Please see the README for author, copyright, and license info.

# set -m: Job control is enabled, as per:
# https://docs.docker.com/config/containers/multi-service_container/
# IMPORTANT: need to run container with --init option

echo "### Booting Pure-FTPd container..."

if [[ -n "${VALKEY_HOST:-}" ]]; then
    # wait for valkey to be up
    echo "Waiting for Valkey..."
    retry_count=0
    while ! valkey-cli -h "$VALKEY_HOST" --raw PING >/dev/null 2>&1; do
        sleep 0.2
        if (( ++retry_count > 100 )); then
            echo "Valkey is still not up, aborting!"
            exit 1
        fi
    done
    echo "Valkey ready"
fi
set -x

# NOTE running rsyslogd this way appears to be better:
# https://gist.github.com/haukex/1b3bfa8686b5bed18fd52ed13d99ceb7
rsyslogd -n &

# generate the default snakeoil SSL certificates
make-ssl-cert generate-default-snakeoil --force-overwrite

# Although the directories are set up in the Dockerfile, they might have been mounted
chmod -c a+rx,u+w,o-w /srv
chmod -c 2775 /srv/ftp
chown -c pure-ftpd:pure-ftpd /srv/ftp

chmod -c a+rx,u+w,o-w /var/log
chmod -c 2775 /var/log/pure-ftpd
chown -c root:pure-ftpd /var/log/pure-ftpd

touch /srv/ftp/upload.log
chown -c pure-ftpd:pure-ftpd /srv/ftp/upload.log

/usr/local/bin/user-init.sh

# docs say it's important to start pure-ftpd before pure-uploadscript
pure-ftpd /etc/pure-ftpd/pure-ftpd.conf
# wait for the named pipe to appear before starting uploadscript
set +x
echo "Waiting for pure-ftpd.upload.pipe..."
retry_count=0
while [[ ! -e /var/run/pure-ftpd.upload.pipe ]]; do
    sleep 0.2
    if (( ++retry_count > 100 )); then
        echo "pure-ftpd.upload.pipe still doesn't exist, aborting!"
        exit 1
    fi
done
echo "pure-ftpd.upload.pipe ready"
set -x
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
