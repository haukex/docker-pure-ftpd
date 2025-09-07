Docker Image of Pure-FTPd
=========================

This repository defines a Docker image that runs a simple
[`pure-ftpd`](https://github.com/jedisct1/pure-ftpd) FTPS server.

FTP users are configured by providing a text file as the Docker secret
`ftp-passwd` that is a list of `USERNAME:PASSWORD` pairs, one per line.

FTP data is in `/srv/ftp`, which you can mount.
An upload log is written to `/srv/ftp/upload.log`, unless you set
the environment variable `DISABLE_UPLOAD_LOG` (note this file
is `flock`ed when it's being written).

Logs are written to `/var/log/pure-ftpd` and to the container's STDOUT,
unless you set the environment variable `DISABLE_LOG_FILE`.

Real SSL certificates can be configured by pointing the symlinks
`/etc/pure-ftpd/ssl-cert.key -> /etc/ssl/private/ssl-cert-snakeoil.key` and
`/etc/pure-ftpd/ssl-cert.pem -> /etc/ssl/certs/ssl-cert-snakeoil.pem`
in the image at the desired SSL certificates.

If the environment variable `VALKEY_HOST` is set, then log messages are
sent to the stream `pure-ftpd.log` and upload messages to `pure-ftpd.uploads`.
The Valkey host not being available is (currently) not a fatal error.
**Note** these streams are not cleaned up by this container, so you'll need to,
for example, do a regular `XTRIM` on them.

To run a quick test of this server:

    docker build . -t 'pure-ftpd:latest' && docker system prune -f
    echo "test_user:PASS_WORD" >/tmp/dummy-ftp-passwd
    docker run --rm --mount type=bind,source=/tmp/dummy-ftp-passwd,target=/run/secrets/ftp-passwd,readonly \
        --publish "127.0.0.1:2121:21" --publish "127.0.0.1:30000-30009:30000-30009" --init pure-ftpd:latest
    lftp -e 'set ssl:verify-certificate no' -u test_user,PASS_WORD localhost:2121

To do a quick test of the Valkey integration:

- `docker run --publish="127.0.0.1:6379:6379" --rm valkey/valkey:8`
- If you want to debug the running Valkey and see all incoming messages:
  `docker exec -it "$(docker container ls --quiet --latest --filter ancestor=valkey/valkey:8)" valkey-cli MONITOR`
- Then, add `--add-host=host.docker.internal:host-gateway --env VALKEY_HOST=host.docker.internal`
  to the above `docker run`.

To run the test suite on locally spawned Docker containers, use `tests/run-local-tests.sh`.
The script `tests/ftp-tests.pl` can also be used on a deployed server.
`lftp` and `valkey-cli` are required for the tests.


Author, Copyright, and License
------------------------------

Copyright © 2025 Hauke Dämpfling (haukex@zero-g.net)
at the Leibniz Institute of Freshwater Ecology and Inland Fisheries (IGB),
Berlin, Germany, <https://www.igb-berlin.de/>

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THIS SOFTWARE.

Pure-FTPd, which is *not* distributed as part of this source repository, is
Copyright (c) 2001 - 2025 Frank Denis <j at pureftpd dot org> with help of contributors,
and is covered by the same license terms. It is available at
<https://github.com/jedisct1/> and <https://www.pureftpd.org/>.
