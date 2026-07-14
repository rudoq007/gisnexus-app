FROM node:20-slim AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install
COPY . .
# Fetches the WhiteboxTools binary into ./bin — must run after `COPY . .`
# (needs scripts/setup-whitebox.js and jszip from node_modules), not as an
# npm postinstall hook (which would fire during the `npm install` above,
# before the source tree exists). setup:whitebox is deliberately non-fatal
# (see the script's own comments) — `mkdir -p bin` first guarantees the
# directory exists either way, so the later `COPY --from=build /app/bin`
# below never fails even if the download itself didn't succeed.
RUN mkdir -p bin && npm run setup:whitebox
RUN npm run build

FROM node:20-slim
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json* ./
RUN npm install --omit=dev
COPY --from=build /app/dist ./dist
COPY --from=build /app/bin ./bin
COPY migrations ./migrations
COPY scripts ./scripts
EXPOSE 4000
# Run pending migrations (idempotent — tracked in the _migrations table, so
# already-applied ones are skipped) before starting the server, so schema
# changes land automatically on every deploy without a separate manual step.
CMD ["sh", "-c", "node scripts/migrate.js && node dist/index.js"]
