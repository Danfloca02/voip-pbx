# syntax=docker/dockerfile:1
FROM debian:12-slim

# Create a non-privileged user that the app will run under.
# See https://docs.docker.com/go/dockerfile-user-best-practices/
ARG ASTERISK_VERSION=22

# Instalacion de dependencias para Asterisk
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git wget curl ca-certificates \
    libsrtp2-dev \
    libssl-dev libncurses5-dev libjansson-dev libsqlite3-dev \
    libedit-dev uuid-dev libxml2-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src
RUN git clone -b ${ASTERISK_VERSION} --single-branch --depth 1 \
    https://github.com/asterisk/asterisk.git

WORKDIR /usr/src/asterisk
RUN apt-get update && \
    contrib/scripts/install_prereq install

RUN ./configure && \
    make menuselect.makeopts && \
    menuselect/menuselect \
      --enable chan_pjsip --enable res_pjsip \
      --enable res_srtp menuselect.makeopts && \
    make -j"$(nproc)" && \
    make install && \
    make samples && \
    make config

# 5. Launch Asterisk in foreground
ENTRYPOINT ["asterisk", "-f", "-vvvc"]