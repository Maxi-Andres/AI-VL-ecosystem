# Publishing Pilot on the internet

How `https://pilot.silk-technologies.com` reaches the Pilot server, and what keeps it safe.
Written 2026-10-27, when the company decided Pilot must be reachable from the internet with
Microsoft sign-in, the same way Splunk already is.

```
browser ──https──▶ 201.216.197.132 (office nginx, real certificate)
                         │  only pilot.silk-technologies.com, robot ingest refused
                         ▼
                   https://192.168.20.99:8443  (Pilot: backend + app, its own certificate)
```

Pilot moves robots. Everything below is about letting people in from anywhere **without**
letting anyone else in.

## 1. DNS — done

GoDaddy (the domain's DNS, `ns63/ns64.domaincontrol.com`): an `A` record `pilot` →
`201.216.197.132`, TTL 600 — the same address as `splunk`. Created 2026-10-27.

## 2. The office nginx (whoever administers 201.216.197.132)

The same machine that publishes `splunk.silk-technologies.com`. Add one site and get its
certificate:

```nginx
# /etc/nginx/sites-available/pilot.silk-technologies.com  (then ln -s into sites-enabled)

# Sign-in, invitation and reset endpoints: at most 10 a minute per address (bursts of 10).
limit_req_zone $binary_remote_addr zone=pilot_auth:10m rate=10r/m;

map $http_upgrade $pilot_connection { default upgrade; '' close; }

server {
    listen 80;
    server_name pilot.silk-technologies.com;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name pilot.silk-technologies.com;
    # ssl_certificate / ssl_certificate_key: written here by certbot (below).

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
```

```nginx
# /etc/nginx/snippets/pilot-proxy.conf
proxy_pass https://192.168.20.99:8443;
proxy_ssl_verify off;                  # Pilot's own certificate, inside the office network
proxy_http_version 1.1;
proxy_set_header Host $host;           # Pilot checks the Origin against this (CSRF guard)
proxy_set_header X-Forwarded-For $remote_addr;   # overwrite: never pass on what the caller sent
proxy_set_header X-Forwarded-Proto https;
proxy_set_header Upgrade $http_upgrade;          # video, detection and joints are WebSockets
proxy_set_header Connection $pilot_connection;
proxy_read_timeout 3600s;              # a WebSocket stays open while someone watches
proxy_send_timeout 3600s;
proxy_buffering off;                   # the vision assistant streams its answers
```

Then:

```bash
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d pilot.silk-technologies.com   # Let's Encrypt, renews by itself
```

## 3. Pilot (on 192.168.20.99)

1. **Tell Pilot which address is the nginx**, or it cannot tell the internet from the office:
   in `~/.pilot/pilot.env` (read by `linux/run.sh`; create it):

   ```bash
   TRUSTED_PROXIES=<the nginx's address as Pilot sees it>
   ```

   To find that address, open `https://pilot.silk-technologies.com` once and read the
   `[backend]` log: the client address on that request is the nginx. Restart Pilot after.
   Until this is set, Pilot fails closed: a request that arrives through a proxy it was not
   told to trust counts as coming from the internet.
2. **Set the public address**: Settings → Team & roles → Invite member → "Invitation links point
   to" → type `https://pilot.silk-technologies.com` → Use. Invitation links, reset links and the
   single sign-on redirect are built on it.
3. **Single sign-on**: Settings → Single sign-on (see section 4).

## 4. Microsoft sign-in (whoever administers the Entra tenant)

Microsoft Entra admin center → App registrations → New registration: any name ("Silk Pilot"),
single tenant, redirect URI platform **Web**:
`https://pilot.silk-technologies.com/api/auth/sso/callback` (Pilot shows the exact value with a
copy button). Then give Pilot the Directory (tenant) ID, the Application (client) ID and a client
secret's Value. The secret expires: put the new one in Pilot before it does. A second factor for
everyone signing in is set in Entra (Conditional Access / security defaults), not in Pilot.

## What protects it

| Layer | What |
|---|---|
| Every API and WebSocket | Refused without a session or a device key (`auth.POLICY`, default deny). `tests/test_auth.py` calls every route with no credential and requires a 401 except the sign-in ones, and fails if anything is served outside the check — `/docs` and `/openapi.json` were, until 2026-10-27. |
| Who gets in | Only invited people. Microsoft proves who they are; it never decides that they belong. |
| Passwords | With single sign-on on, a password works only from the office network, VPN or Tailscale (Settings → Single sign-on → "Allow passwords from the internet", off by default) — so from the internet everyone goes through Microsoft and its second factor. The password stays as the way in from the office when Microsoft is down. |
| Guessing | Sign-in attempts throttled per address and per account in Pilot; per address again in nginx. |
| The browser | CSP (scripts from Pilot only), no framing, HSTS, nosniff, same-origin referrer; session cookie httpOnly + SameSite=Strict + Secure; the Origin of every cookie write is checked. |
| Robots | Their video comes in only from the office (nginx refuses `/ws/robot-*`); every command still goes through the robot's own limits (the executor's clamp and dead-man switch). |

## Not covered — decide before relying on it

- **iacore (:8001), the executor (:8090), the camera bridge (:8091) and mediamtx** have no
  credential of their own. They must never be published: only Pilot's port goes through nginx.
  Anyone already inside the office network can still reach them (ROADMAP PLATAFORMA §7.1).
- **The H.264 (WebRTC) video** goes from mediamtx straight to the browser and has no STUN/TURN:
  from the internet, use MJPEG (the default), which goes through Pilot.
