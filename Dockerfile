# release and test each get their own independent external FROM and do
# a full yarn install/build inline, instead of a shared builder stage
# copied via COPY --from -- same reasoning as graph-hdmi-switch's
# Dockerfile: kaniko pushes a Docker-v2-schema manifest (rejected by zot
# with 415/MANIFEST_INVALID) when a pushed --target stage's own FROM
# references another Dockerfile stage rather than an external image.
# Each stage is built as its own separate kaniko invocation anyway, so
# there's no cross-stage layer caching being given up by not sharing a
# base -- just a larger release image (full source + devDependencies)
# than the multi-stage build Backstage's own docs describe. Acceptable
# tradeoff for now; revisit if image size becomes a real problem.

FROM node:24-bookworm AS test
WORKDIR /app
RUN corepack enable
COPY . .
RUN yarn install --immutable
ENTRYPOINT ["yarn"]

FROM node:24-trixie-slim AS release
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends libsqlite3-dev python3 make g++ && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN corepack enable
COPY . .
ARG COMMIT_SHA
ENV COMMIT_SHA=$COMMIT_SHA
ENV NODE_ENV=production
RUN yarn install --immutable
RUN yarn tsc
RUN yarn build:backend
RUN tar xzf packages/backend/dist/skeleton.tar.gz && \
    tar xzf packages/backend/dist/bundle.tar.gz
EXPOSE 7007
CMD ["node", "packages/backend", "--config", "app-config.yaml", "--config", "app-config.production.yaml"]
