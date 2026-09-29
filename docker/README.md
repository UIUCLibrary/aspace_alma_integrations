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

**The database is the exception, and deliberately so.** `mysql` publishes a
native `linux/arm64v8` image, so `DB_PLATFORM` is left empty and MySQL runs at
full speed on Apple Silicon while only ArchivesSpace and Solr are emulated.
Emulating the database as well made restoring a dump several times slower for no
benefit — importing is precisely the CPU- and IO-heavy work that emulation
punishes hardest, and unlike the application there is no compatibility reason to
do it.

The database is also tuned for import rather than durability: binary logging is
off and InnoDB flushes once a second instead of on every transaction. Measured
on a 173 MB dump, restore to accepting connections:

| settings | time |
|---|---|
| stock | 31s |
| relaxed durability only | 18s |
| binary logging off only | 16s |
| both (what we use) | **14s** |

That trade is safe here because this database is a disposable mirror: if it is
ever corrupted, the fix is `./scripts/up.sh --fresh`, which is what you would do
anyway. Do not copy these settings to a real server.

---

## Quick start

```bash
cd docker

cp .env.example .env
cp config/config.rb.example config/config.rb
```

Now edit both:

* **`.env`** — ports and memory. The defaults are fine to start with.
* **`config/config.rb`** — put your **Alma sandbox** API key in
  `AppConfig[:alma_apikey]`, and set `AppConfig[:alma_holdings]` to your
  location codes.

Then copy the database dump and Solr index down from the server by hand and
drop them into `docker/data/` — see
[Copying the data down from a server](#copying-the-data-down-from-a-server)
below for exactly what goes where. Then:

```bash
./scripts/check-data.sh       # confirms the files are where they should be
./scripts/up.sh --fresh       # restores them and starts
```

You can skip the data entirely and start with an empty ArchivesSpace
(`admin` / `admin`) if you just want to see the plugin's screens.

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

Working on the Arcflow indexing pipeline rather than the plugin? The stack can
run Arclight's Solr as well — see
[Indexing into Arclight with Arcflow](#indexing-into-arclight-with-arcflow).

---

## Copying the data down from a server

Nothing here reaches out to the server for you, so you need no SSH key and no
credentials in any config file. Copy two things down by whatever means you
normally use — `scp`, `rsync`, an SFTP client, a colleague sending you a dump —
put them in `docker/data/`, and run `./scripts/check-data.sh` to confirm they
landed where the containers will look.

### What goes where

| What | Where it is on the server | Where to put it locally |
|---|---|---|
| Database dump | you create it, see below | `docker/data/db-dump/01-archivesspace.sql.gz` |
| Solr index | `/var/solr/data/archivesspace` | `docker/data/solr/archivesspace` |
| Indexer state (optional) | `<aspace>/data/indexer_state` | `docker/data/indexer_state` |
| PUI indexer state (optional) | `<aspace>/data/indexer_pui_state` | `docker/data/indexer_pui_state` |

`<aspace>` is the ArchivesSpace install directory, usually `/opt/archivesspace`.

The finished layout:

```
docker/data/
├── db-dump/
│   └── 01-archivesspace.sql.gz
├── solr/
│   └── archivesspace/          <- the core directory, copied whole
│       ├── conf/
│       ├── core.properties
│       └── data/
│           └── index/
├── indexer_state/              <- optional
└── indexer_pui_state/          <- optional
```

`docker/data/` is gitignored, so nothing you put there can be committed by
accident.

### Match the version to the server

Set `ASPACE_VERSION` in `.env` to the version the server runs, not to the newest
release. It defaults to `4.1.1`, which is what UIUC staging runs. Check the
server with:

```bash
curl -s http://your-aspace-server:8089/ | grep -o '"archivesspace_version":"[^"]*"'
```

The version has to match in both directions, for different reasons:

- **Too old** and it will not start at all. ArchivesSpace migrates forward only,
  so a dump from a newer release has nowhere to go.
- **Too new** and it starts — but the first boot quietly **migrates your data**
  to the newer schema. That works, and it is a one-way change, but your local
  copy is then no longer the thing staging is running, which defeats the point
  of mirroring it.

One setting covers the application and Solr, because ArchivesSpace publishes
both images under the same tag. That is deliberate: it keeps the Solr configset
matched to the application, which ArchivesSpace verifies by checksum on startup.

If you change `ASPACE_VERSION` after you have already started, run
`./scripts/up.sh --fresh`. Neither the database nor the Solr index downgrades —
the database is on the old version's schema, and Solr's Lucene reads its own
major version and one back but not forward. `--fresh` rebuilds both from
`docker/data/`, which is untouched, so nothing is lost. `up.sh` notices the
change and stops with this advice rather than letting you find out later.

### The database dump

Take the dump on the server:

```bash
mysqldump --single-transaction --quick --routines --triggers \
          --default-character-set=utf8mb4 --no-tablespaces \
          -u archivesspace -p archivesspace | gzip > archivesspace.sql.gz
```

Then copy `archivesspace.sql.gz` to your laptop and put it at
`docker/data/db-dump/01-archivesspace.sql.gz`.

Those flags matter:

* **`--routines --triggers`** — ArchivesSpace uses both. A dump without them
  restores into a database that looks complete and then misbehaves. This is the
  single easiest thing to get wrong.
* **`--single-transaction`** — a consistent snapshot without locking tables, so
  it is safe to run against a server other people are using.
* **`--default-character-set=utf8mb4`** — ArchivesSpace stores UTF-8, and
  anything else mangles diacritics in exactly the records you care about.
* **`--no-tablespaces`** — avoids needing the `PROCESS` privilege, which a
  read-only reporting account usually lacks.

Naming and placement rules:

* It must be **inside `docker/data/db-dump/`**, which is mounted read-only into
  the database container at `/dump`.
* **Exactly one dump in that directory.** `load-db.sh` loads the first match and
  ignores the rest, so a stale dump sorting ahead of the new one would be loaded
  instead of it.
* The name is up to you as long as it ends in **`.sql` or `.sql.gz`**. The `01-`
  prefix is only a convention for keeping the order obvious.
* Uncompressed `.sql` works too; gzip just transfers faster.

MySQL only applies the dump on the **first start of an empty database**, which
is why restoring means `./scripts/up.sh --fresh` and not a plain restart.

### The Solr index — and why you may not want it

Copy the **`archivesspace` core directory** whole, so that you end up with
`docker/data/solr/archivesspace/data/index/`. On a stock install with a
standalone Solr that directory is `/var/solr/data/archivesspace`; with the
bundled Solr it is under the ArchivesSpace home instead. From your laptop:

```bash
rsync -az user@server:/var/solr/data/archivesspace/ \
      docker/data/solr/archivesspace/
```

`restore-solr.sh` also accepts `data/solr/data/index` and `data/solr/index`, so
if you copied a level too high or too low it will still find the index.

**The catch:** Lucene will only open an index written by its own major version
or the one before it. ArchivesSpace 4.x ships Solr 9, so a Solr 8 or 9 index
opens and anything older does not — and the failure is an opaque exception at
startup. `check-data.sh` prints the index format so you get some warning, and
`restore-solr.sh` tells you what to do if it fails.

The same rule bites on the minor versions if you change `ASPACE_VERSION`
downward: 4.1.1 ships Lucene 9.8 and 4.2.1 ships Lucene 9.12, so an index that
4.2.1 has opened may no longer load under 4.1.1. Your copy in `docker/data/` is
still as it came off the server, so `./scripts/up.sh --fresh` puts it back.

There is also no point copying an index that was being written to at the time,
though on a quiet dev server that is rarely a problem in practice.

Note that only `data/` is restored into the container: the image's own `conf/`
is kept. ArchivesSpace verifies the Solr schema against the version it expects
and refuses to start on a mismatch, so a `conf/` from a server running a
different ArchivesSpace release would break startup with an error pointing at
Solr rather than at the real cause.

**The reliable alternative is to skip the index entirely:**

```bash
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

### Indexer state

`indexer_state` and `indexer_pui_state` record how far the indexer has got.
They are small. Copying the index without them means ArchivesSpace concludes it
has indexed nothing and re-crawls the whole repository on first start, which
throws away much of the benefit of copying the index. Either copy them too, or
set `ASPACE_INDEXER_ENABLED=false` in `.env` to leave the copied index alone.

### Checking it landed correctly

```bash
./scripts/check-data.sh
```

It reports what it found and exits non-zero if something would actually break:
more than one dump, a truncated download, a file that is not a MySQL dump, or a
`data/solr` with no index in it. It also warns about the things that are merely
slow or surprising, like a missing indexer state.

---

## Day to day

```bash
./scripts/up.sh            # start (data preserved)
./scripts/down.sh          # stop
./scripts/logs.sh          # follow the ArchivesSpace log
./scripts/logs.sh --jobs   # just job/alma/index lines -- use this to watch an audit
./scripts/logs.sh --errors # just errors, with their stack traces
./scripts/smoke.sh         # load every page the plugin adds and check it renders
./scripts/spec.sh          # run the unit specs on the JRuby ArchivesSpace uses
./scripts/shell.sh         # shell inside the ArchivesSpace container
./scripts/shell.sh db      # MySQL client on the local database
./scripts/down.sh --clean  # delete local volumes (keeps ./data)
```

### When something returns 500

Two things make that quick to diagnose.

The error page itself shows the exception, the backtrace and the offending
source lines, because `ASPACE_DEBUG_EXCEPTIONS` is on by default. This is a
local-only affordance: the plugin that enables it lives in `docker/dev_plugin`
and is mounted only by this stack, never loaded by a real ArchivesSpace, since
stack traces in the browser disclose source paths and internals. Set
`ASPACE_DEBUG_EXCEPTIONS=false` in `.env` for the stock behaviour.

For anything that does not surface in the browser -- a failing job, a backend
error, a boot failure -- use the log. The indexer writes a round every thirty
seconds, so a plain `logs.sh` buries the interesting part:

```bash
./scripts/logs.sh --errors                     # follow, errors only
./scripts/logs.sh --errors --since 10m         # only what just happened
./scripts/logs.sh --errors --no-follow --tail 2000
```

It drops the indexer chatter and JRuby's constant-redefinition warnings, and
prints each error with the frames underneath it.

### Checking every page still renders

```bash
./scripts/smoke.sh
```

This logs in, selects a repository and requests every page the plugin adds --
the audit report list, the Alma integrations screens, and the job forms for
both `alma_audit_job` and `alma_bulk_update_job` -- failing on a non-200 or on
an error signature in the body.

Run it before pushing. The RSpec suite covers the pure Ruby underneath the
plugin and never renders a view, so a view calling a method ArchivesSpace does
not have passes `rspec` and fails in the browser. That gap is real and this
script is what closes it.

It needs a repository to exist, because ArchivesSpace resolves job URLs through
a `/repositories/:repo_id` template and returns 500 for all of them when the
session has no repository selected. On a stack restored from a server dump
there will be one already.

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
cd ..                                        # repository root
BUNDLE_GEMFILE=spec/Gemfile bundle install
BUNDLE_GEMFILE=spec/Gemfile bundle exec rspec
```

The manifest is `spec/Gemfile` rather than one in the plugin root on purpose;
the reason is in the main README. These tests cover the MARC diffing, the
report building and the rate limiter, and deliberately do not touch
ArchivesSpace. For the parts that do -- controllers and views -- use
`./scripts/smoke.sh` above.

#### Running them on JRuby instead

A green run on the host is not proof the code works in ArchivesSpace, because
ArchivesSpace runs JRuby and JRuby is stricter about string encodings. The one
that has actually bitten us: `JSON.generate` raises
`Encoding::UndefinedConversionError` on JRuby when handed a string tagged
`ASCII-8BIT` that contains bytes above `0x7F`, while MRI accepts it with only a
deprecation warning. Nokogiri returns exactly such strings, so the audit report
writer passed on the host and failed in production.

```bash
./scripts/spec.sh                            # whole suite, on JRuby
./scripts/spec.sh spec/report_writer_spec.rb # one file
```

It starts a throwaway container, so the stack does not need to be running, and
it takes about ten seconds. Worth running before shipping anything that touches
encodings, file writing or JSON.

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

## Indexing into Arclight with Arcflow

Arclight is the public discovery front end, themed by our Arcuit engine, and
[Arcflow](https://github.com/UIUCLibrary/arcflow) is the ETL that moves records
from ArchivesSpace into it. If you are working on that pipeline rather than on
the staff interface, this stack can run Arclight's Solr for you too, so that
the whole loop is local.

Arcflow and Arclight themselves stay on your laptop. Only Solr moves into
Docker:

```
  Arcflow  ──── ArchivesSpace API ──────►  localhost:8089   (this stack)
     │     ──── ArchivesSpace Solr ─────►  localhost:8983   (this stack)
     │
     └──── bundle exec traject ─────────►  localhost:8984   (this stack)
                                              Arclight Solr, blacklight-core
                                                    ▲
  Arclight + Arcuit, bin/dev on :3000 ──────────────┘
```

### Turning it on

It is off by default, so that nothing changes for anyone working only on the
plugin. In `.env`:

```bash
COMPOSE_PROFILES=arclight
ARCLIGHT_SOLR_CONF=/Users/you/code/arclight/solr/conf
```

`COMPOSE_PROFILES` is read by Docker Compose itself, so every script under
`scripts/` picks the service up with no extra flags.

`ARCLIGHT_SOLR_CONF` should point at **your own Arclight checkout**.
`arclight:install` copies the gem's configset into the app as `solr/conf`, and
yours is the only copy guaranteed to match the Arclight and Arcuit you are
actually running. Leave it empty and the setup script downloads Arclight's
stock configset instead — fine for indexing against, but without any Arcuit
changes.

Then:

```bash
./scripts/up.sh          # brings up Arclight's Solr along with everything else
```

or, if the rest of the stack is already running:

```bash
./scripts/arclight-solr.sh
```

You get a `blacklight-core` core at <http://localhost:8984/solr/blacklight-core>.

### Pointing Arcflow and Arclight at it

Both default to port **8983**, which here is ArchivesSpace's Solr, so both need
telling.

Arclight, on your laptop:

```bash
SOLR_URL=http://localhost:8984/solr/blacklight-core bin/dev
```

Arcflow, also on your laptop — and note it wants both Solrs, ArchivesSpace's as
well as Arclight's:

```bash
python -m arcflow.main \
  --arclight-dir /path/to/arclight \
  --solr-url http://localhost:8984/solr/blacklight-core \
  --aspace-solr-url http://localhost:8983/solr/archivesspace
```

Arcflow reaches the ArchivesSpace API through `.archivessnake.yml`, whose
example already points at `http://localhost:8089` — the backend port this stack
publishes — so that file usually needs nothing but a username and password.

If you would rather not pass the ports every time, swap them instead: set
`ARCLIGHT_SOLR_PORT=8983` and `SOLR_PORT=8984` in `.env`. Nothing here cares
which way round they are; ArchivesSpace reaches its own Solr over the Docker
network, not through the published port.

### The `is_creator` field

Arcflow marks its creator documents with a boolean `is_creator`, so they can be
told apart from collections. That is not an Arclight field, and it does not
match any of the dynamic field patterns (`*_ssim`, `*_tesim` and so on), so
indexing creators into a stock Arclight core fails with:

```
ERROR: [doc=creator_corporate_entities_584] unknown field 'is_creator'
```

`scripts/arclight-solr.sh` adds it for you, to its own copy of the configset —
your Arclight checkout is never written to.

**Arcflow's README tells you to add this through Solr's Schema API. That cannot
work.** Arclight's `solrconfig.xml` sets `<schemaFactory
class="ClassicIndexSchemaFactory"/>`, which makes the schema read-only at
runtime, and the `curl` in those instructions gets a 400 back. The field has to
be in `schema.xml` before the core is created, which is what this script does.
Worth knowing if you ever set one of these up by hand.

Everything else Arcflow indexes — `entity_type_ssi`, `bioghist_tesim`,
`creator_of_collection__collection_ids_ssim`, `record_group_ssim` and the rest
— uses Arclight's dynamic field suffixes and needs no schema change.

### Changing the configset

`solr-precreate` only does anything when the core does not yet exist, so
editing the configset has no effect on a core that is already there. Rebuild
it:

```bash
./scripts/arclight-solr.sh --reset
```

That throws the index away. You are testing an ETL, so rebuilding it is the
point — but it is not reversible, and it is the command to reach for whenever
the core looks stale or will not load.

Other things the script does:

```bash
./scripts/arclight-solr.sh --status                  # up? how many documents?
./scripts/arclight-solr.sh --conf /some/other/conf   # one-off configset
./scripts/arclight-solr.sh --prepare-only            # write the configset, do not start
```

To empty the index without touching the schema, ask Solr directly:

```bash
curl 'http://localhost:8984/solr/blacklight-core/update?commit=true' \
  -H 'Content-Type: text/xml' --data-binary '<delete><query>*:*</query></delete>'
```

### Starting from a copied index

Usually you do not want one: the reason to run this is to watch Arcflow build
the index. But if you have pulled a core down from a server, put its `data`
directory at `docker/data/arclight-solr/index/` and the script will restore it
the same way `restore-solr.sh` handles the ArchivesSpace one. On the server the
core lives at `/var/solr/data/blacklight-core`.

It refuses to restore over a core that already holds documents — use `--reset`
if that is really what you want.

### Solr versions

`ARCLIGHT_SOLR_VERSION` defaults to **9.7.0**, which is what Arclight itself
develops against (its `.solr_wrapper`). Arclight 1.6.x's configset declares
`luceneMatchVersion 8.2.0` and carries `<lib>` paths for both Solr 8 (`contrib/`)
and Solr 9 (`modules/`), so it loads under either; set `8.11.3` if you need to
match Arcflow's own test stack, which pins that.

On Solr 9 the startup log carries a warning about a missing
`contrib/analysis-extras/lucene-libs`. That is the Solr 8 path and is harmless
— the ICU analysers Arclight's `text` and `text_en` field types depend on come
from `modules/` and do load. Do not "fix" it by deleting the `<lib>` lines; the
schema will not work without those analysers.

Unlike the ArchivesSpace images, the stock `solr` image is published for arm64,
so this one service runs natively on Apple Silicon rather than under emulation.
That matters here more than anywhere else in the stack — indexing thousands of
records is exactly the sustained work emulation punishes.

---

## Troubleshooting

### The backend returns 500 and the log mentions `schema_info`

`Table 'archivesspace.schema_info' doesn't exist` means the database has no
ArchivesSpace schema in it. ArchivesSpace does not migrate on startup -- it
checks the schema version and refuses to run if the tables are missing -- so an
empty database needs the migrations applied first. `up.sh` does this for you on
every start; to do it by hand:

```
docker compose run --rm --no-deps \
  --entrypoint /archivesspace/scripts/setup-database.sh archivesspace
```

If that fails, check that `ASPACE_VERSION` in `.env` is at least the version the
dump came from. ArchivesSpace migrates forward only, so pointing an older
release at a dump from a newer one will not work.

### The migrations fail with `Communications link failure`

```
Sequel::DatabaseConnectionError: Java::ComMysqlCjJdbcExceptions::CommunicationsException:
Communications link failure
The last packet sent successfully to the server was 0 milliseconds ago.
The driver has not received any packets from the server.
```

This is a **readiness** problem, not a version problem, and the distinction
matters because the fixes are unrelated. "Has not received any packets" means
nothing was listening on the database port -- ArchivesSpace never got far enough
to look at the schema, so `ASPACE_VERSION` is not involved.

It means nothing was listening on the database port yet. This used to be common
because the dump was applied by MySQL's entrypoint, which does that work behind a
temporary server bound to a unix socket with **no TCP** -- so the port stayed
shut for the whole import.

The dump is now loaded as its own step (`scripts/load-db.sh`) after the server is
up, so the database is reachable within seconds of starting. `up.sh` also waits
for the healthcheck before doing anything that needs a connection. If you see
this anyway, or you are running steps by hand, wait for health first:

```bash
docker compose ps db                     # look for (healthy)
docker compose logs -f db                # watch the import
```

and re-run `./scripts/up.sh`. It is safe to re-run; the migrations are
idempotent, and without `--fresh` it will not touch your data.

### ArchivesSpace exits during startup with a Bundler error

If the log shows `You cannot specify the same gem twice with different version
requirements`, something has put a `Gemfile` in the plugin root. ArchivesSpace
evaluates every `plugins/*/Gemfile` into its own bundle at boot, so a version
constraint there is resolved against ArchivesSpace's own pins, and a conflict
stops the whole application from starting. This plugin keeps its test-only
dependencies in `spec/Gemfile` for exactly this reason. The stack trace points
at ArchivesSpace's own Gemfile, so read a few lines further down for the
`plugins/alma_integrations/Gemfile` frame that names the real culprit.



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
without `--routines --triggers`. Re-take it on the server with the flags in
[The database dump](#the-database-dump), replace
`data/db-dump/01-archivesspace.sql.gz`, and run `./scripts/up.sh --fresh`.

**The dump seems not to have been applied at all.** `load-db.sh` skips itself
when the database already has tables, so a plain restart will not pick up a newly
copied dump. Either reload it in place:

```bash
./scripts/load-db.sh --force
```

or use `./scripts/up.sh --fresh`, which wipes the volume first. Check that
`./scripts/check-data.sh` shows exactly one dump, too — only the first is
loaded.

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
