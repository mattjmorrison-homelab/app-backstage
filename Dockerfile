# base installs production dependencies only, once. Both build (adds the
# devDependencies delta + runs tests + compiles) and release (just copies
# the compiled output) extend base directly -- neither ever repeats the
# production install base already did. This replaces an earlier version
# where `test`/`build` were two independent stages that each redid a full
# yarn install from scratch (kaniko shares nothing between separate
# --target invocations), and `release` did its own second, separate
# production-only install on top of that. Confirmed from a real build's
# layer history: `yarn install` alone was a 3.26GB layer, dwarfing
# everything else -- installing prod deps exactly once and reusing them
# is the fix, not a tuning knob.
#
# base and release stay on node:24-trixie-slim (matches what release
# always used) rather than node:24-bookworm -- the non-slim image bundles
# ~619MB of build tooling (gcc, g++, make, imagemagick, a dozen -dev
# libs) for whatever native module some npm package might need, not
# specifically what this app needs. better-sqlite3 ships prebuilt
# binaries for this platform, so base only needs the runtime lib.

FROM node:24-trixie-slim AS base
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends libsqlite3-dev && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN corepack enable
COPY package.json yarn.lock .yarnrc.yml backstage.json ./
COPY .yarn ./.yarn
# Yarn needs each workspace's own package.json to know the workspaces
# exist at all and to correctly set up packages/backend as a real,
# resolvable directory -- without this, `node packages/backend` fails
# with MODULE_NOT_FOUND even though the compiled bundle gets copied in
# later by release, because nothing ever told yarn that path was a
# workspace to begin with.
COPY packages/app/package.json ./packages/app/package.json
COPY packages/backend/package.json ./packages/backend/package.json
# Only backend's own production deps -- the deployed container serves
# the frontend's pre-bundled static output (from build:backend), it
# never runs packages/app's own React/MUI tree as live node_modules.
# "--all" here also installed the frontend's production deps, nearly
# 5x the image size for nothing (confirmed: 587MB vs 123MB actual).
RUN yarn workspaces focus backend --production

FROM base AS build
# Only build needs a compiler toolchain -- for devDependency-only native
# modules (tree-sitter x2, ssh2/cpu-features, esbuild, @swc/core). base
# and release never see this; it doesn't leak into the deployed image.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends python3 make g++ && \
    rm -rf /var/lib/apt/lists/*
COPY . .
ARG COMMIT_SHA
ENV COMMIT_SHA=$COMMIT_SHA
ENV CI=true
RUN yarn install --immutable
# NODE_ENV=production must not be set yet -- react/testing-library's
# act() explicitly doesn't work against React's production build
# (confirmed: "act(...) is not supported in production builds of
# React" when this was set before the test run instead of after it).
RUN yarn test
ENV NODE_ENV=production
RUN yarn tsc && yarn build:backend

# Independent external FROM, not `FROM base` -- confirmed directly:
# kaniko pushes a Docker-v2-schema manifest Zot rejects (MANIFEST_INVALID)
# when a *pushed* stage's own FROM chains to another local Dockerfile
# stage instead of an external image (same issue graph-hdmi-switch's
# Dockerfile documents). build's own `FROM base` is fine -- build is
# never pushed directly, only used as a COPY --from source. release IS
# pushed, so it copies base's installed state as files instead.
FROM node:24-trixie-slim AS release
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends libsqlite3-dev && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --chown=node:node --from=base /app/node_modules ./node_modules
COPY --chown=node:node --from=base /app/package.json /app/yarn.lock /app/.yarnrc.yml /app/backstage.json ./
COPY --chown=node:node --from=base /app/packages ./packages
COPY --chown=node:node --from=build /app/packages/backend/dist/bundle.tar.gz /app/app-config*.yaml ./
RUN tar xzf bundle.tar.gz && rm bundle.tar.gz
# WORKDIR creates /app as root regardless of any COPY --chown that
# happens afterward -- confirmed directly: the app boots fine as root,
# fails to resolve packages/backend at all as node, and /app itself is
# drwx------ root root. Fix ownership right before switching users.
RUN chown -R node:node /app
USER node
EXPOSE 7007
CMD ["node", "packages/backend", "--config", "app-config.yaml", "--config", "app-config.production.yaml"]
