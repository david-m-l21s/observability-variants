using System.Diagnostics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

// ---- OpenTelemetry: tracing ----------------------------------------------
builder.Services.AddOpenTelemetry()
    // k8s.* attributes arrive via OTEL_RESOURCE_ATTRIBUTES (see Env tab).
    .ConfigureResource(resource => resource
        .AddService(
            serviceName: "shop-api",
            serviceNamespace: "t2a")
        .AddAttributes(new KeyValuePair<string, object>[]
        {
            new("deployment.environment.name", builder.Environment.EnvironmentName),
        }))
    .WithTracing(tracing =>
    {
        // Sampling: SDK default is ParentBased(AlwaysOn) — nothing to set.

        // Incoming HTTP requests -> SERVER spans
        tracing.AddAspNetCoreInstrumentation(o =>
        {
            o.RecordException = true;

            // return false = no span is created for this request
            o.Filter = ctx =>
            {
                if (HttpMethods.IsOptions(ctx.Request.Method)) return false;
                var p = ctx.Request.Path.Value ?? string.Empty;
                return !(p.StartsWith("/health", StringComparison.OrdinalIgnoreCase)
                      || p.StartsWith("/healthz", StringComparison.OrdinalIgnoreCase)
                      || p.StartsWith("/ready", StringComparison.OrdinalIgnoreCase)
                      || p.StartsWith("/alive", StringComparison.OrdinalIgnoreCase)
                      || p.StartsWith("/metrics", StringComparison.OrdinalIgnoreCase));
            };

            o.EnrichWithException = (activity, ex) =>
                activity.SetStatus(ActivityStatusCode.Error, ex.Message);

            o.EnrichWithHttpRequest = (activity, request) =>
            {
                if (request.Headers.TryGetValue("x-tenant-id", out var xTenantId))
                    activity.SetTag("http.request.header.x-tenant-id", xTenantId.ToString());
                if (request.Headers.TryGetValue("x-correlation-id", out var xCorrelationId))
                    activity.SetTag("http.request.header.x-correlation-id", xCorrelationId.ToString());
            };
        });

        // Outgoing HttpClient calls -> CLIENT spans (+ traceparent propagation)
        tracing.AddHttpClientInstrumentation(o =>
        {
            o.RecordException = true;

            o.FilterHttpRequestMessage = request =>
            {
                var uri = request.RequestUri;
                if (uri is null) return true;
                return !(uri.Host.Equals("otel-collector", StringComparison.OrdinalIgnoreCase)
                      || uri.AbsolutePath.StartsWith("/health", StringComparison.OrdinalIgnoreCase));
            };

            o.EnrichWithException = (activity, ex) =>
                activity.SetStatus(ActivityStatusCode.Error, ex.Message);
        });

        // Databases & caches -> CLIENT spans
        // NOT AddSource("Microsoft.EntityFrameworkCore"): that is a DiagnosticListener,
        // not an ActivitySource — AddSource would silently do nothing.
        tracing.AddEntityFrameworkCoreInstrumentation();

        // ActivitySources to listen to
        tracing.AddSource("T2A.Shop");

        // Export
        // Endpoint + protocol from OTEL_EXPORTER_OTLP_* (see Env tab).
        tracing.AddOtlpExporter();
        if (builder.Environment.IsDevelopment())
            tracing.AddConsoleExporter();

        // Span limits: set via OTEL_*_LIMIT environment variables (see Env tab).
    });
