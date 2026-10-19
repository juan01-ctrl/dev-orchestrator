FROM elixir:1.19.6-otp-28-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends build-essential ca-certificates git && rm -rf /var/lib/apt/lists/*
WORKDIR /build
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock* ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile
COPY lib lib
COPY priv priv
RUN mix assets.copy && mix compile && mix release

FROM elixir:1.19.6-otp-28-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates openssl libstdc++6 && rm -rf /var/lib/apt/lists/* && useradd --create-home app
WORKDIR /app
COPY --from=build --chown=app:app /build/_build/prod/rel/dev_orchestrator ./
USER app
ENV PORT=4100 RELEASE_DISTRIBUTION=none
EXPOSE 4100
CMD ["bin/dev_orchestrator", "start"]
