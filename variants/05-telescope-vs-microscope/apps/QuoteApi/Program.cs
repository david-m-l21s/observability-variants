using System.Diagnostics;
using System.Net.Http.Json;
using OpenTelemetry.Logs;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

// QuoteApi — 05-telescope-vs-microscope variant.
//
// Same service as the baseline, with one idea added: every statement this
// service emits is deliberately assigned to one of two tiers.
//
//   System tier (telescope)   -> span attributes and INFO/WARN/ERROR logs.
//                                Statements about the SYSTEM. Land in
//                                ClickHouse. Low cardinality, kept long,
//                                queryable across all services.
//
//   Debug tier (microscope)   -> everything inside a TelemetryTier.Debug
//                                scope. Statements about the inside of ONE
//                                function. Land in Loki only, short
//                                retention, never queried by a dashboard.
//
// The routing happens in the collector, not here. This service only has to
// say which tier a statement belongs to. See k8s/20-otel-collector.yaml.
var builder = WebApplication.CreateBuilder(args);

const string ServiceName = "quote-api";

// Which eligibility rules this pod runs.
//   v1  the correct set: urban, rural and suburban are all licensed.
//   v2  the regression: suburban was silently dropped.
//
// v2 is the whole point of the demo. It answers HTTP 200, throws no
// exception, is not slower, and consumes no more memory. Nothing a
// status-code-and-resources dashboard watches changes. Only the business
// decision changes. Flip it at runtime with scripts/07-trigger-defect.sh.
var ruleset = builder.Configuration["QUOTE_ELIGIBILITY_RULESET"] ?? "v1";
var licensedRegions = ruleset == "v2"
    ? new[] { "urban", "rural" }
    : new[] { "urban", "rural", "suburban" };

builder.Services.AddHttpClient("rating", c =>
    c.BaseAddress = new Uri(
        builder.Configuration["Services:RatingBaseUrl"] ?? "http://rating-api:8080"));

builder.Services.AddOpenTelemetry()
    .ConfigureResource(r => r.AddService(ServiceName))
    .WithTracing(t => t
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddOtlpExporter())
    .WithMetrics(m => m
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddRuntimeInstrumentation()
        .AddOtlpExporter());

builder.Logging.AddOpenTelemetry(o =>
{
    o.SetResourceBuilder(ResourceBuilder.CreateDefault().AddService(ServiceName));
    o.IncludeFormattedMessage = true;
    // Required for the tier marker: with IncludeScopes the key/value pairs of
    // an ILogger scope are exported as OTLP log-record attributes, which is
    // what the collector filters on.
    o.IncludeScopes = true;
    o.ParseStateValues = true;
    o.AddOtlpExporter();
});

var app = builder.Build();

app.MapGet("/healthz", () => Results.Ok("ok"));

app.MapPost("/quotes", async (QuoteRequest req, IHttpClientFactory httpFactory, ILogger<Program> logger) =>
{
    var span = Activity.Current;

    // SYSTEM TIER. Business context on the span: this is the wide event.
    span?.SetTag("insurance.customer_id", req.CustomerId);
    span?.SetTag("insurance.vehicle_type", req.VehicleType);
    span?.SetTag("insurance.driver_age", req.DriverAge);
    span?.SetTag("insurance.region", req.Region);
    span?.SetTag("insurance.coverage_level", req.CoverageLevel);

    var quoteId = Guid.NewGuid().ToString("N");
    span?.SetTag("insurance.quote_id", quoteId);

    // SYSTEM TIER. Which rule version decided this request. Two values, so it
    // costs nothing and it lets the telescope localize the problem to a
    // configuration change rather than to a customer.
    span?.SetTag("quote.ruleset", ruleset);

    var reasons = new List<string>();
    if (req.DriverAge < 18)
        reasons.Add("Driver must be at least 18.");
    if (!licensedRegions.Contains(req.Region ?? string.Empty, StringComparer.OrdinalIgnoreCase))
        reasons.Add($"Region '{req.Region}' is not licensed under ruleset {ruleset}.");

    // DEBUG TIER. Free text, high cardinality, only meaningful to somebody
    // reading this method. It explains HOW the decision below was reached.
    // This is what must never reach the wide event store.
    using (logger.BeginScope(TelemetryTier.Debug))
    {
        logger.LogDebug("Ruleset {Ruleset} licenses regions: {Regions}",
            ruleset, string.Join(",", licensedRegions));
        logger.LogDebug("Quote {QuoteId} eligibility reasons: {Reasons}",
            quoteId, reasons.Count == 0 ? "none" : string.Join(" | ", reasons));
    }

    if (reasons.Count > 0)
    {
        // SYSTEM TIER. A rejection is a normal business outcome, not an
        // incident, so it is a span attribute and NOT a log line. The
        // baseline logs a Warning here; that Warning is deliberately gone.
        span?.SetTag("insurance.decision", "Rejected");
        return Results.Ok(new QuoteResponse(quoteId, 0m, "Rejected", 0));
    }

    var client = httpFactory.CreateClient("rating");
    var rateResp = await client.PostAsJsonAsync("/rate",
        new RateRequest(req.VehicleType, req.DriverAge, req.Region, req.CoverageLevel));

    if (!rateResp.IsSuccessStatusCode)
    {
        // SYSTEM TIER. A real failure. The span status carries it, so the
        // telescope sees it without any log at all; the Error log adds the
        // detail and, being at Error severity, still goes to ClickHouse.
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

    using (logger.BeginScope(TelemetryTier.Debug))
    {
        logger.LogDebug("Quote {QuoteId} premium build-up: base={Base} tax=19% final={Final}",
            quoteId, rate.BasePremium, finalPremium);
    }

    logger.LogInformation(
        "Quote {QuoteId} for {CustomerId}: {Decision} finalPremium={Premium} risk={Risk}",
        quoteId, req.CustomerId, decision, finalPremium, rate.RiskScore);

    return Results.Ok(new QuoteResponse(quoteId, finalPremium, decision, rate.RiskScore));
});

app.Run();

record QuoteRequest(string CustomerId, string VehicleType, int DriverAge, string Region, string CoverageLevel);
record RateRequest(string VehicleType, int DriverAge, string Region, string CoverageLevel);
record RateResponse(int RiskScore, decimal BasePremium);
record QuoteResponse(string QuoteId, decimal FinalPremium, string Decision, int RiskScore);

// The tier marker. One scope, one attribute, no other machinery.
//
// Severity is deliberately NOT used as the marker here: severity answers "how
// bad is this", not "who is this for". Keeping the two axes separate means a
// developer detail can hang off an error, and a business-relevant fact can be
// logged at Debug level without leaving the system store. The collector still
// treats plain Debug/Trace records (for example framework noise, which carries
// no marker) as debug tier as well, so nothing has to be retrofitted.
static class TelemetryTier
{
    public static readonly Dictionary<string, object> Debug = new()
    {
        ["telemetry.tier"] = "debug"
    };
}
