# Imagem Debian, nao Alpine: @node-rs/argon2 e modulo nativo, e o build glibc
# evita a classe de problema em que a imagem sobe e so quebra no primeiro login.
FROM oven/bun:1 AS deps
WORKDIR /app
COPY package.json bun.lock ./
# --frozen-lockfile: o deploy instala exatamente o que foi testado, e falha se o
# lockfile estiver desatualizado em vez de resolver versoes novas sozinho.
RUN bun install --frozen-lockfile --production

FROM oven/bun:1
WORKDIR /app
ENV NODE_ENV=production

COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
# tsconfig.json NAO e opcional: e dele que o Bun le experimentalDecorators e
# emitDecoratorMetadata. Sem ele os decorators do TypeORM compilam no formato
# novo e a API morre no primeiro @PrimaryGeneratedColumn -- em runtime, dentro
# do container, sem aviso nenhum no build.
COPY tsconfig.json ./
COPY src ./src

# Pasta das releases. Precisa ser volume no compose, senao cada deploy apaga
# centenas de MB e todos os jogadores perdem a origem do download.
RUN mkdir -p /app/releases
ENV RELEASES_DIR=/app/releases

EXPOSE 3000

# Sem --env-file: em container a configuracao vem do ambiente. O script "start"
# do package.json aponta para ../.env, que so existe em desenvolvimento.
CMD ["bun", "src/server.ts"]
