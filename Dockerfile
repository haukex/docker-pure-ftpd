# This file is a part of the haukex/docker-pure-ftpd repository.
# Please see the README for author, copyright, and license info.
FROM buildpack-deps:trixie
# buildpack-deps is the image that e.g. the official Python images use.
# It's probably a little bigger than we need but that's still ok.
# Someday we could switch to `debian:trixie` and install only the deps we need.
LABEL maintainer="Hauke D <haukex@zero-g.net>"
LABEL description="This image must be run with the --init option, see run-ftpd.sh for more details."
LABEL org.opencontainers.image.source=https://github.com/haukex/docker-pure-ftpd

# If you want the UID and GID to align with a user on the host machine, you can do the following on the host machine (for example):
# $ sudo groupadd --gid 9001 dock-ftpd
# $ sudo useradd --home-dir / --expiredate '' --inactive -1 --gid dock-ftpd --no-create-home --no-user-group --shell /usr/sbin/nologin --uid 9001 dock-ftpd
# $ sudo adduser $USER dock-ftpd
RUN groupadd --gid 9001 pure-ftpd \
    && useradd --home-dir /srv/ftp --expiredate '' --inactive -1 --gid pure-ftpd --no-create-home \
        --no-user-group --shell /usr/sbin/nologin --uid 9001 pure-ftpd \
    && mkdir -vp /srv && mkdir -vm2775 /srv/ftp && chown -c pure-ftpd:pure-ftpd /srv/ftp \
    && mkdir -vm2775 /var/log/pure-ftpd && chown -c root:pure-ftpd /var/log/pure-ftpd

# quiet debconf
ENV DEBIAN_FRONTEND=noninteractive

# ### Download, build, and install pure-ftpd (and rsyslog; and lftp as a utility inside the container)
# The perl imklog command just comments out kernel logging support (the line `module(load="imklog")`)
# Also prepares the generation of the snakeoil SSL certs (via ssl-cert)
# redis-tools is needed for redis-cli, which uploadscript.sh optionally uses (at the time of writing, it's at version 8.0.2)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        rsyslog rsyslog-hiredis lftp ssl-cert redis-tools \
    && perl -wMstrict -i -ple 's/^(?=\s*module\s*\(\s*[^)]*\bimklog\b)/#/' /etc/rsyslog.conf \
    && rm -f /etc/ssl/private/ssl-cert-snakeoil.key \
    && rm -f /etc/ssl/certs/ssl-cert-snakeoil.pem \
    && find /etc/ssl/certs -xtype l -delete -print \
    && mkdir -v /etc/pure-ftpd \
    && ln -snvf /etc/ssl/private/ssl-cert-snakeoil.key /etc/pure-ftpd/ssl-cert.key \
    && ln -snvf /etc/ssl/certs/ssl-cert-snakeoil.pem /etc/pure-ftpd/ssl-cert.pem \
    && cd /usr/src \
    #&& git clone https://github.com/jedisct1/pure-ftpd.git pure-ftpd && cd pure-ftpd \
    #&& git checkout 30cbb915f7e811cc459559a4c2469248e40c4068 \
    # the following does the same but only fetches that one commit, should be more efficient: \
    && mkdir pure-ftpd && cd pure-ftpd \
    && git init && git remote add origin https://github.com/jedisct1/pure-ftpd.git \
    && git fetch --depth=1 origin 30cbb915f7e811cc459559a4c2469248e40c4068 && git checkout FETCH_HEAD \
    && sh autogen.sh \
    && ./configure --prefix=/usr --sysconfdir=/etc/pure-ftpd --without-inetd \
        --with-tls --with-paranoidmsg --with-boring --without-humor --without-usernames \
        --with-puredb --with-uploadscript \
    && make install-strip \
    && cd / && rm -rf /usr/src/pure-ftpd \
    && apt-get dist-clean

COPY --chmod=644 etc/pure-ftpd.conf /etc/pure-ftpd/
COPY --chmod=644 etc/rsyslog.d-ftp.conf /etc/rsyslog.d/00-ftp.conf
COPY --chmod=500 bin/userinit.sh bin/run-ftpd.sh /usr/local/bin/
COPY --chmod=555 bin/uploadscript.sh bin/logrotate.sh /usr/local/bin/

WORKDIR /srv/ftp

EXPOSE 21 30000-30009
CMD [ "/usr/local/bin/run-ftpd.sh" ]
