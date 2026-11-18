# syntax=docker/dockerfile:1.7

# nginx-docker-distroless
#
# 公式 nginx (Debian trixie) から実行に必要なものだけを集め、
# gcr.io/distroless/base-debian13 に載せる。shell と package manager は含まない。
#
# master は root (80 番 bind と pid のため)、worker は nginx (uid 101)。
# ベースはタグで追従する。nightly が日次で最新を拾う。

ARG NGINX_IMAGE=nginx:stable-trixie
ARG DISTROLESS_IMAGE=gcr.io/distroless/base-debian13:latest

FROM ${NGINX_IMAGE} AS upstream

RUN set -eux; \
    mkdir -p /rootfs/usr/sbin /rootfs/usr/lib /rootfs/usr/share /rootfs/etc /rootfs/run /rootfs/var/run; \
    cp -a /usr/sbin/nginx /rootfs/usr/sbin/; \
    if [ -d /usr/lib/nginx ]; then cp -a /usr/lib/nginx /rootfs/usr/lib/; fi; \
    if [ -d /usr/share/nginx ]; then cp -a /usr/share/nginx /rootfs/usr/share/; fi; \
    cp -a /etc/nginx /rootfs/etc/; \
    mkdir -p /var/cache/nginx /var/log/nginx /var/lib/nginx; \
    { \
      ldd /usr/sbin/nginx 2>/dev/null || true; \
      for f in /usr/lib/nginx/modules/*.so; do \
        [ -e "$f" ] && ldd "$f" 2>/dev/null || true; \
      done; \
      find /usr/lib -name 'libnss_*.so*' -exec ldd {} + 2>/dev/null || true; \
    } | awk '/=>/ {print $3} /^\// {print $1}' | sort -u | while read -r lib; do \
      case "$lib" in \
        */ld-linux*|*/ld64.so*) continue ;; \
        /lib/*) dest="/rootfs/usr${lib}" ;; \
        /lib64/*) dest="/rootfs/usr${lib}" ;; \
        *) dest="/rootfs${lib}" ;; \
      esac; \
      [ -e "$lib" ] || continue; \
      mkdir -p "$(dirname "$dest")"; \
      cp -aL "$lib" "$dest"; \
    done; \
    find /usr/lib -name 'libnss_*.so*' -print0 | while IFS= read -r -d '' f; do \
      dest="/rootfs$f"; \
      mkdir -p "$(dirname "$dest")"; \
      cp -aL "$f" "$dest"; \
    done

FROM ${DISTROLESS_IMAGE}

ARG NGINX_IMAGE
ARG DISTROLESS_IMAGE

LABEL org.opencontainers.image.title="nginx-distroless" \
      org.opencontainers.image.description="nginx on gcr.io/distroless/base-debian13 with the official image's config compatibility" \
      org.opencontainers.image.base.name="${DISTROLESS_IMAGE}" \
      org.opencontainers.image.version="${NGINX_IMAGE}"

COPY rootfs/etc/passwd        /etc/passwd
COPY rootfs/etc/group         /etc/group
COPY rootfs/etc/nsswitch.conf /etc/nsswitch.conf
COPY --from=upstream /rootfs/ /

# nginx が書き込むディレクトリだけ nginx (101:101) 所有にする。
COPY --from=upstream --chown=101:101 /var/cache/nginx /var/cache/nginx
COPY --from=upstream --chown=101:101 /var/log/nginx   /var/log/nginx
COPY --from=upstream --chown=101:101 /var/lib/nginx   /var/lib/nginx

ENV PATH=/usr/sbin:/usr/bin:/sbin:/bin
STOPSIGNAL SIGQUIT
EXPOSE 80
USER 0:0
CMD ["nginx", "-g", "daemon off;"]
