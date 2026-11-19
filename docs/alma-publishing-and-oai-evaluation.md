# Should the audit read Alma through publishing/OAI instead of the Bibs API?

**Verdict: no. Not for this audit, and probably not for any future version of it.**

This was investigated because the bulk audit reads records from the Alma REST API,
which consumes the institution's daily API allowance — an allowance shared with
every other Alma integration on campus. Alma's General Publishing and OAI-PMH
routes appear, on the architectural evidence, to sit outside that allowance
entirely. That makes them superficially attractive. They are not worth taking.

The rest of this document records why, so the question does not have to be
re-opened from scratch.

## What the Bibs API currently costs

Identifier resolution is pure SQL against the ArchivesSpace database and costs
nothing. The audit then reads bibs 100 at a time through Alma's multi-ID
`GET /bibs?mms_id=<...>`, so a 1,200-record audit costs about **12 calls**, not
1,200. The expensive half is the update, where one PUT per record is
irreducible — Alma has no bulk bib write.

So the audit side, the only side publishing/OAI could replace, already runs at
roughly **100 records per API call**. There is not much left to save.

One caveat on that figure: Ex Libris does not document whether a 100-ID GET is
charged as one call or as a hundred. The jobs now report the drop in
`X-Exl-Api-Remaining` alongside the number of requests they made, so the first
real run settles it. Everything below assumes the favourable reading; if it
turns out a multi-ID GET is charged per ID, the arithmetic for the alternatives
improves but the objections in the next section do not go away.

## Why the alternatives lose anyway

**Suppressed records are invisible to publishing, and this plugin creates
suppressed records.** Alma's default is to suppress a bib created through the
API, which is why the README tells you to un-suppress manually in the Metadata
Editor. A suppressed record does not appear in a publishing profile's output at
all; over OAI it surfaces as a `<header status="deleted">` tombstone with no
`<metadata>` element. The records most likely to need auditing would be exactly
the records this route cannot show. This objection alone is decisive.

**Published MARC is not the MARC Alma stores.** A publishing profile can enrich
its output with holdings and item data — `852`, `955`, `998` and similar, chosen
per profile — and the profile at any given institution is usually shared with
Primo or POD and not safely changeable by whoever is running the audit. The
diff's `ignored_tags` and `ignore_value_patterns` were calibrated against Bibs
API output. Auditing published output would mean recalibrating them against
whatever enrichment the local profile happens to apply, and re-doing it whenever
somebody else changes that profile. An audit whose baseline can move underneath
it without warning is not much of an audit.

**The content is stale by design.** OAI serves whatever the last publishing run
produced. A realistic floor is 30–90 minutes behind Alma with an hourly
incremental profile; full republishing runs take many hours. A record edited
since the last run would be reported as differing from ArchivesSpace when it does
not. The whole point of this audit is to tell someone what they are about to
destroy, which makes a false difference worse than a slow answer.

**It is not actually fewer requests for a list of specific records.** OAI
`GetRecord` fetches one record per HTTP request, so a 3,000-record audit becomes
3,000 requests against an endpoint with no documented rate limit and therefore no
documented safe concurrency. `ListRecords` does page 100 at a time, but only over
a *set*, which means building an Alma set that is exactly the audit's list — and
the "Republish / Rebuild Entire Index" action that makes a changed set take
effect is explicitly not available through the Jobs API. Orchestrating that
through `POST /conf/sets`, `op=add_members` and `POST /conf/jobs/{id}?op=run`
would itself consume REST quota, then wait hours for the job, then poll.

**It demands Alma configuration the plugin's users may not have.** The current
setup needs one API key. The OAI route needs an OAI integration profile, a
publishing profile, and the ArchivesSpace host's IP allowlisted on the OAI
profile — allowlisting that is managed separately from the API key. For a plugin
distributed to other institutions, that is a per-site deployment burden in
exchange for savings on the half of the work that is already cheap.

## What would change the answer

Only one thing: auditing the **entire catalogue** on a regular schedule, rather
than a list of a few thousand records. At that scale a nightly publish to SFTP
plus a local file read genuinely is the right shape, and the staleness and
enrichment problems become tractable because you would be tuning against one
known profile continuously rather than once per ad-hoc list. If that ever
becomes the use case, revisit this — but as a separate ingest path alongside the
API route, not as a replacement for it, because of the suppressed-record problem.

## Confidence and provenance

Ex Libris' own documentation sites were unreachable from the environment this
research ran in, so none of the above rests on a first-party page read directly.
It is drawn from a mirrored copy of Ex Libris' own OpenAPI definition for the
Configuration API, from live Alma OAI responses committed as test fixtures by
other institutions, from a dated probe of a production Alma OAI endpoint, and
from operational documentation published by Princeton, Penn, Temple,
Northwestern and Emory.

Two points in particular are **inference rather than documented fact** and should
be checked with an Alma administrator before anyone relies on them:

- That OAI and publishing output are outside the REST governance threshold. The
  evidence is strong but circumstantial: OAI lives on a different hostname, takes
  no API key, has its own error vocabulary, and institutions harvest whole
  catalogues over it at volumes that would exhaust any plausible daily
  allowance. No first-party statement either way was found.
- That publishing profiles can apply normalisation rules to their output, which
  would make published MARC differ from stored MARC and rule the route out
  independently. Only suggestive evidence was found.

Neither affects the verdict, because the suppressed-record and enrichment
objections stand on their own.
