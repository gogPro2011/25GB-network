FROM ubuntu:24.04 AS netperf-build
ARG DEBIAN_FRONTEND=noninteractive
ARG NETPERF_REF=master
RUN apt-get update && apt-get install -y --no-install-recommends build-essential autoconf automake texinfo git ca-certificates && rm -rf /var/lib/apt/lists/*
RUN git clone https://github.com/HewlettPackard/netperf.git /src \
 && cd /src && git checkout "$NETPERF_REF" \
 && ./autogen.sh \
 && ./configure --prefix=/usr/local --enable-histogram CFLAGS="-O2 -fcommon" \
 && make -j"$(nproc)" \
 && make install DESTDIR=/out

FROM ubuntu:24.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends iperf3 sysstat ethtool iproute2 tcpdump procps iputils-ping tini && rm -rf /var/lib/apt/lists/*
COPY --from=netperf-build /out/usr/local/ /usr/local/
COPY nb-counters nb-hostinfo /usr/local/bin/
RUN chmod +x /usr/local/bin/nb-* && iperf3 --version && netperf -V && mpstat -V
ENTRYPOINT ["tini", "-s", "--"]
CMD ["sleep", "infinity"]
