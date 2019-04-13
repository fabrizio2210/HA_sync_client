FROM debian
MAINTAINER fabrizio2210

RUN apt-get update && apt-get install -y csync2 lsyncd sed wget procps && apt-get clean

RUN wget https://github.com/jpillora/chisel/releases/download/1.2.4/chisel_linux_amd64.gz && \
    gunzip chisel_linux_amd64.gz && \
    mv chisel_linux_amd64 /usr/local/bin/chisel && \
    chmod +x /usr/local/bin/chisel


COPY src/* /usr/local/bin/

VOLUME ["/etc", "/var/lib/csync2"]
EXPOSE 80/tcp

CMD /usr/local/bin/wrapper.sh
