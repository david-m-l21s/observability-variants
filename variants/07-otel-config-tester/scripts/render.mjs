#!/usr/bin/env node
// render.mjs — turns an OTel Tracing Configurator configuration into a
// buildable probe app and a Kubernetes manifest.
//
// The code generators are NOT copied here. They are read at runtime from the
// GEN-START ... GEN-END block of configurator/otel-tracing-configurator.html,
// so this script always produces exactly what the page shows.
//
// Commands (paths are relative to the variant folder):
//
//   node scripts/render.mjs import <link|base64|file.json> [--name NAME]
//       Decodes a "Copy config link" / "Copy run command" payload (or reads a
//       JSON file), fills in defaults, writes configs/<NAME>.json and prints
//       NAME. Default NAME: <service.name>-<6 hex of the configuration>, so the
//       same configuration always gets the same name.
//
//   node scripts/render.mjs render <configs/NAME.json> --run-id RUN_ID [--aspnet-env ENV]
//       Writes build/NAME/ (app/, k8s/probe.yaml, generated/) and prints
//       shell assignments (NAME=..., IMAGE=..., ...) for run.sh.
//
//   node scripts/render.mjs link <configs/NAME.json>
//       Prints the configurator URL that opens this configuration.
//
// Plain Node 18+, no npm packages.

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const VARIANT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CONFIGURATOR = path.join(VARIANT, "configurator", "otel-tracing-configurator.html");
const TEMPLATE = path.join(VARIANT, "apps", "OtelProbe");
const NAMESPACE = "07-otel-config-tester";
// When run.sh runs this script inside a node container, the variant folder is
// mounted at another path. VARIANT_HOST_DIR is the real path, for printed output.
const HOST_DIR = process.env.VARIANT_HOST_DIR || VARIANT;

// Options whose generated code needs something the probe app does not have.
// They are rejected instead of producing an image that crashes or tests nothing.
const UNSUPPORTED = {
  redis: "AddRedisInstrumentation() needs an IConnectionMultiplexer (a Redis server) in DI.",
  npgsql: "AddNpgsql() needs a PostgreSQL database; the probe uses SQLite.",
  sqlclient: "AddSqlClientInstrumentation() needs SQL Server; the probe uses SQLite (use EF Core instead).",
  grpc: "The probe makes no gRPC calls, and the package version is not pinned in the configurator.",
};

// Microsoft.EntityFrameworkCore.Sqlite per target framework. Floating patch
// versions: NuGet resolves the newest patch at restore time, and Docker's
// layer cache keeps that result until the .csproj changes.
const EF_SQLITE = { "net8.0": "8.0.*", "net9.0": "9.0.*", "net10.0": "10.0.*" };

// ---------------------------------------------------------------------------
function loadGenerators() {
  const html = fs.readFileSync(CONFIGURATOR, "utf8");
  const a = html.indexOf("/* GEN-START"), b = html.indexOf("/* GEN-END */");
  if (a < 0 || b < a) die(`No GEN-START/GEN-END block in ${CONFIGURATOR}`);
  const names = ["DEFAULTS", "PRESETS", "LIMITS", "genProgram", "genPackageList", "genPackages",
    "genEnv", "genAppsettings", "genConfig", "genChecks"];
  // eslint-disable-next-line no-new-func
  return new Function(html.slice(a, b) + `\nreturn { ${names.join(", ")} };`)();
}

function die(msg, code = 1) { process.stderr.write(`render.mjs: ${msg}\n`); process.exit(code); }
function warn(msg) { process.stderr.write(msg + "\n"); }
const clone = (o) => JSON.parse(JSON.stringify(o));
const sha = (s) => crypto.createHash("sha256").update(s).digest("hex");
const lines = (s) => String(s || "").split(/\r?\n/).map((x) => x.trim()).filter(Boolean);
const slug = (s) => String(s).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40) || "config";
const yq = (s) => JSON.stringify(String(s)); // a JSON string is a valid YAML double-quoted scalar

function arg(name, def) {
  const i = process.argv.indexOf(name);
  return i > 0 && process.argv[i + 1] !== undefined ? process.argv[i + 1] : def;
}

function withDefaults(G, s) {
  const merged = Object.assign(clone(G.DEFAULTS), s || {});
  // Keys the page does not know are dropped: they would never reach the generators anyway.
  for (const k of Object.keys(merged)) if (!(k in G.DEFAULTS)) delete merged[k];
  return merged;
}

function checkSupported(s, what) {
  const bad = Object.keys(UNSUPPORTED).filter((k) => s[k]);
  if (bad.length) die(`${what} uses options the probe app cannot run:\n` +
    bad.map((k) => `  - ${k}: ${UNSUPPORTED[k]}`).join("\n") + "\nSwitch them off in the configurator.", 2);
}

// ---------------------------------------------------------------------------
function decodePayload(input) {
  if (fs.existsSync(input) && fs.statSync(input).isFile()) return JSON.parse(fs.readFileSync(input, "utf8"));
  // Accepts a whole URL (file:///...html#<b64>), a run command, or bare base64.
  let b64 = input.includes("#") ? input.slice(input.lastIndexOf("#") + 1) : input;
  b64 = decodeURIComponent(b64.trim().replace(/^'+|'+$/g, ""));
  try {
    return JSON.parse(Buffer.from(b64, "base64").toString("utf8"));
  } catch (e) {
    die(`Could not decode the configuration. Pass the "Copy config link" URL, the base64 part, or a JSON file.\n  ${e.message}`);
  }
}

function cmdImport(G) {
  const input = process.argv[3];
  if (!input) die("usage: render.mjs import <link|base64|file.json> [--name NAME]");
  const state = withDefaults(G, decodePayload(input));
  checkSupported(state, "this configuration");
  const json = JSON.stringify(state, null, 2) + "\n";
  const name = slug(arg("--name", `${state.serviceName || "config"}-${sha(json).slice(0, 6)}`));
  const file = path.join(VARIANT, "configs", `${name}.json`);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  if (fs.existsSync(file) && fs.readFileSync(file, "utf8") !== json)
    warn(`note: configs/${name}.json existed with a different configuration and was replaced.`);
  fs.writeFileSync(file, json);
  process.stdout.write(name + "\n");
}

function cmdLink(G) {
  const file = process.argv[3];
  if (!file) die("usage: render.mjs link <configs/NAME.json>");
  const state = withDefaults(G, JSON.parse(fs.readFileSync(file, "utf8")));
  const b64 = Buffer.from(JSON.stringify(state), "utf8").toString("base64");
  process.stdout.write(`file://${path.join(HOST_DIR, "configurator", "otel-tracing-configurator.html")}#${b64}\n`);
}

// ---------------------------------------------------------------------------
function splitUsings(program) {
  const all = program.split("\n");
  let i = 0;
  const usings = [];
  while (i < all.length && /^using [\w.]+;$/.test(all[i])) usings.push(all[i++]);
  while (i < all.length && all[i].trim() === "") i++;
  return { usings, body: all.slice(i) };
}

function probeSourceFor(s) {
  const first = lines(s.sources)[0];
  if (!first) return { name: "OtelProbe", listened: false };
  return { name: first.includes("*") ? first.replace(/\*/g, "Probe") : first, listened: true };
}

function csproj(s, pkgs) {
  const tfm = s.fw in EF_SQLITE ? s.fw : "net9.0";
  const refs = pkgs.map((p) => `    <PackageReference Include="${p.id}" Version="${p.ver}" />${p.note ? `  <!-- ${p.note} -->` : ""}`);
  return `<Project Sdk="Microsoft.NET.Sdk.Web">
  <!-- Rendered by scripts/render.mjs. Do not edit; change the configuration instead. -->
  <PropertyGroup>
    <TargetFramework>${tfm}</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <InvariantGlobalization>true</InvariantGlobalization>
    <!-- The template and the generated snippet may both import System.Diagnostics. -->
    <NoWarn>$(NoWarn);CS0105</NoWarn>
  </PropertyGroup>

  <!-- The probe app itself -->
  <ItemGroup>
    <PackageReference Include="Microsoft.EntityFrameworkCore.Sqlite" Version="${EF_SQLITE[tfm]}" />
  </ItemGroup>

  <!-- From the configurator (.csproj packages tab) -->
  <ItemGroup>
${refs.join("\n")}
  </ItemGroup>
</Project>
`;
}

function deepMerge(a, b) {
  for (const [k, v] of Object.entries(b || {})) {
    if (v && typeof v === "object" && !Array.isArray(v) && a[k] && typeof a[k] === "object") deepMerge(a[k], v);
    else a[k] = v;
  }
  return a;
}

function stripHtml(t) {
  return t.replace(/<[^>]+>/g, "").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&amp;/g, "&");
}

function copyDir(src, dst, skip = () => false) {
  fs.mkdirSync(dst, { recursive: true });
  for (const e of fs.readdirSync(src, { withFileTypes: true })) {
    if (skip(e.name)) continue;
    const a = path.join(src, e.name), b = path.join(dst, e.name);
    if (e.isDirectory()) copyDir(a, b, skip); else fs.copyFileSync(a, b);
  }
}

function hashDir(dir) {
  const h = crypto.createHash("sha256");
  const walk = (d) => {
    for (const n of fs.readdirSync(d).sort()) {
      const p = path.join(d, n);
      if (fs.statSync(p).isDirectory()) walk(p);
      else { h.update(path.relative(dir, p) + "\0"); h.update(fs.readFileSync(p)); h.update("\0"); }
    }
  };
  walk(dir);
  return h.digest("hex");
}

function envYaml(env) {
  return env.map((e) => e.fieldPath
    ? `            - name: ${e.name}\n              valueFrom:\n                fieldRef:\n                  fieldPath: ${e.fieldPath}`
    : `            - name: ${e.name}\n              value: ${yq(e.value)}`).join("\n");
}

function cmdRender(G) {
  const file = process.argv[3];
  const runId = arg("--run-id");
  if (!file || !runId) die("usage: render.mjs render <configs/NAME.json> --run-id RUN_ID [--aspnet-env ENV]");
  const name = slug(path.basename(file).replace(/\.json$/, ""));
  const s = withDefaults(G, JSON.parse(fs.readFileSync(file, "utf8")));
  const aspnetEnv = arg("--aspnet-env", "Production");

  checkSupported(s, `configuration ${name}`);

  const out = path.join(VARIANT, "build", name);
  fs.rmSync(out, { recursive: true, force: true });
  const app = path.join(out, "app");

  // --- app --------------------------------------------------------------------
  copyDir(TEMPLATE, app, (n) => ["bin", "obj", "Program.template.cs", "appsettings.template.json"].includes(n));

  const program = G.genProgram(s);
  const { usings, body } = splitUsings(program);
  const tpl = fs.readFileSync(path.join(TEMPLATE, "Program.template.cs"), "utf8");
  if (!tpl.includes("// @@OTEL_USINGS@@") || !tpl.includes("// @@OTEL_TRACING@@")) die("Program.template.cs lost its markers.");
  fs.writeFileSync(path.join(app, "Program.cs"), tpl
    .replace("// @@OTEL_USINGS@@", usings.length ? usings.join("\n") : "// (no usings from the configurator)")
    .replace("// @@OTEL_TRACING@@", body.join("\n")));

  const pkgs = G.genPackageList(s);
  fs.writeFileSync(path.join(app, "OtelProbe.csproj"), csproj(s, pkgs));

  const appsettings = deepMerge(JSON.parse(fs.readFileSync(path.join(TEMPLATE, "appsettings.template.json"), "utf8")),
    G.genAppsettings(s));
  fs.writeFileSync(path.join(app, "appsettings.json"), JSON.stringify(appsettings, null, 2) + "\n");

  const image = `otel-probe:${hashDir(app).slice(0, 12)}`;
  const dotnetVersion = s.fw.replace(/^net/, "");

  // --- env --------------------------------------------------------------------
  const src = probeSourceFor(s);
  const env = G.genEnv(s);
  // Every run is tagged, whatever the configuration says, so ClickHouse rows can
  // be grouped by run. These two are the only resource attributes the test
  // harness adds; everything else comes from the configuration.
  const runAttrs = `test.run.id=${runId},test.config.name=${name}`;
  const ra = env.find((e) => e.name === "OTEL_RESOURCE_ATTRIBUTES");
  if (ra) ra.value = `${ra.value},${runAttrs}`;
  else env.push({ name: "OTEL_RESOURCE_ATTRIBUTES", value: runAttrs });
  env.push(
    { name: "ASPNETCORE_ENVIRONMENT", value: aspnetEnv },
    { name: "PROBE_SOURCE", value: src.name },
    { name: "PROBE_SELF_URL", value: "http://probe:8080" },
    { name: "PROBE_RUN_ID", value: runId },
    { name: "PROBE_CONFIG_NAME", value: name },
  );

  // --- k8s --------------------------------------------------------------------
  const k8s = path.join(out, "k8s");
  fs.mkdirSync(k8s, { recursive: true });
  fs.writeFileSync(path.join(k8s, "probe.yaml"), `# Rendered by scripts/render.mjs — configuration ${name}, run ${runId}.
# Do not edit; change configs/${name}.json (or the configurator) and run scripts/run.sh.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: probe
  namespace: ${NAMESPACE}
  labels:
    app: probe
  annotations:
    otel-config-tester/config: ${yq(name)}
    otel-config-tester/run-id: ${yq(runId)}
spec:
  replicas: 1
  # Recreate, not RollingUpdate: the old pod is gone before the new one starts,
  # so two runs never send spans at the same time.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: probe
  template:
    metadata:
      labels:
        app: probe
      annotations:
        otel-config-tester/config: ${yq(name)}
        otel-config-tester/run-id: ${yq(runId)}
    spec:
      containers:
        - name: probe
          image: ${yq(image)}
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          env:
${envYaml(env)}
          # /health on purpose: real probe traffic is what the Filter options
          # are for. Without a /health filter there is one span every 10 s.
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 3
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: probe
  namespace: ${NAMESPACE}
spec:
  selector:
    app: probe
  ports:
    - name: http
      port: 8080
      targetPort: 8080
`);

  // --- generated/: the three configurator tabs + checks, for reference -------
  const gen = path.join(out, "generated");
  fs.mkdirSync(gen, { recursive: true });
  fs.writeFileSync(path.join(gen, "Program.otel.cs"), program + "\n");
  fs.writeFileSync(path.join(gen, "packages.xml"), G.genPackages(s) + "\n");
  fs.writeFileSync(path.join(gen, "env-appsettings.yaml"), G.genConfig(s) + "\n");
  const checks = G.genChecks(s).map(([k, t]) => `[${k}] ${stripHtml(t)}`);
  const notes = [];
  if (!src.listened) notes.push(`[probe] No ActivitySource in the configuration: the probe's custom spans ("Validate order", "Reserve stock", "Stock sync", ...) use source "${src.name}" and are NOT recorded.`);
  else notes.push(`[probe] Custom spans use ActivitySource "${src.name}" (first entry of the configuration's source list).`);
  if (s.otlp) {
    const ep = s.otlpEndpoint.trim();
    if (!/^https?:\/\/otel-collector(:\d+)?(\/|$)/.test(ep)) notes.push(`[probe] OTLP endpoint ${ep} is not the variant's collector (http://otel-collector:4317 or :4318). Spans will not reach ClickHouse.`);
    if (s.otlpProtocol === "grpc" && /:4318/.test(ep)) notes.push("[probe] gRPC protocol against port 4318 (the HTTP port). Export will fail.");
    if (s.otlpProtocol === "http/protobuf" && /:4317/.test(ep)) notes.push("[probe] HTTP/protobuf protocol against port 4317 (the gRPC port). Export will fail.");
  } else notes.push("[probe] OTLP exporter is off: nothing will reach ClickHouse.");
  if (s.console === "dev" && aspnetEnv !== "Development") notes.push(`[probe] Console exporter is "only in Development", and this run is ${aspnetEnv}: no console output.`);
  fs.writeFileSync(path.join(gen, "checks.txt"), [...checks, ...notes].join("\n") + "\n");
  for (const c of [...checks, ...notes]) warn("  " + c);

  const assign = { NAME: name, RUN_ID: runId, IMAGE: image, DOTNET_VERSION: dotnetVersion,
    BUILD_DIR: path.join(HOST_DIR, "build", name), PROBE_SOURCE: src.name, FRAMEWORK: s.fw };
  process.stdout.write(Object.entries(assign).map(([k, v]) => `${k}=${yq(v).replace(/\$/g, "\\$")}`).join("\n") + "\n");
}

// ---------------------------------------------------------------------------
const G = loadGenerators();
const cmd = process.argv[2];
if (cmd === "import") cmdImport(G);
else if (cmd === "render") cmdRender(G);
else if (cmd === "link") cmdLink(G);
else die("usage: render.mjs import|render|link ... (see the header of this file)");
