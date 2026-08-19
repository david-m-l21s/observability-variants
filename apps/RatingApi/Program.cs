using System.Diagnostics;
using OpenTelemetry.Logs;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

// RatingApi — downstream calculation service. Pure function of the request:
// given vehicle + driver + region + coverage, return a risk score and base
// premium. No state, no dependencies. QuoteApi calls it over HTTP.
var builder = WebApplication.CreateBuilder(args);

const string ServiceName = "rating-api";

// OpenTelemetry: auto-instrumentation for inbound HTTP + runtime metrics.
// The OTLP endpoint comes from OTEL_EXPORTER_OTLP_ENDPOINT (set in the manifest),
// so nothing here is tied to a namespace or cluster.
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
    o.IncludeScopes = true;
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

    // Business attributes on the auto-created server span -> a "wide event".
    var span = Activity.Current;
    span?.SetTag("insurance.vehicle_type", req.VehicleType);
    span?.SetTag("insurance.driver_age", req.DriverAge);
    span?.SetTag("insurance.region", req.Region);
    span?.SetTag("insurance.coverage_level", req.CoverageLevel);
    span?.SetTag("insurance.risk_score", risk);
    span?.SetTag("insurance.base_premium", (double)premium);

    logger.LogInformation(
        "Rated {VehicleType} age {DriverAge} in {Region} ({Coverage}): risk={Risk} basePremium={Premium}",
        req.VehicleType, req.DriverAge, req.Region, req.CoverageLevel, risk, premium);

    return Results.Ok(new RateResponse(risk, premium));
});

app.Run();

record RateRequest(string VehicleType, int DriverAge, string Region, string CoverageLevel);
record RateResponse(int RiskScore, decimal BasePremium);
