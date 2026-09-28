# Builds on top of docker-backstage's pre-published images instead of
# installing dependencies from scratch. docker-backstage:test and
# docker-backstage:prod already have /app/node_modules, package.json,
# yarn.lock, .yarnrc.yml, backstage.json, and packages/*/package.json
# in place (that's exactly what docker-backstage's own Dockerfile
# publishes at those paths) -- this repo no longer keeps its own copies
# of those files (see the deletions in this same change) or runs
# `yarn install`/`yarn workspaces focus` at all. That full dependency
# install -- confirmed as a 3.26GB layer on its own -- now happens once
# in docker-backstage, a repo that changes rarely, instead of on every
# app-backstage PR.
#
# build's `COPY . .` lays this repo's real source on top of the already
# -populated /app from docker-backstage:test. That's safe specifically
# because this repo no longer has its own package.json/yarn.lock/etc to
# stomp the pre-built ones with -- if those files ever come back here,
# this COPY would need to move above them again.
FROM registry.morrisons.site/docker-backstage:test AS build
WORKDIR /app
COPY . .
ARG COMMIT_SHA
ENV COMMIT_SHA=$COMMIT_SHA
ENV CI=true
# NODE_ENV=production must not be set yet -- react/testing-library's
# act() explicitly doesn't work against React's production build
# (confirmed: "act(...) is not supported in production builds of
# React" when this was set before the test run instead of after it).
RUN yarn test
ENV NODE_ENV=production
RUN yarn tsc && yarn build:backend

# External registry reference, not a local Dockerfile stage -- this
# does NOT trigger the MANIFEST_INVALID kaniko/Zot bug (that only
# happens when a *pushed* stage's own FROM chains to another *local*
# stage in the same Dockerfile; chaining to an external image is always
# fine). release pulls docker-backstage:prod directly rather than
# copying installed state from build, since build's own base
# (docker-backstage:test) carries the dev deps and compiler toolchain
# this runtime image doesn't need.
FROM registry.morrisons.site/docker-backstage:prod AS release
WORKDIR /app
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
