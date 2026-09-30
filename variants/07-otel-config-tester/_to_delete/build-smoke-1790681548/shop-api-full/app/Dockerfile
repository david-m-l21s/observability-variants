# OtelProbe, built once per rendered configuration (build/<config>/app/).
# DOTNET_VERSION comes from the configuration's target framework
# (net8.0 -> 8.0, net9.0 -> 9.0, net10.0 -> 10.0).
ARG DOTNET_VERSION=9.0

FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_VERSION} AS build
WORKDIR /src
# Restore first, in its own layer: it only re-runs when the package set in the
# .csproj changes. A configuration that only changes Program.cs reuses it.
COPY OtelProbe.csproj .
RUN dotnet restore OtelProbe.csproj
COPY . .
RUN dotnet publish OtelProbe.csproj -c Release -o /app/publish --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:${DOTNET_VERSION} AS final
WORKDIR /app
COPY --from=build /app/publish .
ENV ASPNETCORE_URLS=http://0.0.0.0:8080
EXPOSE 8080
ENTRYPOINT ["dotnet", "OtelProbe.dll"]
