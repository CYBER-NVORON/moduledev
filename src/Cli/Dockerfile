FROM mcr.microsoft.com/dotnet/sdk:10.0-alpine@sha256:620e765fe18186c08399f7aa978f79f04b6bbf0ee1b3b8a91e2d5c9619e59da1 AS build
WORKDIR /src
COPY src/Cli/Cli.csproj src/Cli/
RUN dotnet restore src/Cli/Cli.csproj
COPY src/Cli/ src/Cli/
COPY src/Shared/ src/Shared/
COPY contracts/ contracts/
RUN dotnet publish src/Cli/Cli.csproj -c Release -o /app

FROM mcr.microsoft.com/dotnet/aspnet:10.0-alpine@sha256:c4b29bf368004ad9076c1ab9bc91fb373561e3905b4345637e14e8b8c57e3be8
WORKDIR /app
COPY --from=build /app .
COPY migrations/ /migrations/
USER app
ENTRYPOINT ["dotnet", "Cli.dll"]
