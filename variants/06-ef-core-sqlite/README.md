# 06-ef-core-sqlite — database spans from Entity Framework Core

The same three services as every other variant — `QuoteWeb → QuoteApi → RatingApi` —
but `QuoteApi` now stores every quote through **Entity Framework Core** and can
read them back. The question this variant answers:

> The baseline registers only ASP.NET Core and HttpClient instrumentation. What
> does it take to see the database work, what does the provider-agnostic EF Core
> instrumentation actually emit, and what should we switch off?

The database is **SQLite in in-memory mode**, inside the `quote-api` process. No
database server, no extra pod. It is a stepping stone: the same code and the same
instrumentation later run against SQL Server or PostgreSQL by changing the
provider (`UseSqlite` → `UseSqlServer` / `UseNpgsql`).

## Why SQLite and not EF Core's InMemory provider

EF Core's `InMemory` provider is **not relational**. It never builds or executes a
`DbCommand`, so the `Microsoft.EntityFrameworkCore.Database.Command.*` diagnostic
events never fire, and the EF instrumentation, which listens to exactly those
events, produces **zero spans**. It would reproduce the "nothing appears" problem,
not solve it.

SQLite is relational: EF generates SQL, opens a connection, executes commands.
The instrumentation sees all of that. `Mode=Memory;Cache=Shared` with one
connection kept open for the lifetime of the process makes it an in-memory
database that several `DbContext` instances share. The data is gone when the pod
restarts. That is fine here.

## What differs from the baseline

1. **`QuoteApi` is rebuilt as `quote-api-ef:v1`** (`apps/QuoteApi/`). `rating-api:v1`
   and `quote-web:v1` are the baseline images, unchanged.
2. **All OpenTelemetry packages move from 1.9.0 to 1.19.x** in that image. Required:
   the EF instrumentation `1.19.1-beta.1` needs
   `OpenTelemetry.Api.ProviderBuilderExtensions >= 1.19.1`.
3. **Three new endpoints' worth of DB work:**

   | Endpoint | Database work | Expected span name |
   | --- | --- | --- |
   | `POST /quotes` (existing) | one `INSERT`, also for `Rejected` quotes | `INSERT quotes` |
   | `GET /quotes/{quoteId}` | `SELECT` by primary key | `SELECT quotes` |
   | `GET /customers/{customerId}/quotes?limit=` | `SELECT` by index, `ORDER BY … LIMIT` | `SELECT quotes` |

4. **One environment variable switches the instrumentation**, in the same image:
   `DB_INSTRUMENTATION=efcore` (default) or `none`. The mode is also a resource
   attribute, `app.db_instrumentation`, on every span and log of `quote-api`, so a
   `none` run and an `efcore` run can be compared side by side in the same
   ClickHouse database.
5. **The collector is the baseline's** plus the `/healthz` drop filter from
   variants 04/05, exporting to its own database **`ef_core_sqlite`**. Nothing
   clever on purpose: this variant tests an app-side change.

## The registration, and the line that does not work

```csharp
.WithTracing(t =>
{
    t.AddAspNetCoreInstrumentation();
    t.AddHttpClientInstrumentation();
    if (dbInstrumentation == "efcore")
        t.AddEntityFrameworkCoreInstrumentation();   // package: OpenTelemetry.Instrumentation.EntityFrameworkCore (prerelease)
    t.AddOtlpExporter();
})
```

`t.AddSource("Microsoft.EntityFrameworkCore")` would compile and do nothing.
That name belongs to a `DiagnosticListener`, not an `ActivitySource`. EF Core
publishes events to the listener. It starts no activities of its own. The
instrumentation package subscribes to those events and starts spans from its
**own** `ActivitySource`. Section 1 of `08-inspect.sh` prints that source's name
as the `ScopeName`.

## Three things we found while building this

These correct or sharpen what we had worked out in conversation beforehand.

**1. The EF package emits the *old* database conventions by default.** Unless
`OTEL_SEMCONV_STABILITY_OPT_IN=database` is set, it writes `db.system`, `db.name`
and `db.statement`, and **every span is named after the database** — `main` for
SQLite. So "SELECT", "INSERT" and "CREATE TABLE" all look alike in a span list.
With the opt-in it writes `db.system.name`, `db.namespace`, `db.query.text`,
`db.query.summary`, and the span name becomes the summary (`INSERT quotes`). The
manifest sets the opt-in. `database/dup` writes both sets, which is a migration aid
that doubles the width. The attribute list we collected earlier
(`db.response.status_code`, `db.stored_procedure.name`, …) was the **SqlClient**
package's. The EF package is a subset: for plain text commands it sets no
`db.operation.name`. For SQLite, `server.address` is either absent or meaningless:
the package derives it by parsing the connection's data source as if it were a
server name, and our data source is the in-memory database name `quotes`.

**2. The query text is sanitized.** With the new conventions the instrumentation
runs the SQL through its sanitizer and replaces literals with `?` (for providers it
recognizes as SQL-like; SQLite should be one — section 4 of `08-inspect.sh` shows it). EF sends
parameters anyway (`@p0`, `@__quoteId_0`), so the stored text carries names, not
values. The parameter **values** are a separate, opt-in switch:
`OTEL_DOTNET_EXPERIMENTAL_EFCORE_ENABLE_TRACE_DB_QUERY_PARAMETERS`. It must stay
unset for an insurer, because the parameters are where the personal data is.
`08-inspect.sh` section 3 is a leak check for it.

**3. EF Core also *logs* every command.** Category
`Microsoft.EntityFrameworkCore.Database.Command`, level `Information`, SQL text in
the message. With a span per command, that log line is the same fact stored a
second time, and the log copy is not sanitized. The manifest sets that category to
`Warning`: failures stay, the per-command chatter goes. `07-switch.sh ef-logs`
turns it back on so the duplication can be measured.

## Two things to keep in mind when reading the numbers

- **A db span covers executing the command, not reading the result.** From the
  package documentation: the span measures the time the connection takes to
  execute the command. It does not include enumerating the result set. With
  SQLite in memory, both are tiny. Against a real database with a large result,
  the gap between the request span and its db spans contains real database-related
  work that no span accounts for.
- **Not every db span has a request as its parent.** `EnsureCreated()` at startup
  runs the schema check and the `CREATE` statements before any request exists.
  With `efcore` on, those show up as **root** spans (section 2, column `roots`).

## Prerequisites (shared, run once)

```bash
# from cluster/scripts
./01-create-cluster.sh            # if the kind cluster doesn't exist yet
./02-build-and-load-images.sh     # needed once for rating-api:v1 and quote-web:v1
./03-clickhouse-otel-user.sh      # once, creates otel:otelpass in the Lima VM
```

## Run it

```bash
# from cluster/variants/06-ef-core-sqlite/scripts
./02-build-and-load-images.sh     # builds quote-api-ef:v1
./04-deploy.sh
./05-port-forward.sh              # leave running in its own terminal
```

| What | Where |
| --- | --- |
| quote-web (form, write path) | http://localhost:8086 |
| quote-api (read endpoints) | http://localhost:8087/quotes/{id}, http://localhost:8087/customers/CUST-01/quotes |

The baseline `quote-web` is reused unchanged and does not proxy the new read
endpoints, so `quote-api` is forwarded directly. Reads therefore start their trace
at `quote-api`.

## The walkthrough

**1. The starting point: nothing appears.**

```bash
./07-switch.sh none               # restarts quote-api; restart 05-port-forward.sh too
./06-generate-load.sh
./08-inspect.sh 10
```

Section 1 shows no EF scope. Section 5 shows `db_spans_per_req = 0`. The database
time is still in there, inside `req_ms`, but nothing names it.

**2. The fix.**

```bash
./07-switch.sh efcore
./06-generate-load.sh
./08-inspect.sh 10
```

Expect: section 1 gains a `Client` row for the EF scope. Section 2 lists
`INSERT quotes` (one per write) and `SELECT quotes` (one per read, including the
404 miss), plus a few root spans from startup. Section 3 lists the attribute keys
and no `db.query.parameter.*`. Section 5 shows exactly one db span per request.

**3. What the conventions switch changes.**

```bash
./07-switch.sh old-semconv
./06-generate-load.sh 20
./08-inspect.sh 5
./07-switch.sh new-semconv
```

Expect every db span named `main`, `db.statement` instead of `db.query.text`, and
no `db.query.summary`. That is what you get if you only add the package.

**4. The duplicate log.**

```bash
./07-switch.sh ef-logs
./06-generate-load.sh 20
./08-inspect.sh 5                 # section 6
./07-switch.sh ef-logs-off
```

Expect one `Microsoft.EntityFrameworkCore.Database.Command` record per db span.

Every switch restarts the pod, so the in-memory database starts empty again, and
the `quote-api` port-forward dies with the old pod. Restart `05-port-forward.sh`
after each switch.

## Not verified yet

Written without network access to nuget.org, so **neither the build nor any run has
happened**. In particular:

- `dotnet publish` inside the Docker build has not run. Package versions were
  taken from nuget.org on 2026-09-28: EF Core Sqlite 9.0.20, OpenTelemetry core
  1.19.1, AspNetCore/Http/Runtime instrumentation 1.19.0, EF instrumentation
  1.19.1-beta.1.
- The `08-inspect.sh` SQL was run against a hand-built table with the exporter's
  column names (chdb), not against data from the exporter.
- Span names and attribute sets above come from reading the instrumentation's
  source (`EntityFrameworkDiagnosticListener.cs`,
  `DatabaseSemanticConventionHelper.cs`), not from observed output.
- Watch on first run: Microsoft.Data.Sqlite retries on `SQLITE_LOCKED` until the
  command timeout, which should cover concurrent writers on a shared-cache
  in-memory database. `06-generate-load.sh` is sequential, so it will not show a
  problem either way.
