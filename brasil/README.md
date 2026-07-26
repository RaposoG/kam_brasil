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

As migrations rodam sozinhas no boot — um deploy nunca sobe com schema defasado.

### Estrutura da API

```
api/src/
├── server.ts       bootstrap do Fastify
├── config.ts       env validado por zod (falha no boot se algo faltar)
├── data-source.ts  TypeORM
├── entities/       Account, Session, GameServer
├── migrations/     versionamento do schema
├── plugins/auth.ts JWT + verificação de sessão
└── routes/
    ├── auth.ts     contas
    └── master.ts   compatibilidade com o cliente do jogo
```

### Endpoints de conta

Todos em JSON. Enviar `Content-Type: application/json`.

| Método | Rota | O que faz |
|---|---|---|
| `POST` | `/auth/register` | `{ email, nickname, password }` → 201. 409 se email/nick em uso |
| `POST` | `/auth/login` | `{ login, password }` — `login` aceita email **ou** nickname → `{ token, expiresAt, account }` |
| `GET` | `/auth/me` | requer `Authorization: Bearer <token>` |
| `POST` | `/auth/logout` | revoga a sessão daquele token |

Regras aplicadas:

- **Nickname**: 3–16 caracteres, apenas `A-Z a-z 0-9 _ -`. O limite de 16 não é
  arbitrário: é o `MP_NICKNAME_LENGTH_MAX` do jogo. O charset restrito evita `|`
  (quebra de linha na UI do KaM) e `[$RRGGBB]` (código de cor).
- **Email e nickname** são únicos *case-insensitive*, garantidos por índice em
  `lower()` — não dá para registrar `Gabriel` e `gabriel`.
- **Senha**: mínimo 8 caracteres, guardada com **argon2id**.
- **Login errado e conta inexistente** devolvem a mesma mensagem, para não
  entregar quais emails existem.
- O JWT carrega o id da sessão em `jti`. Toda requisição autenticada confere a
  sessão no banco — sem isso, logout não teria efeito até o token expirar.

### Endpoints de release do cliente

| Método | Rota | O que faz |
|---|---|---|
| `GET` | `/client/latest` | versão que os jogadores devem estar rodando. 404 se nada publicado |
| `GET` | `/client/releases` | histórico das 20 últimas |
| `POST` | `/client/releases` | publica. Exige header `x-admin-token` |
| `GET` | `/downloads/<arquivo>` | serve o binário |

Para publicar: coloque o executável em `api/releases/` e chame

```bash
curl -X POST http://localhost:3000/client/releases \
  -H "x-admin-token: $ADMIN_TOKEN" -H 'content-type: application/json' \
  -d '{"version":"1.0.0","gameRevision":"r16155","fileName":"KaM_Brasil_1.0.0.exe"}'
```

A API calcula o **sha256 e o tamanho lendo o arquivo em disco**, em vez de
confiar no que foi enviado — assim o hash sempre corresponde ao que os clientes
vão de fato baixar. Releases são imutáveis: republicar a mesma versão dá 409,
porque isso invalidaria o hash que alguém já baixou.

Sem `ADMIN_TOKEN` no `.env`, a rota de publicação responde 503. É o padrão
seguro: ninguém publica por acidente.

### Endpoints do master server

Estas rotas existem para o **cliente do jogo**, que monta as URLs em
`KM_NetServerLocator.pas`. Os nomes e o formato de resposta são fixos no Pascal:
mudar qualquer coisa aqui exigiria recompilar o jogo. Respondem texto puro.

| Rota | Resposta |
|---|---|
| `GET /serveradd.php` | `success` — registra/atualiza um servidor |
| `GET /serverquery.php?rev=` | uma linha por servidor: `Nome,IP,Porta,Dedicado,SO` |
| `GET /announcements.php` | o `MOTD` do `.env`, exibido na aba multiplayer |
| `GET /maps.php` | `success` — o cliente reporta a partida jogada (só logamos) |

⚠️ **O parser do cliente exige exatamente 5 campos por linha** e faz split por
vírgula ([KM_NetServerPoller.pas](../src/net/KM_NetServerPoller.pas) → `AddFromText`).
Uma vírgula no nome do servidor gera 6 campos e a linha é **descartada em silêncio**.
Por isso `serveradd` sanitiza o nome removendo `,`, `|` e quebras de linha.

A listagem filtra por `rev` (o `NET_PROTOCOL_REVISON`): builds de protocolos
diferentes não se enxergam, que é o comportamento correto — elas não conseguiriam
jogar juntas mesmo.

### Como "só os nossos servidores" é garantido

O jogo **não envia credencial nenhuma** no `serveradd.php` — os parâmetros são
fixos no Pascal. A única forma de controlar quem entra na lista sem alterar o
cliente é filtrar pela origem, via `ANNOUNCE_ALLOWED_IPS` no `.env`.

Com a variável vazia, qualquer um anuncia (a API loga um aviso no boot). Em
produção, preencha com o IP do nosso servidor dedicado. Note que isso também
impede que jogadores hospedando partidas locais apareçam na lista — que é
exatamente o desenho pretendido.

Se a API estiver atrás de nginx ou Cloudflare, ligue `TRUST_PROXY=true`, senão
todo request chega com o IP do proxy e o allowlist vira inútil.

### Apontando o jogo para a API local

Crie `KaM Remake Server Settings.ini` na raiz do repositório:

```ini
[Server]
MasterServerAddressNew=http://localhost:3000/
```

Não é preciso recompilar nada — o endereço é lido do `.ini` em tempo de execução
([KM_ServerSettings.pas](../src/settings/KM_ServerSettings.pas)). Abra o jogo e
entre na aba Multijogador para ver a lista vinda da nossa API.

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
