# Preparation

The NixOS module automates the mechanical parts of a SourceHut deployment:
it renders `/etc/sr.ht/config.ini`, creates the `git`/`meta` users, runs the
web/API/webhook/periodic units, initializes and migrates the databases, wires
`sourcehut-ssh` into sshd, and contributes nginx virtual-host rules. Everything
below is **not** managed by the module and must be prepared by you, following
the upstream documentation ([general](https://man.sr.ht/installation.md),
[meta.sr.ht](https://man.sr.ht/meta.sr.ht/installation.md),
[git.sr.ht](https://man.sr.ht/git.sr.ht/installation.md)).

## 1. DNS and TLS

Create `A`/`AAAA` records for `meta.<domain>` and `git.<domain>` (the generated
virtual hosts and the default ones derive from `services.srht.domain`).

The generated vhosts default to `forceSSL` + `enableACME`, so either set:

```nix
security.acme.acceptTerms = true;
security.acme.defaults.email = "admin@example.com";
```

or override with your own certificates via
`services.srht.nginx.virtualHost = { sslCertificate = …; sslCertificateKey = …; }`.

## 2. PostgreSQL

Upstream requires, per service, "a PostgreSQL database and a user with
ownership and all necessary permissions that apply to its database". The
databases are `meta.sr.ht` and `git.sr.ht`; the users are `meta` and `git`.

### NixOS-managed PostgreSQL

```nix
services.postgresql = {
  enable = true;
  ensureDatabases = [ "meta.sr.ht" "git.sr.ht" ];
  ensureUsers = [
    { name = "meta"; ensureDBOwnership = false; }
    { name = "git"; ensureDBOwnership = false; }
  ];
};

# Database names contain dots, so NixOS' `ensureDBOwnership` cannot be used;
# grant ownership explicitly after the databases have been created.
systemd.services.postgresql-setup.postStart = ''
  psql -tAc 'ALTER DATABASE "meta.sr.ht" OWNER TO "meta";'
  psql -tAc 'ALTER DATABASE "git.sr.ht" OWNER TO "git";'
'';
```

With the default peer authentication, connection strings use the Unix socket
and need no password:

```nix
services.srht.settings = {
  "meta.sr.ht".connection-string = "postgresql:///meta.sr.ht?user=meta&host=/run/postgresql";
  "git.sr.ht".connection-string = "postgresql:///git.sr.ht?user=git&host=/run/postgresql";
};
```

### External PostgreSQL

```sql
CREATE ROLE meta LOGIN PASSWORD '…';
CREATE DATABASE "meta.sr.ht" OWNER meta;
CREATE ROLE git LOGIN PASSWORD '…';
CREATE DATABASE "git.sr.ht" OWNER git;
```

then point the module at it, e.g.
`"meta.sr.ht".connection-string = "postgresql://meta:…@db.example.com/meta.sr.ht?sslmode=disable"`.
Being the database owner is sufficient on PostgreSQL 15+ (the owner owns the
`public` schema).

Note on TLS: the Python services use libpq semantics (`sslmode` defaults to
`prefer`), but the Go components (`git.sr.ht-api`, `meta.sr.ht-api`,
`git.sr.ht-http-clone`) use `lib/pq`, which defaults to `sslmode=require`. When
connecting over TCP to a PostgreSQL server without TLS you must therefore add
`?sslmode=disable` to the connection string (or use a Unix socket host such as
`host=/run/postgresql`, where SSL is not attempted).

### Migrations

The module initializes a fresh database from the packaged `schema.sql`
(`sourcehut-migrate <service> init`) and stamps the migration state, then
applies pending migrations on boot when `migrate-on-upgrade=yes` (the default).
Manually: `nix shell .#sourcehut-migrate -c sourcehut-migrate meta.sr.ht -a`.

Upstream recommends subscribing to the
[sr.ht-admins](https://lists.sr.ht/~sircmpwn/sr.ht-admins) mailing list for
upgrades that require manual intervention.

## 3. Redis-compatible backend

Upstream: "A Redis-compatible key/value store. We use [Redict](https://redict.io/)
in production." Anything speaking the Redis protocol works (Redis, Valkey,
DragonFly, a remote instance, ...). Two settings use it:

| Setting | Used for |
|---|---|
| `settings."sr.ht".redis-host` | caching and sessions (upstream example uses database `0`) |
| `settings."meta.sr.ht".webhooks` | Celery broker for outgoing webhook deliveries (give it its own database, upstream example uses `1`) |

Accepted URL forms: `redis://host:port/db`, `rediss://…` for TLS, passwords as
`redis://:password@host:port/db`; `redis-host` also accepts `unix://` sockets
and comma-separated `redis+sentinel://` lists. Use a `redis://`/`rediss://`
URL for the webhooks broker: the same string is parsed by the web process for
queue metrics with a parser that does not understand Celery's `redis+socket://`
scheme.

A minimal local instance with the NixOS Redis module:

```nix
services.redis.servers.sourcehut = {
  enable = true;
  bind = "127.0.0.1";
  port = 6380;
};

services.srht.settings = {
  "sr.ht".redis-host = "redis://127.0.0.1:6380/0";
  "meta.sr.ht".webhooks = "redis://127.0.0.1:6380/1";
};
```

The module asserts that both settings are present, so a missing backend fails
the build instead of half-starting services.

## 4. Secret keys

Generate the three keys with `sr.ht-keygen` (shipped in the `srht` package):

```console
$ nix shell .#srht -c sr.ht-keygen service   # -> settings."sr.ht".service-key
$ nix shell .#srht -c sr.ht-keygen network   # -> settings."sr.ht".network-key
$ nix shell .#srht -c sr.ht-keygen webhook   # -> settings."webhooks".private-key
```

Properties (from the upstream `config.example.ini` comments):

| Key | Purpose | Consistency requirement |
|---|---|---|
| `service-key` | encrypts session cookies | must be shared between all nodes of the same service; on a single host it may be shared by all services |
| `network-key` | encrypts internal messages; also used by `sourcehut-ssh` to talk to the meta.sr.ht API | must be identical on **all** services and nodes |
| `webhooks.private-key` | base64-encoded Ed25519 key signing webhook payloads | should be identical across all your `*.sr.ht` sites; the public key is distributed to webhook consumers |

Handling notes:

- the keys are stored in plain text in your Nix configuration (and therefore
  in the Nix store and `/etc/sr.ht/config.ini`); keep the repository private
- back the keys up: changing `service-key` logs everybody out, changing
  `network-key` breaks service-to-service authentication
- all three are enforced by assertions with the generation commands in the
  error message

## 5. Accounts

Public registration is off by default (upstream
`[meta.sr.ht::settings] registration=no`). Create the first administrator from
a root shell:

```console
# meta.sr.ht-manageuser -t ADMIN -e you@example.com you
```

The module installs a wrapper for this command that runs it as the `meta`
user with the configuration loaded (see `man.sr.ht/meta.sr.ht/installation.md`).

OAuth clients are only needed for third-party tools (e.g. `hut`); create them
in the meta.sr.ht web interface. First-party services authenticate internally
with the `network-key` and need no registration.

## 6. Mail (optional)

Without `[mail]` SMTP settings, outgoing mail (confirmations, notifications)
fails, but the services run. Fill in `settings."mail".smtp-host` /
`smtp-port` / `smtp-user` / `smtp-password` / `smtp-from` (and
`smtp-encryption`/`smtp-auth` if your provider needs non-default values).

For PGP-signed outgoing mail (upstream `config.example.ini`):

1. generate or pick an OpenPGP key,
2. remove its passphrase (`gpg --edit-key <KEYID>` → `passwd` → empty),
3. export the private and public key to files **outside the Nix store**
   (readable by the `meta`/`git` users),
4. set `settings."mail".pgp-privkey` / `pgp-pubkey` to those paths and
   `pgp-key-id` to the key ID.

S3-compatible object storage (git tag artifacts, avatars) is optional via
`settings."objects".s3-*`.

## 7. SSH access to git.sr.ht

The module installs `sourcehut-ssh` as sshd's `AuthorizedKeysCommand` and
enables `PermitUserEnvironment SRHT_*`, so SSH keys registered in meta.sr.ht
are dispatched to `git.sr.ht-shell`. Upstream notes for this setup
(`man.sr.ht/git.sr.ht/installation.md`):

- the `git` system user must be able to log in ("make sure the git user is
  not locked"); on NixOS the module's system user works with public-key
  authentication
- port 22 must be reachable from clients
- verify with `ssh -T git@git.example.com`; after registering an SSH key
  through meta.sr.ht it should greet you instead of opening a shell

Repositories live in `services.srht.git.repos` (default `/var/lib/git`,
owned by `git:git`).

If another module already owns `AuthorizedKeysCommand`, set
`services.srht.git.manageSshd = false` and chain
`sourcehut-ssh "%u" "%h" "%t" "%k"` yourself.

## 8. Backup checklist

- PostgreSQL dumps of `meta.sr.ht` and `git.sr.ht`
- `services.srht.git.repos` (the repositories)
- the three secret keys (without them, sessions and webhook signatures cannot
  be restored)
- object storage buckets, if used

The Redis-compatible backend does **not** need to be backed up: it only holds
caches, the webhook-signature nonce store and the Celery webhook queue. Losing
it costs a re-login and possibly some in-flight webhook deliveries, nothing
permanent.

## Upstream references

- <https://man.sr.ht/installation.md> — general installation and prerequisites
- <https://man.sr.ht/meta.sr.ht/installation.md> — daemons, cronjobs, users
- <https://man.sr.ht/git.sr.ht/installation.md> — daemons, repository storage, SSH dispatch, HTTP cloning
- <https://git.sr.ht/~sircmpwn/git.sr.ht/tree/master/item/config.example.ini>
- <https://git.sr.ht/~sircmpwn/meta.sr.ht/tree/master/item/config.example.ini>
