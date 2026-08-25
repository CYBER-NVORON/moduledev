FROM mcr.microsoft.com/dotnet/sdk:10.0-alpine AS build
WORKDIR /src
COPY src/Cli/Cli.csproj src/Cli/
RUN dotnet restore src/Cli/Cli.csproj
COPY src/Cli/ src/Cli/
RUN dotnet publish src/Cli/Cli.csproj -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0-alpine
WORKDIR /app
COPY --from=build /app .
ENTRYPOINT ["dotnet", "Cli.dll"]
