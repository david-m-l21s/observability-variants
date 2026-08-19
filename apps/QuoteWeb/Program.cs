using System.Net.Http.Json;
using OpenTelemetry.Logs;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

// QuoteWeb — thin frontend / BFF. Serves a small HTML form and proxies its
// submission to QuoteApi. No business logic of its own; it exists to originate
// the trace and give a clickable demo.
var builder = WebApplication.CreateBuilder(args);

const string ServiceName = "quote-web";

builder.Services.AddHttpClient("quote", c =>
    c.BaseAddress = new Uri(
        builder.Configuration["Services:QuoteBaseUrl"] ?? "http://quote-api:8080"));

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
app.MapGet("/", () => Results.Content(Ui.Page, "text/html"));

app.MapPost("/api/quote", async (QuoteRequest req, IHttpClientFactory httpFactory) =>
{
    var client = httpFactory.CreateClient("quote");
    var resp = await client.PostAsJsonAsync("/quotes", req);
    if (!resp.IsSuccessStatusCode)
        return Results.Problem("Quote service unavailable");
    var quote = await resp.Content.ReadFromJsonAsync<QuoteResponse>();
    return Results.Ok(quote);
});

app.Run();

record QuoteRequest(string CustomerId, string VehicleType, int DriverAge, string Region, string CoverageLevel);
record QuoteResponse(string QuoteId, decimal FinalPremium, string Decision, int RiskScore);

// Single-quoted HTML/JS only, so this verbatim string needs no escaping.
static class Ui
{
    public const string Page = @"<!doctype html>
<html>
<head>
<meta charset='utf-8'>
<title>Motor Quote</title>
<style>
  body{font-family:sans-serif;max-width:520px;margin:40px auto}
  label{display:block;margin:10px 0 2px;font-weight:600}
  input,select{width:100%;padding:6px;box-sizing:border-box}
  button{margin-top:16px;padding:9px 18px;cursor:pointer}
  #out{margin-top:20px;white-space:pre-wrap;background:#f4f4f4;padding:12px;border-radius:6px}
</style>
</head>
<body>
<h2>Motor insurance quote</h2>
<label>Customer ID</label><input id='customerId' value='CUST-001'>
<label>Vehicle type</label>
<select id='vehicleType'><option>small</option><option>medium</option><option>suv</option></select>
<label>Driver age</label><input id='driverAge' type='number' value='30'>
<label>Region</label>
<select id='region'><option>urban</option><option>rural</option><option>suburban</option></select>
<label>Coverage</label>
<select id='coverageLevel'><option>basic</option><option>comprehensive</option></select>
<button onclick='getQuote()'>Get quote</button>
<div id='out'></div>
<script>
async function getQuote(){
  const body={
    customerId:document.getElementById('customerId').value,
    vehicleType:document.getElementById('vehicleType').value,
    driverAge:parseInt(document.getElementById('driverAge').value,10),
    region:document.getElementById('region').value,
    coverageLevel:document.getElementById('coverageLevel').value
  };
  const out=document.getElementById('out');
  out.textContent='...';
  try{
    const r=await fetch('/api/quote',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
    out.textContent=JSON.stringify(await r.json(),null,2);
  }catch(e){out.textContent='Error: '+e;}
}
</script>
</body>
</html>";
}
