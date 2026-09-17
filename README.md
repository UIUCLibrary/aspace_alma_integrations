# Alma/ArchivesSpace Integrations

This plugin provides integrations between the ArchivesSpace archival collection management system and the Alma library management system from Ex Libris. It is built on the [Top Container](https://github.com/hudmol/container_management) functionality that Hudson Molonglo developed for ArchivesSpace. Based on the Resource record provided by a user, the integrations will perform the following API calls:

* Check for a BIB with the Resource's MMS ID
* Check for holdings associated with the BIB identified by that MMS ID

Additionally, the integrations allow a user to add new holdings, create a new BIB record if no MMS ID is present or the provided MMS ID does not match any BIB record in Alma, or sync changes to a Resource in ArchivesSpace with the BIB record uniquely identified by the Resource's MMS ID.

# Prerequisites

## For your Resource record

You will need to have a data element in your ArchivesSpace Resources assigned to the MMS IDs for their Alma bibliographic records, so that the API calls have an identifier against which to check. The default is User Defined String 2, which is also what the University of Denver uses, but this is now configurable via **AppConfig[:alma_mms_id_field]** (see below). The plugin also relabels that field in the staff interface so it reads "Alma MMS ID" rather than "String 2", which saves explaining to every cataloguer why the MMS ID lives in an anonymously-named box.

## For your config.rb file

You will need to add three required configuration settings and one optional setting to your config.rb file for these integrations to work:

* **AppConfig[:alma_api_url]** represents the URL you use to access the Alma API. These are region-specific; find yours [here](https://developers.exlibrisgroup.com/alma/apis#calling). Note that since the plugin only uses the `/bibs` API, you will need to include "/bibs" at the end of the API URL string.
* **AppConfig[:alma_apikey]** is the specific API key you use to access the Alma APIs. You may need to consult with your library IT department to access an API key to use for this plugin. If you would like to test API calls against the Alma sandbox, you may request a personal API key through the Alma Developer Network; instructions for this may be found [here](https://developers.exlibrisgroup.com/alma/apis#logging).
* **AppConfig[:alma_holdings]** is an array of the building and location codes in place at your institution. Each item in the array is itself an array, consisting of a building code (`852$b`) and a location code (`852$c`). These are added to the 852 field of the holdings records that the plugin creates.
* **AppConfig[:alma_marc_fields_to_preserve]** *(optional)* is an array of MARC field tags (as strings) whose values should be carried over from the existing Alma record into the ASpace-generated record before pushing to Alma. Use this to prevent locally significant Alma-managed fields from being overwritten. For example, `['035']` will preserve OCLC system control numbers stored in Alma's 035 field. When a tag is listed here, all instances of that field are removed from the ASpace record and replaced with the corresponding fields from Alma. The MARC 008 "Date Entered on File" (positions 00–05) is always preserved regardless of this setting.

### Optional settings for the bulk audit and bulk update

Every one of these has a working default; you only need to set the ones you want to change.

| Setting | Default | What it does |
|---|---|---|
| `AppConfig[:alma_mms_id_field]` | `'string_2'` | Which Resource user-defined field holds the MMS ID. One of `string_1`–`string_4` or `text_1`–`text_5`. |
| `AppConfig[:alma_requests_per_second]` | `19` | Ceiling for requests to Alma. Ex Libris governs at roughly 25/second **per institution**, not per API key, so this leaves headroom for your other campus integrations. |
| `AppConfig[:alma_daily_quota_floor]` | `1000` | Stop a job when Alma's reported remaining daily calls drops below this. Prevents an audit from consuming the institution's whole daily quota. |
| `AppConfig[:alma_max_retries]` | `5` | Retries for a throttled or transient failure, with exponential backoff plus jitter. |
| `AppConfig[:alma_open_timeout]` | `15` | Seconds to wait for a connection. |
| `AppConfig[:alma_read_timeout]` | `120` | Seconds to wait for a response. |
| `AppConfig[:alma_bulk_fetch_size]` | `100` | MMS IDs per bulk `GET /bibs` call. 100 is Alma's documented maximum. |
| `AppConfig[:alma_audit_ignored_tags]` | `['001', '003', '005']` | Tags excluded from the headline summary because they differ mechanically on every record. |
| `AppConfig[:alma_audit_recommend_threshold]` | `0.25` | A tag lost from at least this share of records earns a place in the report's suggested `alma_marc_fields_to_preserve` list. |
| `AppConfig[:alma_audit_store_alma_marc]` | `true` | Store each Alma MARC record as fetched, inside the report. This is the failsafe copy (see below). |
| `AppConfig[:alma_audit_report_retention_days]` | `nil` | Delete audit report files older than N days. `nil` keeps them forever. Only the files are removed; job history rows are never touched. |
| `AppConfig[:alma_include_unpublished]` | `false` | Whether generated MARC includes unpublished records. Must match whatever your single-record push uses, or the audit will describe a push you are not actually making. |
| `AppConfig[:alma_standalone_permission]` | `false` | Register the bulk-update permission as a real, independently grantable permission instead of deriving it. See [Permissions](#permissions). |

# Bulk audit and bulk update

Two ArchivesSpace background jobs handle work across many records at once. Because they are native jobs, you do not have to sit on a page waiting: close the tab, come back later, and the run is in your job list with its status, owner, timestamps, a tailing log, a cancel button, and downloadable output.

## Auditing before you update

**Create Job → Alma Audit.** Give it a list of records, either pasted into the form or uploaded as a file — one identifier per line, or a CSV/TSV column. Identifiers can be:

* an **MMS ID**, matched against the configured user-defined field;
* an **EAD ID**, matched against the Resource's `ead_id`;
* a **resource identifier** (`id_0`, or the full identifier), matched against the Resource's identifier.

By default the job classifies each line on its own, but you can force a single type on the form. Prefixing a line with `mms:` or `ead:` overrides the form setting for that line only.

The job resolves every identifier, fetches the matching Alma records in bulk, generates the MARC ArchivesSpace would push, and compares them. What comes out is a JSON report with:

* **Per-field loss counts** — the headline the report exists for, e.g. *"MARC 035: 1128 of 1200 records would lose data in this field."* Fields are counted separately for records that would lose the field entirely, lose some instances of it, have it changed, or gain it.
* **Recommended additions to `alma_marc_fields_to_preserve`**, derived from those loss counts. This is the practical payoff: the report tells you which fields to protect before you push anything.
* **Per-record detail**, down to individual subfields and to positions within the 008 and leader.
* **Error rows** for anything that could not be audited — an identifier that matched no resource, matched more than one, had no MMS ID, or that Alma rejected. These are first-class rows in the report, not silent omissions, so the counts always add up.

The report page shows the summary, lets you drill into individual records, and offers the full JSON as a download.

### What is deliberately left out of the headline

Control fields — the leader and the 001, 003, 005 and most of the 008 — differ between Alma and ArchivesSpace on essentially every record, for mechanical reasons that have nothing to do with catalogue content. Counting them would bury the differences you actually care about. They are excluded from the summary tables and the report page says so explicitly; **the differences themselves are still recorded in full in the JSON**, so nothing is hidden, and you can change the list with `AppConfig[:alma_audit_ignored_tags]`.

## Running the bulk update

From the report page, "Run the bulk update" creates an **Alma Bulk Update** job that carries the audit's ID with it. The update works from the audit's resolved list, so the records it touches are exactly the records you reviewed.

Safety rails, all on by default:

* **A prior audit is required.** Skipping it needs an explicit override on the form.
* **Dry run** defaults to on, so the first run of any list does everything except send the PUTs.
* **Staleness checks.** Between the audit and the update, someone may have edited the record in Alma or in ArchivesSpace. The job compares Alma's 005 and the ArchivesSpace `lock_version` against the values captured at audit time, and additionally passes Alma's own `stale_version_check` on the PUT, so Alma itself rejects a record that moved underneath us. Stale records are held back and reported rather than overwritten.
* **The failsafe copy.** Every Alma MARC record fetched during the audit is stored verbatim in the report, and the update job takes a fresh snapshot of each record immediately before overwriting it. If an update turns out to have been a mistake, the previous state of the catalogue record is on disk, not merely in Alma's history.
* **Network Zone records are held back by default.** If a bib is an Institution Zone record linked to a shared Network Zone record, a PUT replaces only the local fields, so a straightforward "Alma minus ArchivesSpace" reading of the diff would overstate the loss. Rather than guess, the audit flags those records and the update skips them unless you opt in. If you know your bibs are IZ-only, you can turn this off.

## Rate limiting

The Alma API is governed at roughly 25 requests per second across your whole institution, and there is a daily call quota that this plugin shares with every other Alma integration on campus. An audit of a few thousand records could comfortably starve all of them, so:

* requests pass through a shared token bucket, defaulting to 19/second across the whole ArchivesSpace process;
* bibs are fetched **100 at a time** via Alma's multi-ID `GET /bibs`, which turns a 1,200-record audit into about 12 calls rather than 1,200 — the audit is essentially free against your quota, and only the update (one PUT per record, unavoidable) is expensive;
* a `PER_SECOND_THRESHOLD` rejection backs off with jitter and retries;
* the remaining-calls figure Alma returns on every response is watched, and the job stops cleanly if it falls below your configured floor;
* a `DAILY_THRESHOLD` rejection stops the job with a resumable checkpoint. It deliberately does **not** sleep until midnight: ArchivesSpace runs two job threads by default, and a job that sleeps for hours would occupy half your job capacity.

The API key is sent in an `Authorization` header rather than in the query string, so it stays out of Alma's logs and out of any proxy's.

# Permissions

Running a bulk update rewrites catalogue records for hundreds or thousands of titles at once, so it is worth a moment's thought about who can do it. Three options, in rough order of how much they worry me:

* **Reuse `update_resource_record`.** Convenient, and wrong: it means anyone who can edit a finding aid can also rewrite the library catalogue in bulk. Those are not the same trust level.
* **Reuse `manage_repository`.** Narrow enough to be safe, but it conflates catalogue-push authority with unrelated repository administration, and it cannot be granted on its own.
* **A dedicated permission, `update_alma_records`.** Says what it means, and can be reasoned about independently.

This plugin takes the third option, and by default registers it as a *derived* permission implied by `manage_repository`. That gives you a meaningful, self-documenting permission code with **no database footprint at all** — ArchivesSpace resolves derived permissions in memory, so nothing is written to the `permission` table and uninstalling the plugin leaves nothing behind. The trade-off is that it travels with `manage_repository` and cannot be granted separately.

If you want to grant bulk-update rights to a group that should *not* have full repository management, set `AppConfig[:alma_standalone_permission] = true`. The permission is then created as a real row and appears in the group edit form like any other. See the next section for what that writes and how to undo it.

# Database footprint

Short version: **this plugin adds no migrations, no tables and no columns, and in its default configuration writes no permanent rows of its own.**

* **No schema changes.** There are no migrations in this plugin. Nothing is altered about the ArchivesSpace database structure, so there is nothing to roll back and no schema state to get stuck in. Uninstalling is removing the plugin directory and its `AppConfig[:plugins]` entry.
* **The permission, by default, touches nothing.** `Permission.define(..., :implied_by => 'manage_repository')` returns before it reaches the database; ArchivesSpace keeps derived permissions in an in-process list rebuilt at every boot. Remove the plugin and the permission ceases to exist. There is no residue and no cleanup step.
* **The permission, if you opt in to `:alma_standalone_permission`,** inserts a single row into `permission` (find-or-create, so restarts do not duplicate it), and one row in `group_permission` for each group you grant it to. If you later remove the plugin, an orphaned permission row is harmless — ArchivesSpace treats an unknown permission code as "denied" and does not error on it — but if you want it gone, note that `group_permission` has no `ON DELETE CASCADE`, so delete the grants first:

  ```sql
  DELETE FROM group_permission
   WHERE permission_id = (SELECT id FROM permission WHERE permission_code = 'update_alma_records');
  DELETE FROM permission WHERE permission_code = 'update_alma_records';
  ```

  Take a backup first, as with any manual statement against a production database.
* **Job runs are ordinary ArchivesSpace data.** Audits and updates create rows in `job` and `job_input_file` through the standard job-creation path, exactly as a CSV import or a report does. They are deleted the same way, through the ArchivesSpace interface.
* **Retention is off unless you turn it on.** With `AppConfig[:alma_audit_report_retention_days]` set, a sweep runs when a job starts. It only considers this plugin's own job types, only finished ones, and it deletes **files**, never job history rows — so the record that an audit happened, who ran it, and what it found in summary survives even after the full JSON is aged out. ArchivesSpace's own job deletion leaves output files on disk, which is why this cleanup exists at all.
* **The bulk update never writes to `resource` or `user_defined`.** Unlike the single-record push, which can create a new Alma bib and then write its MMS ID back to the Resource, the bulk update refuses to act on a record with no MMS ID and records it as an error instead. Its only writes are to Alma.

The risk I would actually keep an eye on is not the database: it is Alma. The database changes here are nil-to-trivial and reversible with a two-line SQL statement. Overwriting catalogue records is neither, which is why the audit, the dry run, the staleness checks and the stored MARC snapshots are all on by default.

# Development

The shared library under `lib/` is plain Ruby with no ArchivesSpace dependencies, so it can be tested without a running instance:

```
BUNDLE_GEMFILE=spec/Gemfile bundle install
BUNDLE_GEMFILE=spec/Gemfile bundle exec rspec
```

The test manifest is `spec/Gemfile`, not a `Gemfile` in the plugin root, and that is deliberate. ArchivesSpace evaluates every `plugins/*/Gemfile` into its own bundle when it boots, so a Gemfile here is not a private development file: its version constraints are resolved together with ArchivesSpace's. Declaring a gem that ArchivesSpace already pins, at a different version, makes Bundler refuse to resolve and ArchivesSpace refuse to start — with a stack trace that points at ArchivesSpace's Gemfile rather than at the plugin. CI fails the build if a `Gemfile` reappears in the plugin root. Only add one if the plugin genuinely needs a gem at runtime, and then pin it compatibly with the ArchivesSpace release you are targeting.

The suite covers the parts where a quiet mistake would be expensive: the MARC diff engine, the field preserver, the rate limiter, Alma error parsing, identifier parsing, and the report builder. It runs on every push via GitHub Actions.

## A local ArchivesSpace to test against

The unit tests deliberately do not need ArchivesSpace, but the job runners, the forms and the report page do. [`docker/`](docker/README.md) contains a Docker Compose stack that runs ArchivesSpace, MySQL and Solr locally with this plugin mounted, so you can test against a copy of a real repository rather than an empty database.

```
cd docker
cp .env.example .env
cp config/config.rb.example config/config.rb   # edit: Alma sandbox API key
```

Then copy a database dump and, optionally, a Solr index down from an existing server into `docker/data/` — [`docker/README.md`](docker/README.md) says which directories to take and where to put them — and start:

```
./scripts/check-data.sh    # confirms the files are where they should be
./scripts/up.sh --fresh
```

See [`docker/README.md`](docker/README.md) for the full walkthrough, including the Apple Silicon notes.

# Using the integrations

The integrations may be accessed via the repository menu:

![Access the plugin by clicking on the repository menu dropdown. Hover over "Plugins," then select "Alma Integrations."](docs/plugin_menu.png)

The plugin consists of a search form with two fields: the Resource, a linker where the user is prompted to search for a collection whose metadata in Alma they wish to view, and the Record Type, where the user is prompted to select the type of metadata with which they wish to work (either BIBs, Holdings, or Items). Once the resource and record type are selected, clicking the “Submit” button will initiate an Alma search.

![The Alma Integrations plugin index. Two fields are required: the Resource to be searched, and the Alma record type whose data the user would like to see.](docs/plugin_index.png)

Depending on the record type selected, the plugin will query the Alma API for either BIB, Holding, or Item metadata using the MMS ID provided in the linked Resource record. If no MMS ID is provided, an alert to that effect. will appear in the search results view.

## Resource BIBs

If the user selects BIBs as their record type, the plugin will display a side-by-side view of the MARC record that will be pushed to Alma (the ASpace-generated record with Alma fields preserved, as described above) and the MARC record currently present in Alma. If there is no MMS ID present, the plugin will display a message to that effect in the Alma view.

![The BIBs view in the Alma Integrations plugin. Displays side-by-side MARC representations of the linked Resource, one generated by the ArchivesSpace API and one as it is recorded in Alma.](docs/plugin_bibs.png)

If the user wishes to push changes from ArchivesSpace to Alma, e.g. if Resource-level metadata was added or updated in ArchivesSpace, clicking the “Push to Alma” button will overwrite the existing Alma MARC record with the MARC record generated by the ArchivesSpace API. If no MARC record is present in Alma for a Resource, clicking this button will create a new MARC record in Alma, then add that record’s MMS ID to the linked ArchivesSpace Resource. (Note that Alma's default is to suppress new records created via the API; for now you will need to use the Metadata Editor to un-suppress the record manually if you would like it published to Primo.)

Currently there is no way to pull changes made in Alma back into ArchivesSpace.

## Resource Holdings

If the user selects Holdings as their record type, the plugin searches for all holdings records attached to the BIB with the MMS ID provided by the user in the search form. It cross-checks the results against the list of location codes provided in the `alma_holdings_codes` setting of the ArchivesSpace instance's `config.rb` file, and returns a list of the holdings found via the API, including the record ID, location code, and location name for each.

To add new holdings, the user may select the desired holdings location from the drop-down list found in the Add New Holdings sub-record form. This list contains the location codes set in the `alma_holdings_codes` configuration setting which were not found in the holdings search. Upon selecting a location and clicking the “Add” button, ArchivesSpace will attempt to post the new holdings to Alma, then return to the plugin index page. If successful, the new Holdings ID will be returned; if not, the plugin will return the error message returned by the Alma API.

![Holdings results from the Alma Integrations plugin](docs/plugin_holdings.png)

## Resource Items

Currently a search for the Item record type returns a list of items attached to the BIB record with the MMS ID found on the linked Resource record. The plugin displays fields that are used by Special Collections and Archives at DU for inventory control and container management. There is no way to synchronize item-level metadata between ArchivesSpace and Alma in any way at this time.

![Item results from the Alma Integrations plugin](docs/plugin_items.png)

# Future Development

Requests for new features and bug fixes can be filed as [Issues](https://github.com/duspeccoll/alma_integrations/issues).

# In Conclusion

Feel free to kick the tires on this against your own ArchivesSpace/Alma environment and let me know how it works. Questions, comments, and/or pull requests welcome! E-mail: kmc35 [at] psu.edu.
