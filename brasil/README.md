# brasil/ — plataforma online do Kam Brasil

Tudo que não é a engine do jogo mora aqui. Esta pasta é isolada de propósito: o upstream
`reyandme/kam_remake` nunca vai criar um diretório `brasil/`, então nada daqui entra em
conflito quando puxamos as atualizações deles.

```
brasil/
├── docker-compose.yml   PostgreSQL 18
├── .env               ← criado por você a partir de .env.example (não versionado)
├── api/                 Fastify + TypeORM  — contas, tokens, lista de servidores
└── launcher/            Tauri + Vue        — login, atualização automática
```

## Pré-requisitos

| Ferramenta | Para quê | Situação |
|---|---|---|
| [Bun](https://bun.sh) | runtime e gerenciador de pacotes | ✅ instalado |
| [Docker](https://docker.com) | PostgreSQL local | ✅ instalado |
| [Rust](https://rustup.rs) + MSVC Build Tools | compilar o launcher Tauri | ⚠️ **ainda não instalado** |

O Rust só é necessário para buildar o launcher. A API roda sem ele.

---

## Subindo o banco

```bash
cd brasil && cp .env.example .env && docker compose up -d
```

O Postgres sobe na porta definida em `POSTGRES_PORT` (padrão `5432`), com volume nomeado —
os dados sobrevivem a `docker compose down`. Para zerar tudo:

```bash
docker compose down -v
```

## Rodando a API

```bash
cd brasil/api && bun install && bun run dev
```

Sobe em `http://localhost:3000` com reload automático. Health check:

```bash
curl http://localhost:3000/health
```

Deve responder `{"status":"ok","database":"connected"}` — é a forma rápida de confirmar que
a API está de pé e que ela enxerga o Postgres.

### Estrutura da API

```
api/src/
├── server.ts       bootstrap do Fastify e registro de plugins
├── data-source.ts  configuração do TypeORM
├── entities/       entidades (Account, Session, Server...)
└── routes/         rotas agrupadas por assunto
```

## Launcher

Ainda não inicializado. Quando o Rust estiver instalado:

```bash
cd brasil && bun create tauri-app launcher --template vue-ts --manager bun
```

Preferimos o scaffold oficial a escrever a estrutura na mão — ele já configura a ponte
Rust ↔ Vue, os ícones e o `tauri.conf.json` corretamente para a versão atual.

---

## Como isso conversa com o jogo

O cliente do KaM lê o endereço do master server de um `.ini`, não de código compilado:

```ini
; KaM_Remake_Settings.ini
[Server]
MasterServerAddressNew=http://localhost:3000/
```

Ou seja: apontar o jogo para a nossa API **não exige recompilar nada**. Os PHPs em
[../Utils/MasterServer/](../Utils/MasterServer/) são a especificação do contrato que a
nossa API precisa atender (`serverquery`, `serveradd`, `servertime`).

O servidor de jogo em si é um processo separado — o `KaM_DedicatedServer`, binário Pascal
que escuta TCP na porta 56789 e hospeda várias salas. Ele roda **ao lado** da API, não
dentro dela. A API é a autoridade sobre contas e sobre quais servidores existem; o tráfego
de partida não passa por ela.
