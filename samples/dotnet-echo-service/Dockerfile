# Multi-stage: build with the SDK image, run on the slim ASP.NET runtime image.
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY EchoService.csproj ./
RUN dotnet restore
COPY . ./
RUN dotnet publish -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:8.0
WORKDIR /app
COPY --from=build /app ./
ENV ASPNETCORE_URLS=http://+:8090
EXPOSE 8090
ENTRYPOINT ["dotnet", "EchoService.dll"]
