ARG COREDNS_VERSION=1.14.7
FROM docker.io/coredns/coredns:${COREDNS_VERSION}

LABEL maintainer="admin@sysummit.internal"
LABEL description="CoreDNS authoritative server (unified image for primary/secondary)"

# 官方镜像已是静态二进制 + scratch/minimal base
# 如需 dig/nslookup 等调试工具，取消下行注释：
# RUN apk add --no-cache bind-tools

EXPOSE 53/udp 53/tcp

ENTRYPOINT ["/coredns"]
CMD ["-conf", "/etc/coredns/Corefile"]
