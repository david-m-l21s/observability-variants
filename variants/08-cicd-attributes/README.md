# 08-cicd-attributes — facts from the CI pipeline in every wide event

The same three services as every other variant — `QuoteWeb → QuoteApi → RatingApi`,
**C# code unchanged** — but built by a **GitHub Actions workflow** that bakes facts
only the pipeline knows into each image. The apps send them as resource
attributes, so every span, log and metric in ClickHouse carries them.

> Which build answered this request? Did the errors start with build 42? Which
> commit is running in this namespace right now?

The same approach works in Azure DevOps. Only the variable names differ (table below).

## The attributes

| Attribute | Set at | GitHub source | Azure DevOps equivalent |
|---|---|---|---|
| `service.version` | build | `<run_number>-<short sha>` | `$(Build.BuildNumber)` |
| `vcs.ref.head.revision` | build | `github.sha` | `$(Build.SourceVersion)` |
| `vcs.ref.head.name` | build | `github.ref_name` | `$(Build.SourceBranchName)` |
| `vcs.repository.url.full` | build | `server_url/repository` | `$(Build.Repository.Uri)` |
| `cicd.pipeline.name` | build | `github.workflow` | `$(Build.DefinitionName)` |
| `cicd.pipeline.run.id` | build | `github.run_id` | `$(Build.BuildId)` |
| `cicd.pipeline.run.url.full` | build | `…/actions/runs/<run_id>` | `…/_build/results?buildId=…` ⚠ contains `=` |
| `deployment.environment.name` | deploy | manifest | manifest |
| `k8s.namespace.name`, `k8s.pod.name` | deploy | manifest (Downward API) | manifest |

All names are from the OTel semantic conventions. The `cicd.*` names were made to
describe a pipeline run; here they mean "the run that produced this binary". That is
our interpretation, not a convention rule.

## How the values get into the process

```
GitHub Actions ──build-args──▶ Dockerfile ARG ──▶ ENV OTEL_BUILD_ATTRIBUTES   (image)
Kubernetes manifest ───────────────────────────▶ env OTEL_RESOURCE_ATTRIBUTES (pod)
                     container start (ENTRYPOINT):
                     OTEL_RESOURCE_ATTRIBUTES = <manifest value>,<OTEL_BUILD_ATTRIBUTES>
                     exec dotnet <App>.dll  ──▶ OTel SDK env detector ──▶ every signal
```

Two variables, merged at container start. Neither side overwrites the other. The
manifest keeps setting `OTEL_RESOURCE_ATTRIBUTES` exactly like the baseline does.
No C# change: `AddService(ServiceName)` without a version argument does not write
`service.version`, and `ResourceBuilder.CreateDefault()` includes the env detector.

## What differs from the baseline

1. **`.github/workflows/08-cicd-attributes.yml`** at the repo root. GitHub runs
   workflows only from there. It builds the three apps **for amd64 and arm64**, pushes
   them to `ghcr.io/david-m-l21s/cicd-attributes/<app>:<run>-<sha>` and `:latest`, and
   writes the same facts as OCI labels.
2. **`docker/Dockerfile`** — one Dockerfile for all three apps; the build context is the
   unchanged `apps/<App>/` folder. Two targets: `final` (the pattern) and `naive` (the trap).
3. **`k8s/`** — baseline manifests with image placeholders and
   `deployment.environment.name=lab`, plus `13-rating-api-naive.yaml` (the trap, 0 replicas).
   Collector = baseline + healthz drop → DB `cicd_attributes`. Deliberately **no**
   `k8sattributes` processor.
4. Port: quote-web `:8089`.

## Traps found while building

- **`$(VAR)` in a manifest cannot see image ENV.** Kubernetes resolves `$(VAR)` only
  against variables listed earlier in the same `env:` block. An unresolved reference
  stays as literal text. `"$(OTEL_BUILD_ATTRIBUTES),k8s.namespace.name=x"` reaches the
  app unchanged, and the SDK skips the first part. This is why the merge happens in the
  entrypoint.
- **One `OTEL_RESOURCE_ATTRIBUTES`, two writers.** A container env var replaces the
  image's value; nothing is merged. Shown live by the `naive` deployment.
- **`=` or `,` in a value drops it silently.** The .NET SDK (1.9.0
  `OtelEnvResourceDetector`) splits on `,` then `=` and skips any pair that does not
  give exactly two parts. No percent-decoding. The workflow replaces `,` `=` and
  whitespace with `_`. The Azure DevOps build URL contains `?buildId=…` — it would
  vanish without that step.
- **`kubectl exec … env` lies here.** `exec` starts a new process with the manifest's
  environment; it never runs the entrypoint. The merged value is only visible in
  `/proc/1/environ` (what `08-inspect.sh` section 0 reads).
- **Azure DevOps:** `Docker@2` with `command: buildAndPush` ignores `arguments`, so the
  build args never arrive and every attribute says `unknown`. Use `build` + `push`.
- **GHCR packages start private**, even from a public repo. Set each one to public once.
- Unset build args give the value `unknown`, not an empty attribute: a forgotten
  build arg is visible, not silent.

## How to run and test

### Prerequisites (once)

- kind cluster `obs-vm-tests` running, Lima VM with ClickHouse running, `otel` user
  created (`cluster/scripts/03-clickhouse-otel-user.sh`).
- Docker Desktop running on the Mac (for `docker pull` / `docker inspect`).

### 1. Push, let the workflow build

```bash
cd ~/Documents/projects/ALH/VM-Tests/cluster
git add .github/workflows/08-cicd-attributes.yml variants/08-cicd-attributes VARIANTS.md
git commit -m "Variant 08: CI/CD attributes in wide events"
git push
```

Open **Actions → 08-cicd-attributes** on GitHub. The run has two jobs (meta, then a
3-way build matrix). The run summary shows the computed version (for example `1-a1b2c3d`)
and the baked `OTEL_*` env of each image. First run: about 5–8 minutes. Later runs are
faster (layer cache).

You can start it by hand too: **Run workflow** (workflow_dispatch).

### 2. Make the packages public (first run only)

GitHub → your profile → **Packages**. For `cicd-attributes/rating-api`,
`cicd-attributes/quote-api`, `cicd-attributes/quote-web`:
**Package settings → Change visibility → Public**.

Check from the Mac, without login:

```bash
docker logout ghcr.io 2>/dev/null; docker pull ghcr.io/david-m-l21s/cicd-attributes/rating-api:latest
```

### 3. Look at what the pipeline baked in

```bash
cd variants/08-cicd-attributes/scripts
./03-show-image.sh            # or ./03-show-image.sh 1-a1b2c3d
```

Expect for each image: the OCI labels (`revision`, `version`, `source`), the
`OTEL_BUILD_ATTRIBUTES` list with real values (no `unknown`), and the entrypoint with
the merge. The `-naive` image has the values in `OTEL_RESOURCE_ATTRIBUTES` instead.

### 4. Deploy

```bash
./04-deploy.sh                # resolves :latest to the concrete version
```

The kind node pulls from ghcr.io itself. If that fails (`ImagePullBackOff`, e.g. proxy,
or the packages are still private): `./04-deploy.sh latest --load`.

### 5. Traffic

```bash
./05-port-forward.sh          # terminal 2, keep it open
./06-generate-load.sh         # terminal 1, 40 quotes
```

### 6. Check

```bash
./08-inspect.sh
```

| Section | Expect |
|---|---|
| 0 | each pod: three `k8s.*`/`deployment.*` keys, then seven build keys |
| 1 | one row per pod; version, rev, run_id, env all filled |
| 2 | **0** in every `no_*` column, for traces, logs and metrics |
| 3 | rating-api: the 10 attributes from the table above, plus `service.name`, `service.instance.id` and `telemetry.sdk.*` from the SDK |
| 4/5 | one version per service |

Also open the `run_url` from section 5 in the browser: it goes to the exact workflow run.

### 7. The trap

```bash
./07-trap.sh on
./06-generate-load.sh
./08-inspect.sh 5
```

Expect: section 0 shows the naive pod with **only** the three deploy keys. Section 1
has a second rating-api row with empty version/rev/run_id. Section 2 shows about half
of the rating-api trace rows (and the naive pod's logs and metrics) lacking the build
attributes, while `no_namespace` stays 0. Same build, same manifest — only the image
target differs.

```bash
./07-trap.sh off
```

### 8. A second build: the cut-over

Make any change that triggers the workflow, for example a comment line in
`variants/08-cicd-attributes/docker/Dockerfile`, push, wait for the run, then:

```bash
./04-deploy.sh                # new version -> pods replaced
./05-port-forward.sh          # restart: the forward dies with the old pods
./06-generate-load.sh
./08-inspect.sh
```

Section 4 now shows the minute where version N stops and N+1 starts. Section 5 shows
one row per (service, version) with its own p95 and error count. That table is the
answer to "did it start with that build?".

### Without GitHub (fallback)

```bash
./02-build-local.sh           # same Dockerfile, values from your local git
./04-deploy.sh local-<sha7> --no-pull
```

`cicd.pipeline.name=local-build` then marks the data as not from CI.

### Clean up

```bash
kubectl delete namespace 08-cicd-attributes
curl 'http://localhost:8123/?user=otel&password=otelpass' --data-binary 'DROP DATABASE cicd_attributes'
```

## Not covered here (worth knowing)

- **Option C**, the `k8sattributes` collector processor, would add `k8s.*` without the
  manifest touching `OTEL_RESOURCE_ATTRIBUTES`, so a plain `ENV OTEL_RESOURCE_ATTRIBUTES`
  in the image would survive. It needs cluster-level read rights on pods, which the
  restricted client namespace does not have. The entrypoint merge needs no rights, but
  needs a shell in the image (not true for chiseled .NET images; then merge in C# with
  `ResourceBuilder.AddAttributes`).
- Pull-request builds (`vcs.change.id`) and the person who triggered the build are left
  out on purpose: the first is only useful if PR builds get deployed, the second is
  personal data.

## Verified outside the cluster (2026-10-07)

- Workflow passes `actionlint`. Collector config passes `otelcol-contrib 0.146.1 validate`.
  Scripts are `shellcheck` clean. Rendered manifests parse.
- **Dockerfile logic with a real `docker build`** (BuildKit, Dockerfile outside the
  context, both targets, all build args) on stand-in base images with a fake `dotnet`
  that parses the variable the way the 1.9.0 SDK does: `final` + manifest value →
  all 10 keys kept; `final` without manifest value → 7 build keys, no leading comma;
  `naive` + manifest value → only the 3 deploy keys (trap reproduced); the literal
  `$(OTEL_BUILD_ATTRIBUTES)` reference → skipped. `dotnet` runs as PID 1 (the `exec`
  works); `/proc/1/environ` shows the merged value while `exec … env` shows only the
  manifest value.
- `08-inspect.sh` SQL runs in chdb against tables with the exporter's column names
  (found and fixed one defect: `ORDER BY` over a `UNION ALL` needs a wrapping subquery).

**Not verified:** a real .NET build (mcr.microsoft.com and nuget.org unreachable from
the session; `-a $TARGETARCH` is the documented .NET 8+ pattern), the workflow on
GitHub, GHCR pulls from kind, and the real SDK in a pod.
