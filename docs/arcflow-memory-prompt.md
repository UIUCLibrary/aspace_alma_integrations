# Agent prompt: Arcflow memory and efficiency work

This document is a task brief for an agent working in
[`UIUCLibrary/arcflow`](https://github.com/UIUCLibrary/arcflow). It lives here
because it was produced while testing Arcflow against the local Docker stack in
[`docker/`](../docker/README.md), not because any of the work belongs in this
repository. Nothing in this repository needs to change.

Hand the agent this file plus a checkout of Arcflow.

---

## Background

A run of roughly 10,000 resources and 5,000 agents against a containerised
ArchivesSpace on a MacBook Air (7 GB allocated to Docker) showed one large step
up in memory, then a steady climb with occasional large drops.

Arcflow's Python process was profiled to find out how much of that is Arcflow.
**Most of it is not.** Read the next section before changing anything, because
it determines which of the fixes below are worth prioritising.

## What was measured, and how

Arcflow's real `process_collections` was driven against an in-process stub of
`ASnakeClient` (no live ArchivesSpace), using a ~35 KiB EAD fixture with 60
components. RSS was sampled from `/proc/self/status` against the number of
records completed, inside a single run.

**Finding 1 — the per-record path does not leak.** After 6,000 records,
`tracemalloc` attributes under ~100 KiB of retained allocation across all sites,
and live object counts by type are unchanged. `XmlTransformService`,
`AgentService` and `OmekaService` hold no cross-record state, and the lxml trees
are released correctly.

**Finding 2 — the growth is a step, not a climb.** Sampling every 250 records
across a 10,000-record run:

```
 records  RSS MiB   delta
     250     53.3  +16.52
     500     53.3   +0.00
    1000     53.3   +0.02
    5000     53.3   +0.00
   10000     53.3   +0.00
```

Memory reaches its peak before the first few hundred records finish and then
does not move for the remaining 9,750. Runs at 500 / 2,000 / 6,000 / 20,000
records show the size of that step scaling linearly with the number of records,
at roughly **1.7 KiB per queued task**.

**Consequence for the 10k + 5k run:** the step is worth on the order of
**25 MiB**, and the Python process should settle somewhere near 60–100 MiB
total. That is real, and worth fixing because it scales with the wrong thing,
but *it does not explain a multi-gigabyte climb.*

**Finding 3 — the steady climb with large drops is a JVM sawtooth, not Python.**
A flat Python RSS with a climbing container total points at the services Arcflow
drives: ArchivesSpace's JVM, Solr's JVM, MySQL, and page cache from files
written during the run. Steady growth punctuated by large drops is the shape of
a heap filling and then being collected. In the stack in `docker/`, ArchivesSpace
is given `-Xmx2g` and Solr `-Xms512m -Xmx1536m`; those ceilings plus non-heap
overhead and MySQL are a tight fit in a 7 GB VM before Arcflow adds any load.

**Before optimising Arcflow's Python memory, confirm which process is growing.**
Watch the `python -m arcflow.main` RSS directly (it runs on the laptop, outside
the container — if the 7 GB figure is Docker's, Arcflow is not in that number at
all) alongside `docker stats`. If the container grows while Python stays flat,
the highest-value fixes are the ones that reduce load on ArchivesSpace — items 1
and 2 below — not the allocation fixes.

---

## The work

Ordered by expected impact for a 10,000-resource run. Each item states the
evidence, so re-verify rather than trusting this document.

### 1. One `print_to_pdf_job` per resource is the dominant cost on ArchivesSpace

`task_resource` calls `request_pdf_job` for every published resource, so a
10,000-resource run creates 10,000 ArchivesSpace jobs, each producing a PDF that
ArchivesSpace generates, stores and serves back. That is almost certainly the
largest single source of pressure on the container, and it is pressure Arcflow
creates.

Investigate what can be done about it: whether PDFs need regenerating for
resources whose EAD has not changed, whether job creation can be throttled or
batched rather than fired per resource ahead of the polling phase, and whether
completed job records and output files can be cleaned up as they are consumed so
ArchivesSpace is not holding thousands of them. `--skip-pdf-generation` already
exists as an escape hatch; the goal is to make the default path affordable.

Treat the ArchivesSpace side as the thing being measured here, not Arcflow's RSS.

### 2. `_execute_solr_query` fetches an entire result set to count it

In `main.py`, `_execute_solr_query` issues a query with `rows=0` to read
`numFound`, then re-issues it with `rows=num_found` — the whole result set in a
single unpaginated response, parsed into one list.

`get_all_agents` calls it twice. The first call, for `excluded_docs`, exists
only so that `len(excluded_ids)` can be written to a log line — a number the
count query already returned. That entire fetch and JSON parse is discarded.

Fix the wasted call outright. For the query whose results are actually used,
page it (Solr's `cursorMark` is the right tool for deep paging) rather than
materialising everything at once.

### 3. Fan-out queues every task up front and holds every handle

`process_collections`, `process_digital_objects` and `process_creators` all use
the same shape:

```python
results = [pool.apply_async(self.task_resource, args=(...)) for ... ]
for r in results:
    r.get()
```

`apply_async` puts each task straight onto the `ThreadPool`'s unbounded
`_taskqueue`, and each `AsyncResult` carries a `threading.Event` (a `Condition`
and a `Lock`). All N exist before the first one runs, and the list pins every
`AsyncResult` — along with its retained `_value` — until the phase ends.
Isolating just this pattern:

```
N= 20000   all-pending +21.2 MiB    after get() +30.7 MiB
N= 50000   all-pending +57.8 MiB    after get() +82.4 MiB
```

Peak memory becomes a function of how many records are in the run rather than
how many are in flight.

Bound the number of outstanding tasks — chunk the record list and drain each
chunk before queueing the next. `self.batch_size` is already 400 and would be a
reasonable chunk size. Do not assume `imap_unordered` fixes this: `ThreadPool`'s
input queue is unbounded too, so it can still run far ahead of the workers.
Explicit chunking or a semaphore is what actually bounds it.

Keep `--repository-id`, the `--skip-*` flags and the symlink-based
pending/completed bookkeeping working exactly as they do now.

### 4. `index_collections` rescans the whole directory once per batch

The batching loop calls `os.scandir(xml_dir)` from the start on every iteration,
breaking once it has collected `batch_size` entries. As the directory fills with
`completed_*` symlinks, each successive batch scans further before finding
`created_*` work, so total scanning cost grows quadratically with the number of
resources. Iterate the directory once and consume from that iterator across
batches.

### 5. `AgentService.get_agent_bioghist_data` has no cache

It is called once per creator per resource, and re-fetches the same agent over
HTTP every time. A creator linked to 200 collections is fetched 200 times. A
plain dict cache keyed on `agent_uri`, held for the life of the run, removes a
large number of round trips — and the saving is largest on exactly the
shared-creator records that matter. Note the pipeline is threaded, so make the
cache safe for concurrent access.

While in this area: `find_eac_cpf_config` is called in `process_creators` and
then again at the top of `index_creators`, which is redundant.

### 6. A shared `requests.Session` across pool threads

The single `ASnakeClient` created in `ArcFlow.__init__` is used from all four
pool threads. `requests.Session` is not documented as thread-safe. This is a
correctness risk rather than a memory one, and it may explain intermittent,
hard-to-reproduce failures. Confirm the behaviour before changing it; the fix is
a session per thread.

### 7. Dead code with a latent file-handle leak

`get_ead_id_from_file` calls `xml.dom.pulldom.parse(xml_file_path)` and `break`s
out of the iteration without closing the underlying file. It is never called —
`get_ead_from_symlink` is used instead at both call sites. Remove it, or fix it
so it does not become a real leak if someone starts calling it.

---

## Constraints

- Behaviour must not change. The symlink naming scheme
  (`created_`/`completed_`, and the `{resource_id}.xml` pointer used to detect a
  changed `ead_id`), the `.arcflow.yml` timestamp bookkeeping, and every CLI flag
  must keep working as they do today.
- Do not add dependencies. Everything above is achievable with the standard
  library plus what Arcflow already imports.
- Arcflow's README is out of date and should not be trusted as a specification:
  it documents an `--aspace-dir` option that no longer exists in `main()`, calls
  `--ead-extra-config` by the name `--traject-extra-config`, and omits
  `--aspace-solr-url`, which is required. Fixing the README is in scope and
  worth doing.

## How to verify

Profiling Arcflow does not require a live ArchivesSpace. Stub `ASnakeClient`
in-process, feed it a realistic EAD fixture, and sample `VmRSS` from
`/proc/self/status` against records completed *inside* a single run. Sampling
only before and after cannot distinguish a fixed step from a genuine leak — that
distinction is the whole point, and it is what the numbers above rest on.

Useful checks:

- RSS sampled every N records should stay flat across the run, and the initial
  step should stop scaling with the total record count.
- `tracemalloc` snapshots compared across the run should show nothing
  accumulating.
- Confirm against a real ArchivesSpace afterwards, watching the Python RSS and
  `docker stats` side by side, since the stub deliberately removes the HTTP
  layer and the ArchivesSpace-side cost that item 1 is about.

The stack in [`docker/`](../docker/README.md) gives you ArchivesSpace, both Solr
cores and MySQL for that final check.
