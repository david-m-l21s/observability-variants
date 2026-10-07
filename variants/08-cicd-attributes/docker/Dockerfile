# One Dockerfile for all three baseline apps (variant 08-cicd-attributes).
#
# The build context is the UNCHANGED baseline app folder (apps/RatingApi, ...).
# Only this file differs, so the C# code is not copied into the variant.
#
#   docker buildx build \
#     -f variants/08-cicd-attributes/docker/Dockerfile \
#     --build-arg APP=RatingApi --build-arg SERVICE_VERSION=42-a1b2c3d ... \
#     --target final apps/RatingApi
#
# Two targets:
#   final  the correct pattern. Build values go into OTEL_BUILD_ATTRIBUTES; a
#          start command appends them to whatever OTEL_RESOURCE_ATTRIBUTES the
#          Kubernetes manifest sets. Neither side overwrites the other.
#   naive  the trap, built on purpose. Build values go straight into
#          OTEL_RESOURCE_ATTRIBUTES. The manifest sets the same variable, which
#          REPLACES the image value, so all build attributes are silently lost.

# ---------------------------------------------------------------------------
# build: runs on the build machine's own architecture and cross-compiles for
# the target (amd64 on the GitHub runner, arm64 for an Apple Silicon kind node).
# No emulation is needed, because the runtime stage below has no RUN steps.
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:9.0 AS build
ARG APP
ARG TARGETARCH
WORKDIR /src
COPY . .
RUN test -n "$APP" || (echo "build-arg APP is required (RatingApi|QuoteApi|QuoteWeb)" >&2; exit 1)
# -a accepts the Docker names amd64/arm64 directly (.NET 8+ SDK).
RUN dotnet publish "${APP}.csproj" -c Release -a "$TARGETARCH" -o /app/publish

# ---------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/aspnet:9.0 AS runtime
ARG APP
WORKDIR /app
COPY --from=build /app/publish .
ENV ASPNETCORE_URLS=http://0.0.0.0:8080
ENV APP_DLL=${APP}.dll
EXPOSE 8080

# --- build metadata: keep last. These values change on every commit and
# --- would invalidate the cache of every layer below them.
#
# Values must not contain ',' or '='. The .NET SDK (OtelEnvResourceDetector)
# splits on ',' and then on '=', and silently SKIPS any pair that does not split
# into exactly two parts. The workflow sanitises the values before passing them.
ARG SERVICE_VERSION=unknown
ARG VCS_REVISION=unknown
ARG VCS_REF_NAME=unknown
ARG VCS_REPOSITORY_URL=unknown
ARG CICD_PIPELINE_NAME=unknown
ARG CICD_RUN_ID=unknown
ARG CICD_RUN_URL=unknown

ENV OTEL_BUILD_ATTRIBUTES="service.version=${SERVICE_VERSION},vcs.ref.head.revision=${VCS_REVISION},vcs.ref.head.name=${VCS_REF_NAME},vcs.repository.url.full=${VCS_REPOSITORY_URL},cicd.pipeline.name=${CICD_PIPELINE_NAME},cicd.pipeline.run.id=${CICD_RUN_ID},cicd.pipeline.run.url.full=${CICD_RUN_URL}"

# ---------------------------------------------------------------------------
# naive: the trap. Same image, but the build values sit in the ONE variable that
# the manifest also sets.
FROM runtime AS naive
ENV OTEL_RESOURCE_ATTRIBUTES="${OTEL_BUILD_ATTRIBUTES}"
ENTRYPOINT ["/bin/sh", "-c", "exec dotnet \"$APP_DLL\""]

# ---------------------------------------------------------------------------
# final: the pattern we recommend. Last stage = default target.
#
# At container start both values exist: the image ENV and the manifest env.
# ${X:+X,} expands to "X," only when the manifest set something, so there is
# never a leading comma. `exec` replaces the shell with dotnet, so dotnet is
# PID 1 and receives SIGTERM from Kubernetes directly.
#
# Rule that keeps the merge unambiguous: build keys only here, deploy keys
# (k8s.*, deployment.environment.name) only in the manifest.
FROM runtime AS final
ENTRYPOINT ["/bin/sh", "-c", "export OTEL_RESOURCE_ATTRIBUTES=\"${OTEL_RESOURCE_ATTRIBUTES:+$OTEL_RESOURCE_ATTRIBUTES,}$OTEL_BUILD_ATTRIBUTES\"; exec dotnet \"$APP_DLL\""]
