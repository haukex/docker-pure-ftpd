#!/bin/bash
set -euxo pipefail
cd -- "$( dirname -- "${BASH_SOURCE[0]}" )"/..
# This file is a part of the haukex/docker-pure-ftpd repository.
# Please see the README for author, copyright, and license info.

# This bash script can optionally be passed an image name to use
default_image_name="pure-ftpd:latest"
image_name="${1:-$default_image_name}"

# check for required tools
if ! lftp --version >/dev/null; then
    echo "lftp not installed? (Hint: sudo apt install lftp)" >&2
    exit 1
fi
if ! valkey-cli --version >/dev/null; then
    echo "valkey-cli not installed? (Hint: sudo apt install valkey-tools)" >&2
    exit 1
fi

# Build an image for us to use (if needed)
if [[ "$image_name" == "$default_image_name" ]]; then
    docker build --progress=plain -t "$default_image_name" .
fi

# Function for cleaning up running docker containers, networks, etc. on exit
stop_commands=()  # Remember to add each started container to this array
cleanup_commands() {
    for (( idx=${#stop_commands[@]}-1 ; idx>=0 ; idx-- )); do ${stop_commands[idx]}; done
    stop_commands=()
}

# Note: The Docker documentation states that bind mounts should fail if the source doesn't exist on the host.
# However, I am experiencing different behavior: `docker run --rm -it --mount type=bind,src=/no_such_path,dst=/mnt alpine sh`
# creates a directory /no_such_path/ on my host machine. Looks like https://github.com/docker/for-win/issues/11958

# Set up temp directories for volumes
temp_dir="$( mktemp --directory )"
cleanup_tempdirs() {
    # a slightly complicated way to gain the privileges needed to clean up these files
    # (I didn't feel like requiring the user of these tests to have sudo rights, docker is enough)
    docker run \
        --mount type=bind,source="$temp_dir/ftp",target=/srv/ftp \
        --mount type=bind,source="$temp_dir/logs",target=/var/log/pure-ftpd \
        --rm "$image_name" find /srv/ftp /var/log/pure-ftpd -mindepth 1 -delete -print
}
finalize() {
    exit_code=$1
    cleanup_commands
    cleanup_tempdirs
    rm -rf "$temp_dir"
    if [[ "$exit_code" -ne 0 ]]; then echo "FAIL!"; fi
}
trap 'finalize "$?"' EXIT
trap 'finalize 256' SIGINT SIGTERM
mkdir -v "$temp_dir/ftp" "$temp_dir/logs"
echo "test_user:PASS_WORD" >"$temp_dir/ftp-passwd"

# ### Spin up a regular Pure-FTPd Docker container
ftp_id="$( docker run --name pure-ftpd-test-srv \
    --mount type=bind,source="$temp_dir/ftp-passwd",target=/run/secrets/ftp-passwd,readonly \
    --mount type=bind,source="$temp_dir/ftp",target=/srv/ftp \
    --mount type=bind,source="$temp_dir/logs",target=/var/log/pure-ftpd \
    --publish 127.0.0.1:2121:21/tcp \
    --publish 127.0.0.1:30000-30009:30000-30009/tcp \
    --rm --detach --init "$image_name" )"
stop_commands+=("docker stop $ftp_id")

tests/ftpd-tests.pl -h localhost:2121 -f "$temp_dir/ftp" -l "$temp_dir/logs" \
    -r "docker exec \"$ftp_id\" bash -c '/usr/local/bin/logrotate.sh \
    && kill -HUP \`cat /var/run/rsyslogd.pid\` && logger -p ftp.notice Rotated'"

# clean up so the next test has a fresh start
cleanup_commands
cleanup_tempdirs

# ### Spin up a regular container together with Valkey and file output disabled
docker network create pure-ftpd-test-net
stop_commands+=("docker network rm pure-ftpd-test-net")
valkey_id="$( docker run --name pure-ftpd-test-valkey \
    --publish="127.0.0.1:6379:6379/tcp" \
    --network pure-ftpd-test-net \
    --rm --detach valkey/valkey:8 )"
# Note: If you want to debug the running Valkey and see all incoming messages:
# `docker exec -it "$(docker container ls --quiet --latest --filter ancestor=valkey/valkey:8)" valkey-cli MONITOR`
stop_commands+=("docker stop $valkey_id")
ftp_id="$( docker run --name pure-ftpd-test-srv \
    --mount type=bind,source="$temp_dir/ftp-passwd",target=/run/secrets/ftp-passwd,readonly \
    --mount type=bind,source="$temp_dir/ftp",target=/srv/ftp \
    --mount type=bind,source="$temp_dir/logs",target=/var/log/pure-ftpd \
    --publish 127.0.0.1:2121:21/tcp \
    --publish 127.0.0.1:30000-30009:30000-30009/tcp \
    --network pure-ftpd-test-net \
    --env VALKEY_HOST=pure-ftpd-test-valkey \
    --env DISABLE_LOG_FILE=1 --env DISABLE_UPLOAD_LOG=1 \
    --rm --detach --init "$image_name" )"
stop_commands+=("docker stop $ftp_id")

tests/ftpd-tests.pl -h localhost:2121 -f "$temp_dir/ftp" -l "$temp_dir/logs" -L -v localhost

echo "########## ########## ########## Docker Logs ########## ########## ##########"
docker logs $ftp_id
echo "########## ########## ########## ########### ########## ########## ##########"
