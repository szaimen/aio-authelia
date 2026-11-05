FROM authelia/authelia:4.39.28

# Run Authelia itself as nobody. The upstream entrypoint chowns /config and drops privileges.
ENV PUID=65534 \
    PGID=65534

COPY --chmod=775 start.sh /start.sh

VOLUME /config

ENTRYPOINT [ "/start.sh" ]

# Needed for Nextcloud AIO so that image cleanup can work.
# Unfortunately, this needs to be set in the Dockerfile in order to work.
LABEL org.label-schema.vendor="Nextcloud"
