FROM alpine:3.20
RUN apk add --no-cache bash jq coreutils
COPY run.sh /run.sh
COPY rootfs/ /rootfs/
RUN chmod +x /run.sh
CMD ["/run.sh"]
