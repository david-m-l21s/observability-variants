using System.Diagnostics;
using System.Net.Http.Json;

// QuoteApi — backend orchestrator. Validates the request, calls RatingApi over
// HTTP for a base premium + risk score, applies tax + a decision rule, and
// returns the quote. In-memory only.
//
// 02-runtime-injection variant: NO in-code OpenTelemetry SDK — the OTel Operator
// injects the .NET agent at runtime. Business attributes are still added to the
// current Activity via the BCL System.Diagnostics API.
var builder = WebApplication.CreateBuilder(args);

// Downstream RatingApi. Base URL from config (Services__RatingBaseUrl in the
// manifest); default resolves to the in-namespace service.
builder.Services.AddHttpClient("rating", c =>
    c.BaseAddress = new Uri(
        builder.Configuration["Services:RatingBaseUrl"] ?? "http://rating-api:8080"));

var app = builder.Build();

app.MapGet("/healthz", () => Results.Ok("ok"));

app.MapPost("/quotes", async (QuoteRequest req, IHttpClientFactory httpFactory, ILogger<Program> logger) =>
{
    var span = Activity.Current;
    span?.SetTag("insurance.customer_id", req.CustomerId);
    span?.SetTag("insurance.vehicle_type", req.VehicleType);
    span?.SetTag("insurance.driver_age", req.DriverAge);
    span?.SetTag("insurance.region", req.Region);
    span?.SetTag("insurance.coverage_level", req.CoverageLevel);

    var quoteId = Guid.NewGuid().ToString("N");
    span?.SetTag("insurance.quote_id", quoteId);

    // Simple eligibility rule handled here in the backend.
    if (req.DriverAge < 18)
    {
        span?.SetTag("insurance.decision", "Rejected");
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
