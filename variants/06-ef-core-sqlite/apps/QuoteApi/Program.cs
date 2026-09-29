using System.Diagnostics;
using System.Net.Http.Json;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using OpenTelemetry.Logs;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

// QuoteApi — variant 06-ef-core-sqlite.
//
// Same orchestration as the baseline (validate -> call RatingApi -> tax +
// decision), plus ONE new thing: every quote is persisted through Entity
// Framework Core, and can be read back.
//
//   POST /quotes                         INSERT one row per quote
//   GET  /quotes/{quoteId}               SELECT by primary key
//   GET  /customers/{customerId}/quotes  SELECT by indexed column, newest first
//
// The database is SQLite in in-memory mode. Not EF's InMemory provider: that
// one is not relational, never executes a DbCommand, and so produces no spans
// at all. SQLite is relational, runs inside this process, and needs no server.
//
// What is being tested: does the provider-agnostic EF Core instrumentation
// (OpenTelemetry.Instrumentation.EntityFrameworkCore, prerelease) give us
// usable database spans? DB_INSTRUMENTATION switches it on and off in the SAME
// image, so the "before" and "after" can be compared in the same ClickHouse
// database:
//
//   DB_INSTRUMENTATION=efcore  (default)  AddEntityFrameworkCoreInstrumentation()
//   DB_INSTRUMENTATION=none               only ASP.NET Core + HttpClient, as in
//                                         the baseline -> DB work is invisible
var builder = WebApplication.CreateBuilder(args);

const string ServiceName = "quote-api";

var dbInstrumentation = (builder.Configuration["DB_INSTRUMENTATION"] ?? "efcore")
    .Trim().ToLowerInvariant();
if (dbInstrumentation is not ("efcore" or "none"))
    throw new InvalidOperationException(
        $"DB_INSTRUMENTATION must be 'efcore' or 'none', got '{dbInstrumentation}'.");

// --- database ---------------------------------------------------------------
// A named, shared-cache in-memory database. It exists for as long as at least
// one connection to it is open, so one connection is opened here and kept open
// for the lifetime of the process. Every DbContext opens its own connection to
// the same named database, as it would against a real server.
// Consequence: the data is gone when the pod restarts. That is fine here.
const string ConnectionString = "Data Source=quotes;Mode=Memory;Cache=Shared";
var keepAlive = new SqliteConnection(ConnectionString);
keepAlive.Open();
builder.Services.AddSingleton(keepAlive); // held for the process lifetime (DI does not dispose instances it did not create)

builder.Services.AddDbContext<QuoteDb>(o => o.UseSqlite(ConnectionString));

builder.Services.AddHttpClient("rating", c =>
    c.BaseAddress = new Uri(
        builder.Configuration["Services:RatingBaseUrl"] ?? "http://rating-api:8080"));

// --- telemetry --------------------------------------------------------------
// app.db_instrumentation is a RESOURCE attribute, so every span, log and metric
// of this pod says which mode produced it. That is what lets 08-inspect.sh put
// a "none" run and an "efcore" run side by side.
void ConfigureResource(ResourceBuilder r) => r
    .AddService(ServiceName)
    .AddAttributes(new KeyValuePair<string, object>[]
    {
        new("app.db_instrumentation", dbInstrumentation),
    });

builder.Services.AddOpenTelemetry()
    .ConfigureResource(ConfigureResource)
    .WithTracing(t =>
    {
        t.AddAspNetCoreInstrumentation();
        t.AddHttpClientInstrumentation();

        // The one line this variant is about.
        //
        // NOT t.AddSource("Microsoft.EntityFrameworkCore"): that name is a
        // DiagnosticListener, not an ActivitySource, so AddSource would silently
        // do nothing. The package subscribes to the listener's
        // Database.Command.* events and starts spans from its OWN ActivitySource.
        //
        // Semantic conventions: this package still emits the OLD db attributes
        // (db.system, db.name, db.statement; span name = database name) unless
        // OTEL_SEMCONV_STABILITY_OPT_IN=database is set. The manifest sets it,
        // so we get db.system.name / db.namespace / db.query.text /
        // db.query.summary and span names like "INSERT quotes".
        //
        // Query PARAMETER values stay off (the default). For an insurer the
        // parameters are exactly where personal data is. Do not set
        // OTEL_DOTNET_EXPERIMENTAL_EFCORE_ENABLE_TRACE_DB_QUERY_PARAMETERS.
        if (dbInstrumentation == "efcore")
            t.AddEntityFrameworkCoreInstrumentation();

        t.AddOtlpExporter();
    })
    .WithMetrics(m => m
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddRuntimeInstrumentation()
        .AddOtlpExporter());

builder.Logging.AddOpenTelemetry(o =>
{
    var rb = ResourceBuilder.CreateDefault();
    ConfigureResource(rb);
    o.SetResourceBuilder(rb);
    o.IncludeFormattedMessage = true;
    o.IncludeScopes = true;
    o.AddOtlpExporter();
});

var app = builder.Build();

// Create the schema once at startup. With DB_INSTRUMENTATION=efcore this
// already produces db spans: a few ROOT spans (no parent request) for the
// schema check and the CREATE statements. Expected, and a useful reminder
// that db spans are not only children of HTTP requests.
using (var scope = app.Services.CreateScope())
{
    scope.ServiceProvider.GetRequiredService<QuoteDb>().Database.EnsureCreated();
}

app.MapGet("/healthz", () => Results.Ok("ok"));

app.MapPost("/quotes", async (
    QuoteRequest req, IHttpClientFactory httpFactory, QuoteDb db, ILogger<Program> logger) =>
{
    var span = Activity.Current;
    span?.SetTag("insurance.customer_id", req.CustomerId);
    span?.SetTag("insurance.vehicle_type", req.VehicleType);
    span?.SetTag("insurance.driver_age", req.DriverAge);
    span?.SetTag("insurance.region", req.Region);
    span?.SetTag("insurance.coverage_level", req.CoverageLevel);

    var quoteId = Guid.NewGuid().ToString("N");
    span?.SetTag("insurance.quote_id", quoteId);

    if (req.DriverAge < 18)
    {
        span?.SetTag("insurance.decision", "Rejected");
        await SaveAsync(db, req, quoteId, 0, 0m, 0m, "Rejected");
        logger.LogWarning("Quote {QuoteId} rejected: driver under 18 (age {Age})", quoteId, req.DriverAge);
        return Results.Ok(new QuoteResponse(quoteId, 0m, "Rejected", 0));
    }

    var client = httpFactory.CreateClient("rating");
    var rateResp = await client.PostAsJsonAsync("/rate",
        new RateRequest(req.VehicleType, req.DriverAge, req.Region, req.CoverageLevel));

    if (!rateResp.IsSuccessStatusCode)
    {
        span?.SetStatus(ActivityStatusCode.Error, "Rating service failed");
        logger.LogError("Rating service returned {Status} for quote {QuoteId}",
            (int)rateResp.StatusCode, quoteId);
        return Results.Problem("Rating service unavailable");
    }

    var rate = await rateResp.Content.ReadFromJsonAsync<RateResponse>()
               ?? throw new InvalidOperationException("Empty rating response.");

    var finalPremium = decimal.Round(rate.BasePremium * 1.19m, 2); // + 19% insurance tax
    var decision = rate.RiskScore >= 80 ? "Referred" : "Approved";

    span?.SetTag("insurance.risk_score", rate.RiskScore);
    span?.SetTag("insurance.base_premium", (double)rate.BasePremium);
    span?.SetTag("insurance.final_premium", (double)finalPremium);
    span?.SetTag("insurance.decision", decision);

    await SaveAsync(db, req, quoteId, rate.RiskScore, rate.BasePremium, finalPremium, decision);

    logger.LogInformation(
        "Quote {QuoteId} for {CustomerId}: {Decision} finalPremium={Premium} risk={Risk}",
        quoteId, req.CustomerId, decision, finalPremium, rate.RiskScore);

    return Results.Ok(new QuoteResponse(quoteId, finalPremium, decision, rate.RiskScore));
});

// Read one quote back by primary key.
app.MapGet("/quotes/{quoteId}", async (string quoteId, QuoteDb db) =>
{
    Activity.Current?.SetTag("insurance.quote_id", quoteId);

    var quote = await db.Quotes.AsNoTracking()
        .FirstOrDefaultAsync(q => q.QuoteId == quoteId);

    Activity.Current?.SetTag("insurance.quote_found", quote is not null);
    return quote is null ? Results.NotFound() : Results.Ok(quote);
});

// A customer's quote history, newest first.
app.MapGet("/customers/{customerId}/quotes", async (string customerId, int? limit, QuoteDb db) =>
{
    var take = Math.Clamp(limit ?? 20, 1, 100);
    Activity.Current?.SetTag("insurance.customer_id", customerId);

    var quotes = await db.Quotes.AsNoTracking()
        .Where(q => q.CustomerId == customerId)
        .OrderByDescending(q => q.CreatedAtUtc)
        .Take(take)
        .ToListAsync();

    Activity.Current?.SetTag("insurance.quotes_returned", quotes.Count);
    return Results.Ok(quotes);
});

app.Run();

// One INSERT per quote. Rejected quotes are stored too: "what did we offer this
// customer, and what did we refuse" is exactly what quote history is for.
static async Task SaveAsync(QuoteDb db, QuoteRequest req, string quoteId,
    int riskScore, decimal basePremium, decimal finalPremium, string decision)
{
    db.Quotes.Add(new QuoteRecord
    {
        QuoteId = quoteId,
        CustomerId = req.CustomerId,
        VehicleType = req.VehicleType,
        DriverAge = req.DriverAge,
        Region = req.Region,
        CoverageLevel = req.CoverageLevel,
        RiskScore = riskScore,
        BasePremium = basePremium,
        FinalPremium = finalPremium,
        Decision = decision,
        // DateTime, not DateTimeOffset: the SQLite provider cannot ORDER BY a
        // DateTimeOffset, and the history endpoint orders by this column.
        CreatedAtUtc = DateTime.UtcNow,
    });
    await db.SaveChangesAsync();
}

record QuoteRequest(string CustomerId, string VehicleType, int DriverAge, string Region, string CoverageLevel);
record RateRequest(string VehicleType, int DriverAge, string Region, string CoverageLevel);
record RateResponse(int RiskScore, decimal BasePremium);
record QuoteResponse(string QuoteId, decimal FinalPremium, string Decision, int RiskScore);

class QuoteDb(DbContextOptions<QuoteDb> options) : DbContext(options)
{
    public DbSet<QuoteRecord> Quotes => Set<QuoteRecord>();

    protected override void OnModelCreating(ModelBuilder b)
    {
        var q = b.Entity<QuoteRecord>();
        q.ToTable("quotes");
        q.HasKey(x => x.QuoteId);
        q.HasIndex(x => new { x.CustomerId, x.CreatedAtUtc });
    }
}

class QuoteRecord
{
    public string QuoteId { get; set; } = "";
    public string CustomerId { get; set; } = "";
    public string VehicleType { get; set; } = "";
    public int DriverAge { get; set; }
    public string Region { get; set; } = "";
    public string CoverageLevel { get; set; } = "";
    public int RiskScore { get; set; }
    public decimal BasePremium { get; set; }
    public decimal FinalPremium { get; set; }
    public string Decision { get; set; } = "";
    public DateTime CreatedAtUtc { get; set; }
}
