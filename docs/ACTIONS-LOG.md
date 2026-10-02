# Installation action log

This file records the reproducible actions taken to create the environment.
Generated credentials are intentionally recorded only in the gitignored
`secrets/credentials.md`.

1. Confirmed Docker 29.7.2, Docker Compose 5.5.1, OpenSSL 3.6.4, curl, jq, and
   Python were present.
2. Confirmed host capacity: 32 GB RAM, 24 CPUs, and approximately 1.8 TB free.
3. Confirmed ports 80, 443, and 2222 were unused.
4. Confirmed `vm.max_map_count=1048576`, sufficient for SonarQube.
5. Selected the requested Compose architecture with ChartMuseum at `helm.dev`.
6. Created separated configuration, data, certificate, secret, chart, and backup
   paths; Compose services; TLS routing; bootstrap/verification/backup scripts;
   and installation/migration documentation.
7. Generated strong credentials, a local CA, a SAN server certificate, and the
   Forgejo administrator SSH key with `scripts/install.sh`.
8. Local DNS resolution was not active on this host at installation time; scripts
   therefore use curl host overrides and containers use network aliases. Browser
   access still requires the records described in `docs/INSTALL.md`.
9. The documented ChartMuseum `v0.16.3` tag was unavailable in Docker Hub; the
   published `latest` tag was used and its pulled content is validated during
   startup.
10. Docker Engine 29 rejected Traefik 3.5's Docker API 1.24. Replaced Docker
    provider discovery with explicit file-based routes, removed the proxy's
    Docker socket access, and made local health probes bypass host proxy settings.
11. Created the Forgejo administrator, uploaded its SSH public key, and registered
    the site-wide `local-docker-runner`. Tightened SonarQube readiness to require
    API status `UP` instead of merely accepting an HTTP-successful `STARTING`.
12. SonarQube rejected hexadecimal-only admin passwords because they lack
    uppercase characters. Updated password generation to guarantee uppercase,
    lowercase, numeric, and symbol characters. Corrected runner registration to
    persist its state in `config/runner/.runner`.
13. Added the host Docker socket GID to the rootless runner. Rancher's embedded
    k3s first retained a stale node IP, then exposed that an empty `/etc/rancher`
    bind mount hid internal trust material. Preserved both failed initial states,
    removed the incorrect mount, and initialized clean state on the stable
    Compose network. Rancher's configuration remains in its separated
    `data/rancher` tree because the image couples it to embedded-k3s state.
14. Installed the local CA trust anchor and static host records through `pkexec`.
    Moved NSS `files` lookup ahead of `mdns_minimal` (with a timestamped
    `/etc/nsswitch.conf` backup) because `.dev` mDNS negative results otherwise
    prevented applications from consulting `/etc/hosts`.
15. Completed idempotent bootstrap and verified Forgejo, the Actions runner,
   SonarQube, Rancher, ChartMuseum, hostname resolution, system CA trust, and
   the server certificate. All services are running.
16. Exercised backup/recovery tooling. Updated backup to pause services and
   archive root-owned Rancher state through a container while leaving the
   backup user-owned, then verified service restart and endpoints.
17. Initialized local Git history containing only reproducible infrastructure,
18. `https://rancher.dev` returned 502 because `rancher/rancher:latest` resets
    embedded k3s on every start when `server/db/etcd` exists. k3s exits and asks
    to restart without `--cluster-reset`, so the container never listens on port
    80. Mounted `config/rancher/entrypoint.sh`, which resets only when
    `server/db/reset-flag` is present, and removed the leftover flag. After that,
    k3s still rejected ports 80 and 443 because a stuck `kube-system/traefik`
    LoadBalancer had no endpoints. Removed its load-balancer finalizer so the
    service could finish deleting. Pinned Rancher to `172.18.0.2` so a recreate
    does not revive the stale node-IP failure.
   scripts, templates, and documentation. Runtime data, credentials, keys,
   certificates, runner registration, and backups remain ignored.
18. Installed the host Helm CLI from the Arch repository (`v4.2.2`) through
   `pkexec`. The private repository command is documented but was not persisted,
   avoiding plaintext ChartMuseum credentials in Helm client configuration.
