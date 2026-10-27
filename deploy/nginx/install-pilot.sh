#!/bin/bash
# Publish Silk Pilot at https://pilot.silk-technologies.com on this nginx (ticktera).
# Run from this folder as an admin:  sudo bash install-pilot.sh
# Touches nothing of the splunk or zammad sites; stops before reloading if nginx -t fails.
set -euo pipefail
cd "$(dirname "$0")"
DOMAIN=pilot.silk-technologies.com

# 1. The certificate first (the site below points at it). Port 80 is the http-redirect site,
#    which serves /.well-known/acme-challenge/ from /var/www/letsencrypt.
if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    certbot certonly --webroot -w /var/www/letsencrypt -d "$DOMAIN" \
        --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring
fi

# 2. The site and its proxy snippet.
install -m 644 pilot-proxy.conf /etc/nginx/snippets/pilot-proxy.conf
install -m 644 "$DOMAIN" "/etc/nginx/sites-available/$DOMAIN"
ln -sfn "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"

# 3. Check, then reload (on a failed check, take the site out again and stop).
if ! nginx -t; then
    rm -f "/etc/nginx/sites-enabled/$DOMAIN"
    echo "nginx -t failed: Pilot's site was removed again, nothing reloaded." >&2
    exit 1
fi
systemctl reload nginx
# Renewals: certbot's timer renews every certificate, and this host already reloads nginx after
# each one (/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh, set up for splunk).
echo "Done: https://$DOMAIN"
