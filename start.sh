#!/bin/sh
# SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

set -e

# The generated files contain secrets
umask 077

if ! grep -q " /config " /proc/mounts; then
    echo "/config is not a mountpoint!"
    exit 1
fi

require_var() {
    if [ -z "$2" ]; then
        echo "$1 must be set!"
        exit 1
    fi
}
require_var NC_DOMAIN "$NC_DOMAIN"
require_var NC_BASE_DN "$NC_BASE_DN"
require_var JWT_SECRET "$JWT_SECRET"
require_var SESSION_SECRET "$SESSION_SECRET"
require_var STORAGE_ENCRYPTION_KEY "$STORAGE_ENCRYPTION_KEY"
require_var OIDC_HMAC_SECRET "$OIDC_HMAC_SECRET"
require_var OIDC_CLIENT_SECRET "$OIDC_CLIENT_SECRET"
require_var LLDAP_PASSWORD "$LLDAP_PASSWORD"
require_var SMTP_PASSWORD "$SMTP_PASSWORD"

AUTHELIA_DOMAIN="auth.$NC_DOMAIN"

# The users are managed in lldap. Authelia fails to start if it cannot connect to it.
while ! nc -w 2 nextcloud-aio-lldap 3890 < /dev/null > /dev/null 2>&1; do
    echo "Waiting for nextcloud-aio-lldap to become available. Make sure that the lldap community container is enabled!"
    sleep 5
done

# Generate the RSA key that is used to sign the OIDC tokens only once
if ! [ -f /config/keys/private.pem ]; then
    mkdir -p /config/keys
    authelia crypto pair rsa generate --bits 4096 --directory /config/keys
fi

# Send mails via the Stalwart community container if it is enabled. Otherwise write them to a file.
if nslookup nextcloud-aio-stalwart >/dev/null 2>&1; then
    STALWART_FOUND=1
    echo "Stalwart was found. Mails will be sent as authelia@$NC_DOMAIN via Stalwart."
    NOTIFIER="  # The account authelia@$NC_DOMAIN needs to be created in Stalwart with the password that is shown in the AIO interface
  disable_startup_check: true
  smtp:
    address: 'submissions://nextcloud-aio-stalwart:465'
    username: 'authelia@$NC_DOMAIN'
    password: '$SMTP_PASSWORD'
    sender: 'Authelia <authelia@$NC_DOMAIN>'
    tls:
      server_name: 'mail.$NC_DOMAIN'"
else
    echo "Stalwart was not found. Mails will be written to /config/notification.txt."
    NOTIFIER="  filesystem:
    filename: '/config/notification.txt'"
fi

CLIENT_SECRET_HASH="$(authelia crypto hash generate pbkdf2 --variant sha512 --password "$OIDC_CLIENT_SECRET" | sed -n 's/^Digest: //p')"
JWKS_KEY="$(sed 's/^/          /' /config/keys/private.pem)"

# The configuration is regenerated on every start so that e.g. a domain change gets applied
cat << EOF > /config/configuration.yml
# This file is generated on every container start. Changes will be lost!
# Put your own changes into /config/configuration.custom.yml instead.
theme: 'auto'

server:
  address: 'tcp://:9091/'

log:
  level: 'info'

totp:
  issuer: '$NC_DOMAIN'

identity_validation:
  reset_password:
    jwt_secret: '$JWT_SECRET'

authentication_backend:
  ldap:
    implementation: 'lldap'
    address: 'ldap://nextcloud-aio-lldap:3890'
    base_dn: '$NC_BASE_DN'
    user: 'uid=admin,ou=people,$NC_BASE_DN'
    password: '$LLDAP_PASSWORD'

access_control:
  default_policy: 'two_factor'

session:
  secret: '$SESSION_SECRET'
  cookies:
    # Only Authelia's own subdomain needs the session cookie since it is only used as OIDC provider.
    # Using $NC_DOMAIN would send the cookie to all other subdomains (e.g. of other community containers), too.
    - domain: '$AUTHELIA_DOMAIN'
      authelia_url: 'https://$AUTHELIA_DOMAIN'

regulation:
  max_retries: 5
  find_time: '2m'
  ban_time: '10m'

storage:
  encryption_key: '$STORAGE_ENCRYPTION_KEY'
  local:
    path: '/config/db.sqlite3'

notifier:
$NOTIFIER

identity_providers:
  oidc:
    hmac_secret: '$OIDC_HMAC_SECRET'
    jwks:
      - key_id: 'nextcloud-aio'
        algorithm: 'RS256'
        use: 'sig'
        key: |
$JWKS_KEY
    claims_policies:
      nextcloud:
        id_token:
          - 'email'
          - 'email_verified'
          - 'name'
          - 'preferred_username'
          - 'groups'
    clients:
      - client_id: 'nextcloud'
        client_name: 'Nextcloud'
        client_secret: '$CLIENT_SECRET_HASH'
        public: false
        # Users that did not set up a second factor yet get asked to do so on their first login
        authorization_policy: 'two_factor'
        claims_policy: 'nextcloud'
        # Nextcloud is the first-party app of this instance, so asking for consent makes no sense
        consent_mode: 'implicit'
        require_pkce: true
        pkce_challenge_method: 'S256'
        redirect_uris:
          - 'https://$NC_DOMAIN/apps/user_oidc/code'
        scopes:
          - 'openid'
          - 'profile'
          - 'email'
          - 'groups'
        response_types:
          - 'code'
        grant_types:
          - 'authorization_code'
        access_token_signed_response_alg: 'none'
        userinfo_signed_response_alg: 'none'
        token_endpoint_auth_method: 'client_secret_post'
EOF

set -- --config /config/configuration.yml
if [ -f /config/configuration.custom.yml ]; then
    set -- "$@" --config /config/configuration.custom.yml
fi

# Do not leak the secrets into the Authelia process
unset JWT_SECRET SESSION_SECRET STORAGE_ENCRYPTION_KEY OIDC_HMAC_SECRET OIDC_CLIENT_SECRET LLDAP_PASSWORD SMTP_PASSWORD CLIENT_SECRET_HASH JWKS_KEY NOTIFIER

# The upstream entrypoint fixes the permissions of /config and drops privileges to PUID:PGID
/app/entrypoint.sh "$@" &
AUTHELIA_PID=$!

stop_authelia() {
    kill -TERM "$AUTHELIA_PID" 2>/dev/null || true
    wait "$AUTHELIA_PID" || true
}
trap 'stop_authelia; exit 0' TERM INT

# AIO does not guarantee that Stalwart is started before this container.
# So if it shows up later, exit so that docker restarts the container and the mail configuration gets regenerated.
if [ "$STALWART_FOUND" != 1 ]; then
    while kill -0 "$AUTHELIA_PID" 2>/dev/null; do
        if nslookup nextcloud-aio-stalwart >/dev/null 2>&1; then
            echo "Stalwart became available. Restarting in order to send mails via Stalwart..."
            stop_authelia
            exit 1
        fi
        sleep 10 &
        wait $!
    done
fi

wait "$AUTHELIA_PID"
