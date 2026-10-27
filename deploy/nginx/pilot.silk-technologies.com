# Silk Pilot on the office nginx (ticktera, 192.168.12.102, VLAN 12 — beside the splunk and
# zammad sites). Same layout as the splunk site: port 80 is the existing http-redirect site
# (it also answers Let's Encrypt from /var/www/letsencrypt), this one is 443 only.
# Install with install-pilot.sh (needs sudo). Why each line: docs/PUBLIC_ACCESS.md.

# Sign-in, invitation and reset endpoints: at most 10 a minute per address (bursts of 10).
limit_req_zone $binary_remote_addr zone=pilot_auth:10m rate=10r/m;

map $http_upgrade $pilot_connection { default upgrade; '' close; }

server {
    listen 443 ssl;
    http2 on;
    server_name pilot.silk-technologies.com;

    ssl_certificate     /etc/letsencrypt/live/pilot.silk-technologies.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/pilot.silk-technologies.com/privkey.pem;

    server_tokens off;
    client_max_body_size 25m;          # floor plans are the largest upload

    # The robots push their video in from the office network, never from the internet.
    location ~ ^/ws/robot-(cam|h264)$ { return 403; }

    # FastAPI's API map. Pilot no longer serves it (2026-10-27); refused here as well, so an
    # older Pilot behind this proxy cannot publish it either.
    location ~ ^/(docs|redoc|openapi\.json)(/|$) { return 404; }

    location ~ ^/api/(auth/(login|setup|sso/)|invitations/|password-resets/) {
        limit_req zone=pilot_auth burst=10 nodelay;
        include snippets/pilot-proxy.conf;
    }

    location / {
        include snippets/pilot-proxy.conf;
    }
}
