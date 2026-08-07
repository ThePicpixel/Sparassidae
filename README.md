# Single-node Elastic stack

Elasticsearch + Kibana + Fluentd in containers, with TLS on every hop, secrets
held in keystores rather than environment variables, and provisioned
credentials for Terraform-managed detection rules.

```bash
chmod +x deploy.sh                       # once, after download
./deploy.sh                              # deploy with generated passwords
./deploy.sh up --password 'hunter2' --version 9.5.0 --heap 4g
./deploy.sh status
./deploy.sh creds
./deploy.sh clean
```

Everything is idempotent. Re-running `up` reuses existing certificates,
keystores and API keys; `--rotate-keys` re-issues the Terraform key.

## Layout

| Path | Committed? | What |
| --- | --- | --- |
| `deploy.sh` | yes | The whole thing |
| `docker-compose.yml` | yes | Three services |
| `fluentd/` | yes | Image + config |
| `.env` | no | Config and passwords, `0600` |
| `certs/` | no | CA and PEM leaf certs |
| `secrets/` | no | `elasticsearch.keystore`, `kibana.keystore` |
| `out/` | no | Credentials and generated Terraform files |

## What the script does

1. **Preflight** — Docker Compose v2, daemon reachable, `vm.max_map_count`.
2. **Config** — flag > existing `.env` > default. Unset passwords are generated
   as 24-char secrets, Kibana encryption keys as 48-char.
3. **PKI** — a throwaway `elasticsearch` container runs `elasticsearch-certutil`
   to issue a local CA and PEM certs for `es01` and `kibana`, with `localhost`
   and `127.0.0.1` in the SANs so host-side tools work. Add more with `--san`.
4. **Keystores** — `elasticsearch.keystore` holds `bootstrap.password`;
   `kibana.keystore` holds `elasticsearch.password` plus the three
   `xpack.*.encryptionKey` values. Both are bind-mounted as single files, so no
   secret appears in `docker-compose.yml` or in container environment.
5. **Bring-up** — `es01` first, then wait on its healthcheck.
6. **Provisioning** — sets the `kibana_system` password, creates the
   `fluentd_writer` and `dac_terraform` roles and their users, and issues the
   Terraform API key. Runs via `docker compose exec` inside `es01`, so the
   `elastic` password never hits the host process table.
7. **Outputs** — `out/credentials.txt`, `out/terraform/`, `out/fluentd/`.
8. **Kibana and Fluentd** start last, once their accounts exist.

## Security posture

Transport TLS uses `verification_mode: certificate`; HTTP TLS and Kibana's
connection to Elasticsearch use full hostname verification. Kibana serves
HTTPS to the browser with its own leaf cert. Because the CA is self-signed
you'll get a browser warning on first visit — import `certs/ca/ca.crt` into
your trust store to clear it, or terminate TLS at a proxy with a real cert
and point `SERVER_PUBLICBASEURL` at that.

The `elastic` superuser is only used by `deploy.sh` during provisioning.
Fluentd and Terraform each get a least-privilege role instead.

## Terraform / Detection-as-Code

`out/terraform/` contains a `provider.tf` skeleton and a
`secrets.auto.tfvars` (`0600`) with a working endpoint, CA path, API key and
the `terraform` user's credentials. Copy them next to your rule definitions:

```bash
cp out/terraform/*.tf out/terraform/*.tfvars ~/my-detections/
cd ~/my-detections && terraform init && terraform plan
```

Two things worth knowing. The provider needs **both** blocks: Kibana resources
such as `elasticstack_kibana_security_detection_rule` authenticate with
username and password, while the Elasticsearch block (index templates, ILM,
ingest pipelines) uses the API key. And the `kibana` block's TLS options vary
between provider releases — if `terraform init` rejects the block as written,
either trust `certs/ca/ca.crt` at the OS level or uncomment `insecure = true`.

Index templates and ILM are deliberately left unmanaged by this script, per the
design: Terraform owns them. Until you define one, Fluentd relies on the
`auto_configure` privilege and dynamic mapping.

## Fluentd

The container listens on `24224` (forward, TCP and UDP) and `9880` (HTTP), and
writes to daily `fluentd-YYYY.MM.DD` indices over TLS as the `fluentd` user.
Buffers are on-disk in a named volume and retry forever, so a restart of
Elasticsearch doesn't drop events.

```bash
# smoke test
curl -X POST -d 'json={"message":"hello"}' http://localhost:9880/test.event

# ship a container's logs
docker run --log-driver=fluentd \
  --log-opt fluentd-address=localhost:24224 \
  --log-opt tag=fluentd.myapp  myimage
```

`out/fluentd/forward-client.conf` is a ready-made config for shipping in from
another host, alongside a copy of the CA.

## Podman (openSUSE Tumbleweed and friends)

The script detects Podman automatically, including behind the `podman-docker`
shim, and adapts. Override with `--engine podman` or `--engine docker` if the
guess is wrong.

```bash
sudo zypper install podman podman-docker docker-compose
systemctl --user enable --now podman.socket
export DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"
./deploy.sh
```

Real Compose v2 over the Podman socket is the best-supported combination, so
the script prefers it when `DOCKER_HOST` is set, falling back to
`podman compose` and then `podman-compose`. The fallbacks handle
`depends_on: condition: service_healthy` poorly, but the script sequences
services and polls health itself, so it works either way.

Three things get adjusted automatically:

**Memory locking.** Rootless Podman cannot raise `RLIMIT_MEMLOCK` above your
user's hard limit, so `bootstrap.memory_lock=true` fails Elasticsearch's
bootstrap check and the node exits. When rootless is detected the script sets
`bootstrap.memory_lock=false` and writes a `compose.override.yml` clamping the
ulimit to your actual limit. It tells you it's done this. To lock memory
properly instead, either run rootful (`sudo ./deploy.sh`) or raise the limit:

```bash
sudo mkdir -p /etc/systemd/system/user@$(id -u).service.d
printf '[Service]\nLimitMEMLOCK=infinity\n' | sudo tee \
  /etc/systemd/system/user@$(id -u).service.d/memlock.conf
sudo systemctl daemon-reload && loginctl terminate-user $(id -un)
```

Disabling swap achieves the same end, which is what memory locking is for.

**SELinux.** Tumbleweed installs from snapshot 20250211 onward default to
SELinux enforcing; older installs kept AppArmor, so which you have depends on
when you installed. If `getenforce` reports `Enforcing`, bind mounts get a `,z`
relabel — without it the containers get permission denied on `certs/` and the
keystores. Named volumes are left alone, as they should be.

**Cleanup.** Rootless Podman maps container UID 1000 to a subuid on the host,
so the certificates end up owned by an ID your user can't unlink. `clean` runs
`podman unshare rm -rf` before falling back to a plain `rm`.

Two things are *not* handled for you:

- `vm.max_map_count` is a host kernel setting and needs root whichever engine
  you use. The script warns; the fix is in the warning.
- **Podman has no fluentd log driver.** `--log-driver=fluentd` is Docker-only.
  Log to journald and read it with `fluent-plugin-systemd`, or forward from
  inside the application. `podman run --log-driver=journald --log-opt tag=myapp`
  plus a `@type systemd` source is the usual route.

If your user has no subuid range (rare on openSUSE, but it happens after some
migrations), rootless containers won't start at all:

```bash
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
podman system migrate
```

## Caveats

- **Single node means a yellow cluster.** Any index with a replica stays
  unassigned. That's expected; set `number_of_replicas: 0` in your templates
  if the yellow status bothers you.
- **API keys are returned once.** The Terraform key lives in
  `out/terraform/api_key`. `clean` destroys it, and it can't be recovered —
  only re-issued.
- **`--heap` should be at most half of `--mem-limit`**, and both well under
  host RAM. The defaults assume a machine with 8 GB or more.
- **This is a single-node deployment.** It's the right shape for a lab, a
  detection-engineering sandbox or a small internal stack, but it has no
  redundancy and no snapshot repository configured.
