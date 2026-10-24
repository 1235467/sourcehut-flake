# sourcehut-flake

Packages and a NixOS module for the **latest upstream [SourceHut](https://sourcehut.org)**
services. NixOS removed `services.sourcehut` (and the `sourcehut.*` packages) in
25.11 because the packaged versions were unmaintained; this flake builds the
current upstream tags from source instead.

The steps you have to prepare outside of the NixOS configuration (DNS,
PostgreSQL, a Redis-compatible backend, secret keys, accounts, mail, SSH
prerequisites) are documented in [PREPARATION.md](PREPARATION.md), based on
the upstream installation guides.

Currently covered services (the only ones this flake packages):

| Component | Version | Purpose |
|---|---|---|
| [git.sr.ht](https://git.sr.ht/~sircmpwn/git.sr.ht) | 0.102.8 | git hosting: web frontend, GraphQL API, SSH shell, HTTP clone, update hook |
| [meta.sr.ht](https://git.sr.ht/~sircmpwn/meta.sr.ht) | 0.88.9 | accounts, authentication, SSH/PGP keys, webhook delivery |
| [core.sr.ht](https://git.sr.ht/~sircmpwn/core.sr.ht) | 0.84.10 | shared `srht` Python modules, assets, `sr.ht-keygen` |
| [scm.sr.ht](https://git.sr.ht/~sircmpwn/scm.sr.ht) | 0.22.30 | shared VCS code used by git.sr.ht |
| [sourcehut-ssh](https://git.sr.ht/~sircmpwn/sourcehut-ssh) | 0.6.0 | unified SSH dispatcher (sshd `AuthorizedKeysCommand`) |
| [sourcehut-migrate](https://git.sr.ht/~sircmpwn/sourcehut-migrate) | 0.3.1 | database initialization and migrations |

Build-time tools that are not in nixpkgs are packaged as well:
`ariadne-codegen` 0.19.0, `gqlgen` 0.17.64 (with x/tools v0.49 so that it works
with modern Go), `dataloaden` 0.3.0.

## Quick start

```nix
{
  inputs.sourcehut.url = "github:you/sourcehut-flake"; # or git+file:///path/to/repo

  outputs = { self, nixpkgs, sourcehut, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        sourcehut.nixosModules.default
        {
          networking.domain = "example.com";

          services.nginx.enable = true;            # nginx is user-managed
          security.acme.acceptTerms = true;        # for the default TLS setup
          security.acme.defaults.email = "admin@example.com";

          services.srht = {
            enable = true;
            git.enable = true;
            meta.enable = true;

            settings = {
              "sr.ht" = {
                service-key = "…";  # sr.ht-keygen service
                network-key = "…";  # sr.ht-keygen network
                redis-host = "redis://127.0.0.1:6379";
              };
              "webhooks".private-key = "…";  # sr.ht-keygen webhook
              "meta.sr.ht".connection-string = "postgresql://meta:pw@127.0.0.1/meta.sr.ht";
              "git.sr.ht".connection-string = "postgresql://git:pw@127.0.0.1/git.sr.ht";
              "meta.sr.ht".webhooks = "redis://127.0.0.1:6379/1";
            };
          };
        }
      ];
    };
  };
}
```

See [Required settings](#required-settings) for how to generate the keys and
what the redis URLs are used for.

## Flake outputs

| Output | Description |
|---|---|
| `nixosModules.default` / `nixosModules.sourcehut` | the `services.srht` NixOS module |
| `overlays.default` | adds `pkgs.sourcehut.{srht,scmsrht,gitsrht,metasrht,sourcehut-ssh,sourcehut-migrate,ariadne-codegen,gqlgen,dataloaden}` |
| `packages.x86_64-linux.*` | the same packages, buildable with `nix build .#gitsrht` etc. |

The NixOS module does not require the overlay; it instantiates the packages
from the importing configuration's own nixpkgs.

> **Namespace:** the options live under `services.srht`, not
> `services.sourcehut`. nixpkgs keeps `services.sourcehut` as a
> "removed option" stub, and any module that re-declares it fails evaluation.

## Module options

### Top level

| Option | Type | Default | Meaning |
|---|---|---|---|
| `services.srht.enable` | bool | `false` | enable the whole stack |
| `services.srht.domain` | null or str | `null` | global domain of the instance; falls back to `networking.domain`. Used to derive `meta.<domain>` / `git.<domain>` origins |
| `services.srht.listenAddress` | str | `127.0.0.1` | address the Gunicorn web services and the Go APIs bind to |
| `services.srht.settings` | attrs (typed keys + freeform) | `{}` | rendered to `/etc/sr.ht/config.ini`; frequently used keys are typed options with docs/examples (visible via `nixos-option services.srht.settings`), any other upstream key can be set through the freeform set; see [settings](#settings-reference) |

### `services.srht.meta.*` (meta.sr.ht, required by git.sr.ht)

| Option | Type | Default | Meaning |
|---|---|---|---|
| `enable` | bool | `false` | run `meta.sr.ht` (web), `meta.sr.ht-api`, `meta.sr.ht-webhooks` (Celery worker), daily maintenance timer |
| `package` | package | this flake's `metasrht` | combined package (Python app + Go API + assets) |
| `user` / `group` | str | `meta` / `meta` | system user the services run as |
| `port` | port | `5000` | web frontend port (Gunicorn) |
| `apiPort` | port | `5100` | GraphQL API port (Go daemon) |

### `services.srht.git.*` (git.sr.ht)

| Option | Type | Default | Meaning |
|---|---|---|---|
| `enable` | bool | `false` | run `git.sr.ht` (web), `git.sr.ht-api`, periodic maintenance timer, HTTP clone endpoint |
| `package` | package | this flake's `gitsrht` | combined package |
| `user` / `group` | str | `git` / `git` | system user; also the SSH login user for git push/pull |
| `port` | port | `5001` | web frontend port |
| `apiPort` | port | `5101` | GraphQL API port |
| `repos` | path | `/var/lib/git` | on-disk repository storage (becomes the git user's home); also served over HTTP clone |
| `gitPackage` | package | `pkgs.git` | git used by the API/periodic jobs |
| `manageSshd` | bool | `true` | install `sourcehut-ssh` as sshd's `AuthorizedKeysCommand` (plus `PermitUserEnvironment SRHT_*`). Set to `false` when another module owns that setting and chain the dispatcher yourself |
| `fcgiwrap.prefork` | int | `4` | preforked fcgiwrap processes for HTTP(S) cloning |

### `services.srht.nginx.*`

| Option | Type | Default | Meaning |
|---|---|---|---|
| `enable` | bool | `true` | generate the virtual hosts described below; set to `false` to write them (or another reverse proxy) yourself |
| `virtualHost` | nginx vhost options | `{}` | merged into the virtual hosts generated for `meta.<domain>` and `git.<domain>`, typed with the nginx virtual-host options from nixpkgs (so `enableACME`, `sslCertificate`, `locations`, ... are checked), e.g. to set `enableACME = false` or provide `sslCertificate`/`sslCertificateKey` |

With `enable` (the default) the module contributes vhost rules (proxy to the
web/API ports, `/static`, HTTP clone via fcgiwrap, recommended proxy headers
per location). It never enables or otherwise configures `services.nginx`;
enable nginx yourself. The fcgiwrap socket (`/run/fcgiwrap-gitsrht.sock`) is
available even with `enable = false`, for hand-written fastcgi locations.

TLS is enabled by default in the generated vhosts (`forceSSL` and
`enableACME`), so either set `security.acme.acceptTerms` and
`security.acme.defaults.email`, or override the vhosts via
`services.srht.nginx.virtualHost`. HTTP cloning additionally requires the
internal fcgiwrap instance, which the module configures automatically.

## Settings reference

`services.srht.settings` is rendered verbatim to `/etc/sr.ht/config.ini` (the
format is the upstream `config.example.ini`; see the
[git.sr.ht](https://git.sr.ht/~sircmpwn/git.sr.ht/tree/master/item/config.example.ini)
and [meta.sr.ht](https://git.sr.ht/~sircmpwn/meta.sr.ht/tree/master/item/config.example.ini)
examples). Frequently used keys are declared as typed options with
descriptions and examples (browse them with
`nixos-option services.srht.settings`); any other upstream key can be added
through the freeform attribute set.

All keys below and everything you put in `services.srht.settings` are the
upstream `config.ini` keys verbatim; the module invents no new keys. The only
one not shown in the example files is `[sr.ht] assets`, which upstream code
(`srht/config.py`, `sourcehut-migrate`) reads with `/usr/share/sourcehut` as
its default; it is set to the combined asset directory because that path does
not exist on NixOS.

### Set automatically (override with `mkForce` or plain assignment)

| Key | Value |
|---|---|
| `"sr.ht".global-domain` | `services.srht.domain` |
| `"sr.ht".environment` | `production` |
| `"sr.ht".assets` | combined asset directory (SCSS, static files, SQL schema, migrations) |
| `"meta.sr.ht".origin` / `"git.sr.ht".origin` | `https://meta.<domain>` / `https://git.<domain>` |
| `"meta.sr.ht".api-internal-origin` / `"git.sr.ht".api-internal-origin` | `http://127.0.0.1:<apiPort>`; used by frontends and the SSH dispatcher for internal GraphQL calls (external clients keep using `origin`) |
| `"meta.sr.ht".migrate-on-upgrade`, `"git.sr.ht".migrate-on-upgrade` | `yes` (runs `sourcehut-migrate <service> -a` on boot) |
| `"git.sr.ht".repos`, `"git.sr.ht".post-update-script`, `"git.sr.ht".shell`, `"git.sr.ht".enable-dispatch` | derived from the options above (SSH dispatch, repo path, update hook) |
| `"git.sr.ht".outgoing-domain`, `"meta.sr.ht::settings".onboarding-redirect` | https URLs under the instance domain |

### Required settings

| Key | What it is | How to generate |
|---|---|---|
| `"sr.ht".service-key` | key encrypting session cookies, shared by all services on the host | `sr.ht-keygen service` (from the `srht` package, also in `nix shell .#srht`) |
| `"sr.ht".network-key` | key encrypting internal messages/service-to-service auth; must be identical across all services | `sr.ht-keygen network` |
| `"webhooks".private-key` | base64 Ed25519 key signing webhook payloads | `sr.ht-keygen webhook` |
| `"sr.ht".{site-name,site-info,site-blurb,source-url,owner-name,owner-email}` | presentational/contact settings read at import or render time without defaults; no defaults are provided on purpose | set your own values |
| `"mail".smtp-from` | sender address; must be present and a valid address because the Go APIs read it unconditionally (SMTP host itself stays optional) |
| `"meta.sr.ht::billing".enabled` | `yes`/`no`; read at startup by metasrht (use `no` unless running Stripe billing) |
| `"meta.sr.ht".connection-string` / `"git.sr.ht".connection-string` | PostgreSQL connection URL **including credentials**, e.g. `postgresql://meta:password@127.0.0.1/meta.sr.ht?sslmode=disable`. Databases and roles are not created by the module. The Go components default to `sslmode=require`, so add `?sslmode=disable` when connecting over TCP to a server without TLS (or use a Unix socket URL, e.g. `postgresql:///meta.sr.ht?user=meta&host=/run/postgresql`) | your infrastructure |
| `"sr.ht".redis-host` | Redis-compatible URL for caching/sessions, e.g. `redis://127.0.0.1:6379` (Redis, Valkey, DragonFly, `rediss://`, `unix://`, sentinel lists) | your infrastructure |
| `"meta.sr.ht".webhooks` | **Celery broker URL** for the meta.sr.ht webhook delivery worker (queue for outgoing webhook events), e.g. `redis://127.0.0.1:6379/1`. Required when `meta.enable` | your infrastructure |

Every listed key is enforced by an assertion, so a missing key fails the
build with an actionable message instead of a broken runtime service.

### Optional settings (upstream keys, used verbatim)

| Key | Purpose |
|---|---|
| `"mail".smtp-host` / `smtp-port` / `smtp-user` / `smtp-password` / `smtp-from` | outgoing mail (account verification, notifications). Without it, mail sending fails |
| `"mail".pgp-privkey` / `pgp-pubkey` / `pgp-key-id` | OpenPGP key used to sign outgoing mail; `pgp-privkey` must be a path outside the Nix store |
| `"objects".s3-upstream` / `s3-access-key` / `s3-secret-key` | S3-compatible object storage (git tag artifacts, avatars) |
| `"meta.sr.ht::settings".registration` | `yes` to allow public registration |
| `"meta.sr.ht".avatar-bucket` / `avatar-prefix` | S3 bucket for user avatars |
| `"meta.sr.ht::billing".enabled` / `stripe-*` | Stripe billing (not used by this module; enable upstream keys if needed) |
| `"git.sr.ht::api".internal-ipnet`, `"meta.sr.ht::api".internal-ipnet` | subnets allowed internal API auth (defaults to loopback) |
| `"git.sr.ht".repos-index` | zoekt code-search index path; leave unset to disable code search |

## What the module installs

For `meta.enable = true`:

- `meta.sr.ht.service` — Gunicorn (`metasrht.app:app`)
- `meta.sr.ht-api.service` — `meta.sr.ht-api` Go daemon
- `meta.sr.ht-webhooks.service` — `celery -A metasrht.webhooks worker`
- `meta.sr.ht-daily.timer` — `meta.sr.ht-daily` maintenance tasks
- `sourcehut-migrate-meta.service` — initializes the database on first boot
  (`sourcehut-migrate meta.sr.ht init`), then applies pending migrations
- `meta.sr.ht-manageuser` wrapper in the system path (runs as the `meta` user)

For `git.enable = true`:

- `git.sr.ht.service` — Gunicorn (`gitsrht.app:app`)
- `git.sr.ht-api.service` — `git.sr.ht-api` Go daemon
- `git.sr.ht-periodic.timer` — `git.sr.ht-periodic` every 20 minutes
- `sourcehut-migrate-git.service` — same migration handling as above
- `fcgiwrap-gitsrht` instance + nginx fastcgi location
  (`git.sr.ht-http-clone`) for HTTP(S) cloning
- sshd integration: `AuthorizedKeysCommand` → `sourcehut-ssh`, which
  authenticates SSH keys against meta.sr.ht and dispatches to
  `git.sr.ht-shell` / update hooks

Database migrations only run when a new package version ships new migration
files; the first boot initializes from the packaged `schema.sql`.

## Coexistence with existing services

The module is written to sit next to an existing nginx/PostgreSQL/sshd setup:

- user-visible shared options (`services.openssh.*`, user definitions) are
  only set with `mkDefault`, and `services.postgresql.*` / `services.redis.*`
  are never configured at all, so your own definitions win
- nginx is never enabled or reconfigured beyond the generated virtual hosts;
  the vhost locations and their `proxyPass` are `mkDefault` too, so existing
  definitions for the same hostnames take precedence
- multiple `AuthorizedKeysCommand` users: the module fails with an actionable
  assertion instead of silently breaking git over SSH; set
  `services.srht.git.manageSshd = false` to step aside
- PostgreSQL and Redis are never configured by this module: you provide the
  connection URLs, it only orders its units after `postgresql.target` when
  the nixpkgs PostgreSQL module is enabled

## Updating the packaged versions

Versions and hashes are pinned in `nix/packages/*.nix`. To bump:

1. change `version` (and the `rev`/`tag` for `sourcehut-migrate`) in the
   package file
2. refresh the source hash:
   `nix store prefetch-file --unpack --json <tarball-url>` (use the plain,
   non-`--unpack` hash only for PyPI sdist fetches)
3. For `gitsrht`/`metasrht` also refresh `vendorHash`: set it to
   `lib.fakeHash`, run `nix build .#gitsrht`, and copy the hash from the
   error message. The GraphQL code for the Go APIs is generated inside the
   fixed-output derivation before vendoring, so the hash covers the generated
   imports as well
4. `nix flake check` and, ideally, boot the resulting system once

Python service packages get their version from `SETUPTOOLS_SCM_PRETEND_VERSION`
set in the derivation; Go binaries embed `BuildVersion` via ldflags.
