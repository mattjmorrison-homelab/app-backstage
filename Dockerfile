# test and build+release use real multi-stage COPY --from, not a fully
# inline release build -- an earlier version did the whole yarn
# install/build inline in the release stage, which meant kaniko had to
# snapshot the *entire* filesystem (full source tree + all
# devDependencies) after every RUN. In CI that hung/died partway
# through: kaniko's own log showed every Dockerfile instruction finish,
# including the final EXPOSE/CMD and the --no-push skip, then went
# silent for ~2 minutes before the Job was killed -- consistent with
# that final full-tree snapshot exhausting the pod's resources.
#
# COPY --from is NOT the same problem graph-hdmi-switch's Dockerfile
# documents (kaniko pushing a manifest zot rejects when a pushed
# --target stage's own FROM chains to another local stage as its base
# image) -- that's about the stage's base image, not about copying
# files from an earlier stage. release's own FROM here is still an
# external image, so it's unaffected.
#
# That alone wasn't enough, though: kaniko still snapshots the *entire*
# filesystem after every RUN, even in the `build`/`test` stages, and a
# fresh yarn install here is 1GB+ across 2800+ packages -- slow/fragile
# on this cluster's runners regardless of which stage carries it. So:
# install/tsc/build:backend are chained into one RUN (fewer full-tree
# snapshots), and check.yml/publish.yml pass kaniko --snapshot-mode=redo
# (inspects only what the just-run command actually touched, instead of
# re-hashing every file) for the same reason.

FROM node:24-bookworm AS test
WORKDIR /app
RUN corepack enable
COPY . .
RUN yarn install --immutable
ENTRYPOINT ["yarn"]

FROM node:24-bookworm AS build
WORKDIR /app
RUN corepack enable
COPY . .
ARG COMMIT_SHA
ENV COMMIT_SHA=$COMMIT_SHA
ENV NODE_ENV=production
RUN yarn install --immutable && \
    yarn tsc && \
    yarn build:backend

FROM node:24-trixie-slim AS release
# better-sqlite3 ships prebuilt binaries for this platform -- just the
# runtime shared library is needed, no compiler toolchain (matches the
# scaffold's own default Dockerfile).
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends libsqlite3-dev && \
    rm -rf /var/lib/apt/lists/*
USER node
WORKDIR /app
COPY --chown=node:node --from=build /app/.yarn ./.yarn
COPY --chown=node:node --from=build /app/.yarnrc.yml ./
COPY --chown=node:node --from=build /app/backstage.json ./
ENV NODE_ENV=production
COPY --chown=node:node --from=build /app/yarn.lock /app/package.json /app/packages/backend/dist/skeleton.tar.gz ./
RUN tar xzf skeleton.tar.gz && rm skeleton.tar.gz
RUN yarn workspaces focus --all --production && \
    rm -rf "$(yarn cache clean 2>/dev/null; echo /home/node/.cache/yarn)"
COPY --chown=node:node --from=build /app/examples ./examples
COPY --chown=node:node --from=build /app/packages/backend/dist/bundle.tar.gz /app/app-config*.yaml ./
RUN tar xzf bundle.tar.gz && rm bundle.tar.gz
EXPOSE 7007
CMD ["node", "packages/backend", "--config", "app-config.yaml", "--config", "app-config.production.yaml"]
