using System.Diagnostics;
using OpenTelemetry.Logs;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

// RatingApi — 05-telescope-vs-microscope variant.
//
// Unchanged in behaviour. The only difference from the baseline is that the
// step-by-step arithmetic of the premium and the risk score is now emitted as
// DEBUG TIER telemetry: it explains the inside of one pure function and is
// worthless to anybody looking at the system as a whole.
//
// The result (risk score, base premium) stays on the span, because that IS a
// fact about the system. The factors that produced it do not.
var builder = WebApplication.CreateBuilder(args);

const string ServiceName = "rating-api";

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
    // Required for the tier marker — see QuoteApi/Program.cs.
    o.IncludeScopes = true;
    o.ParseStateValues = true;
    o.AddOtlpExporter();
});

var app = builder.Build();

app.MapGet("/healthz", () => Results.Ok("ok"));

app.MapPost("/rate", (RateRequest req, ILogger<Program> logger) =>
{
    var basePremium = (req.VehicleType?.ToLowerInvariant()) switch
    {
        "small" => 300m,
        "medium" => 450m,
        "suv" => 600m,
        _ => 500m
    };

    var ageFactor = req.DriverAge < 25 ? 1.4m : req.DriverAge > 70 ? 1.3m : 1.0m;
    var regionFactor = (req.Region?.ToLowerInvariant()) switch
    {
        "urban" => 1.2m,
        "rural" => 0.9m,
        _ => 1.0m
    };
    var coverageFactor =
        string.Equals(req.CoverageLevel, "comprehensive", StringComparison.OrdinalIgnoreCase)
            ? 1.5m : 1.0m;

    var premium = decimal.Round(basePremium * ageFactor * regionFactor * coverageFactor, 2);

    var risk = Math.Clamp(
        (int)((ageFactor - 0.9m) * 40 + (regionFactor - 0.9m) * 30 + (coverageFactor - 1.0m) * 20) + 20,
        0, 100);

    // SYSTEM TIER. Business attributes on the auto-created server span — the
    // wide event. Outcomes only, no intermediate arithmetic.
    var span = Activity.Current;
    span?.SetTag("insurance.vehicle_type", req.VehicleType);
    span?.SetTag("insurance.driver_age", req.DriverAge);
    span?.SetTag("insurance.region", req.Region);
    span?.SetTag("insurance.coverage_level", req.CoverageLevel);
    span?.SetTag("insurance.risk_score", risk);
    span?.SetTag("insurance.base_premium", (double)premium);

    // DEBUG TIER. How the two numbers above came about. Useful for exactly one
    // question ("why is this premium what it is?") and useless for every
    // system-level question, so it is routed away from ClickHouse.
    using (logger.BeginScope(TelemetryTier.Debug))
    {
        logger.LogDebug(
            "Premium factors: base={Base} age={AgeFactor} region={RegionFactor} coverage={CoverageFactor} -> premium={Premium}",
            basePremium, ageFactor, regionFactor, coverageFactor, premium);
        logger.LogDebug(
            "Risk formula: (age {AgeFactor} - 0.9)*40 + (region {RegionFactor} - 0.9)*30 + (coverage {CoverageFactor} - 1.0)*20 + 20 -> risk={Risk}",
            ageFactor, regionFactor, coverageFactor, risk);
    }

    logger.LogInformation(
        "Rated {VehicleType} age {DriverAge} in {Region} ({Coverage}): risk={Risk} basePremium={Premium}",
        req.VehicleType, req.DriverAge, req.Region, req.CoverageLevel, risk, premium);

    return Results.Ok(new RateResponse(risk, premium));
});

app.Run();

record RateRequest(string VehicleType, int DriverAge, string Region, string CoverageLevel);
record RateResponse(int RiskScore, decimal BasePremium);

// See QuoteApi/Program.cs for why the marker is an attribute and not a severity.
static class TelemetryTier
{
    public static readonly Dictionary<string, object> Debug = new()
    {
        ["telemetry.tier"] = "debug"
    };
}
