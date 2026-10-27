# Silk Pilot on the office nginx (192.168.12.102, VLAN 12 — the one that also publishes
# splunk.silk-technologies.com and soporte.silk-technologies.com). Why each line: see
# docs/PUBLIC_ACCESS.md.
#
#   sudo cp pilot.silk-technologies.com /etc/nginx/sites-available/
#   sudo cp pilot-proxy.conf /etc/nginx/snippets/
#   sudo ln -s /etc/nginx/sites-available/pilot.silk-technologies.com /etc/nginx/sites-enabled/
#   sudo nginx -t && sudo systemctl reload nginx
#   sudo certbot --nginx --redirect -d pilot.silk-technologies.com

# Sign-in, invitation and reset endpoints: at most 10 a minute per address (bursts of 10).
limit_req_zone $binary_remote_addr zone=pilot_auth:10m rate=10r/m;

map $http_upgrade $pilot_connection { default upgrade; '' close; }

server {
    # One block on port 80: `certbot --nginx --redirect` moves it to 443 with the certificate and
    # adds the http -> https redirect, the same way it did for splunk.
    listen 80;
    server_name pilot.silk-technologies.com;

    server_tokens off;
    client_max_body_size 25m;          # floor plans are the largest upload

    # The robots push their video in from the office network, never from the internet.
    location ~ ^/ws/robot-(cam|h264)$ { return 403; }

    location ~ ^/api/(auth/(login|setup|sso/)|invitations/|password-resets/) {
        limit_req zone=pilot_auth burst=10 nodelay;
        include snippets/pilot-proxy.conf;
    }

    location / {
        include snippets/pilot-proxy.conf;
    }
}
