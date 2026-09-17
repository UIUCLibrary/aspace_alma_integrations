# Local ArchivesSpace for plugin development

A Docker stack that runs ArchivesSpace, MySQL and Solr on your machine, so you
can exercise this plugin — including the Alma audit and bulk update jobs —
against a copy of a real server's data before going anywhere near a shared
staging box.

It is built to *mirror*: you copy down a server's database and, optionally, its
Solr index, and point this at them.

---

## Before you start

**Docker Desktop** (macOS) or Docker Engine with the Compose v2 plugin (Linux).
Give Docker at least **6 GB of RAM** — Settings → Resources on Docker Desktop.
ArchivesSpace and Solr are both JVMs and will be unhappy below that.

**About 10 GB of disk**, more if the repository you are mirroring is large.

**SSH key access to the server you want to mirror**, plus a MySQL user on it
that can run a dump. The fetch script will not accept an interactive SSH
password.

### A word about Apple Silicon

ArchivesSpace publishes **amd64 images only** — there is no arm64 build of
either `archivesspace/archivesspace` or `archivesspace/solr`. On your M2 this
runs under Rosetta emulation.

It works, but:

* first start is slow — **10 to 20 minutes** is normal, and longer if database
  migrations run against a restored dump;
* subsequent starts are much quicker, a couple of minutes;
* it is memory-hungry. 6 GB allocated to Docker is a realistic floor.

Turn on **Settings → General → Use Rosetta for x86_64/amd64 emulation** in
Docker Desktop if it is not already on. It is significantly faster than the
default QEMU path.

`ASPACE_PLATFORM` is pinned to `linux/amd64` in `.env` deliberately, so the
stack behaves identically on your laptop and on an amd64 CI runner. That is the
whole point when you are trying to reproduce a bug someone else is seeing.

---

## Quick start

```bash
cd docker

cp .env.example .env
cp config/config.rb.example config/config.rb
```

Now edit both:

* **`.env`** — set `REMOTE_HOST`, `REMOTE_USER`, `REMOTE_DB_*` and
  `REMOTE_SOLR_DATA` to point at the server you are mirroring.
* **`config/config.rb`** — put your **Alma sandbox** API key in
  `AppConfig[:alma_apikey]`, and set `AppConfig[:alma_holdings]` to your
  location codes.

Then:

```bash
./scripts/fetch-remote.sh     # pull down the database and Solr index
./scripts/up.sh --fresh       # restore them and start
```

When it finishes you get:

| | |
|---|---|
| Staff interface | <http://localhost:8080> |
| Public interface | <http://localhost:8081> |
| Backend API | <http://localhost:8089> |
| Solr | <http://localhost:8983/solr> |

Log in with an account from the mirrored server. (If you started without a
dump, it is `admin` / `admin`.)

The plugin is at **Repository menu → Plugins → Alma Integrations**, and the new
jobs are under **Create → Job → Alma Audit**.

---

## Pulling data down from a server

`./scripts/fetch-remote.sh` does both halves; `--db-only` and `--solr-only`
do one at a time.

### The database

The dump is produced *on the remote host* and streamed back over SSH
compressed, so nothing large is written to that server's disk. It uses
`--single-transaction`, which takes a consistent snapshot without locking
tables — safe to run against a server other people are using.

It includes `--routines` and `--triggers`. ArchivesSpace uses both, and a dump
without them restores into a database that looks fine and then misbehaves.

The password is passed to `mysqldump` through the environment rather than on
the command line, so it does not show up in that server's process list.

The result lands in `data/db-dump/01-archivesspace.sql.gz`. MySQL's entrypoint
applies everything in that directory on **first start of an empty database** —
which is why restoring means `up.sh --fresh` rather than a plain restart.

### The Solr index — and why you may not want it

The script rsyncs the remote index into `data/solr`, and `up.sh --fresh` copies
it into the Solr container.

**The catch:** Lucene will only open an index written by its own major version
or the one before it. If the server runs an older Solr than the ArchivesSpace
image you have pinned, the core will refuse to load and you get an opaque
exception at startup. `fetch-remote.sh` prints the remote index format so you
get some warning, and `restore-solr.sh` tells you what to do if it fails.

There is also no point copying an index that was being written to at the time,
though on a quiet dev server that is rarely a problem in practice.

**The reliable alternative is to skip the copy entirely:**

```bash
./scripts/fetch-remote.sh --db-only
./scripts/up.sh --fresh
./scripts/reindex.sh
```

Reindexing takes tens of minutes on a large repository, and longer under
emulation — but it cannot fail on a version mismatch and the index is
guaranteed to match the database you actually restored. If you are only testing
this plugin, note that **the Alma jobs read from the database, not from Solr.**
Solr only drives search and browse. A stale or missing index will not affect an
audit run at all. Reindex when you need to *find* records in the staff
interface, not to run a job against them.

---

## Day to day

```bash
./scripts/up.sh            # start (data preserved)
./scripts/down.sh          # stop
./scripts/logs.sh          # follow the ArchivesSpace log
./scripts/logs.sh --jobs   # just job/alma/index lines -- use this to watch an audit
./scripts/shell.sh         # shell inside the ArchivesSpace container
./scripts/shell.sh db      # MySQL client on the local database
./scripts/down.sh --clean  # delete local volumes (keeps ./data)
```

### Editing the plugin

Your working copy is bind-mounted read-only at
`/archivesspace/plugins/alma_integrations`. After changing Ruby code:

```bash
docker compose restart archivesspace
```

That is about a minute rather than a full boot. For view/ERB work you can
uncomment `AppConfig[:frontend_cache_classes] = false` in `config/config.rb`
and skip the restart, at the cost of a slower interface.

Changes to `schemas/` or `backend/job_runners/` always need a restart —
ArchivesSpace loads those at boot.

### Running the unit tests

The shared library has no ArchivesSpace dependencies, so its tests run on the
host with no container at all:

```bash
cd ..            # repository root
bundle install
bundle exec rspec
```

---

## Trying the Alma jobs locally

1. Find a resource in the mirrored data that has an MMS ID in the field named
   by `AppConfig[:alma_mms_id_field]` (User Defined String 2 by default,
   relabelled "Alma MMS ID" in the interface by this plugin).
2. **Create → Job → Alma Audit**, paste a handful of identifiers, submit.
3. Watch it with `./scripts/logs.sh --jobs`.
4. When it finishes, **Plugins → Alma Integrations → Alma Audit Reports** has
   the summary and the JSON download.

Two settings in `config.rb.example` exist to make this pleasant locally:
`alma_bulk_fetch_size` is dropped to 10 so you can watch chunking happen with a
short list, and `alma_requests_per_second` is dropped to 5 because the Alma
sandbox is shared.

**Use a sandbox API key.** The bulk update job writes to Alma. Against a
production key, a mistake here rewrites real catalogue records. The job
defaults to dry-run, but do not rely on that as your only safeguard.

---

## Troubleshooting

**First start seems hung.** It probably is not. Migrations against a restored
dump are slow, and slow again under emulation. `./scripts/logs.sh` will show
what it is doing. The healthcheck allows 15 minutes before complaining.

**`Cannot connect to the Docker daemon`.** Docker Desktop is not running.

**Port already in use.** Change `STAFF_PORT` and friends in `.env`, and update
`AppConfig[:frontend_url]` in `config/config.rb` to match — otherwise redirects
send you to the wrong port.

**Solr core will not load.** Almost always the version mismatch described
above. `docker compose logs solr` confirms it; `./scripts/reindex.sh` fixes it.

**Search returns nothing but records exist.** The index is empty or stale. Run
`./scripts/reindex.sh`. Again, this does not affect the Alma jobs.

**`Table 'x' doesn't exist` or migration errors.** The dump was probably taken
without `--routines --triggers`. Re-run `./scripts/fetch-remote.sh --db-only`
and `./scripts/up.sh --fresh`.

**Out of memory / the JVM dies.** Raise Docker's memory allocation, or lower
`ASPACE_JAVA_XMX` and `SOLR_JAVA_MEM` in `.env`.

**Start completely over.**

```bash
./scripts/down.sh --clean
./scripts/up.sh --fresh
```

---

## What is gitignored

`docker/data/`, `docker/config/config.rb` and `docker/.env` are all ignored,
and should stay that way. Between them they hold a copy of production data, a
real Alma API key and database passwords. The `.example` files are the tracked
ones — keep credentials out of those.
