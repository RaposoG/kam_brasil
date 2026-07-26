# Deploy da API

A API vive em `https://kam-api.melhorzin.com`, com rebuild automático a cada push
no GitHub.

## O que precisa existir no ambiente

Copie [.env.example](.env.example) e preencha. Os que **não** podem ficar no padrão:

| Variável | Por quê |
|---|---|
| `JWT_SECRET` | mínimo 32 caracteres. `openssl rand -hex 32` |
| `POSTGRES_PASSWORD` / `DATABASE_URL` | senha real, e `sslmode=require` se o banco for remoto |
| `ADMIN_TOKEN` | sem ele a publicação de releases fica desabilitada (503) |
| `TRUST_PROXY=true` | **obrigatório** atrás de nginx/Cloudflare |
| `ANNOUNCE_ALLOWED_IPS` | IP do servidor dedicado |
| `NODE_ENV=production` | desliga o log formatado e o modo verboso |

### `TRUST_PROXY` não é detalhe

Sem ele, `request.ip` devolve o IP do proxy. Como `ANNOUNCE_ALLOWED_IPS` e
`VERIFY_ALLOWED_IPS` comparam contra esse valor, todo request pareceria vir do
mesmo endereço — os dois allowlists viram enfeite.

## ⚠️ `RELEASES_DIR` precisa ser volume persistente

Uma release ocupa centenas de MB e mora em disco, não no banco. Com rebuild
automático a cada push, uma pasta dentro do container é **apagada a cada
deploy** — e todos os jogadores perdem a origem do download.

Monte um volume e aponte `RELEASES_DIR` para ele.

## Migrations

Rodam sozinhas no boot. Um deploy nunca sobe com schema defasado, e não há passo
manual entre o push e a API no ar.

## O servidor de jogo fica ao lado

O `KaM_DedicatedServer` é um processo separado, **na mesma máquina que a API**.
Isso não é conveniência, é requisito:

`GET /auth/verify` recebe o ticket **na query string, em texto claro** — porque o
cliente HTTP do Pascal (`KM_HTTPClient`) só faz GET, sem TLS e sem headers. Por
isso `VERIFY_ALLOWED_IPS` defaulta para `127.0.0.1` e a rota responde 403 para
qualquer outra origem.

Se algum dia o servidor de jogo precisar rodar em outra máquina, essa rota tem
que virar HTTPS antes — e isso exige mexer no Pascal.

Configuração do servidor dedicado (`KaM Remake Server Settings.ini`):

```ini
[Server]
MasterServerAddressNew=https://kam-api.melhorzin.com/
KamBrasilRequireAuth=1
KamBrasilAuthVerifyUrl=http://127.0.0.1:3000/auth/verify
UDPAnnounce=0
```

`UDPAnnounce=0` porque temos master server próprio; a descoberta UDP só
duplicaria o servidor na lista de quem estiver na mesma rede.

## Publicando uma release

1. Buildar `KaM_Remake.exe` e `Utils/RXXPacker/RXXPacker.exe` no Delphi
2. Copiar a árvore para uma pasta no servidor
3. Registrar:

```bash
curl -X POST https://kam-api.melhorzin.com/client/releases \
  -H "x-admin-token: $ADMIN_TOKEN" -H 'content-type: application/json' \
  -d '{"version":"1.0.0","gameRevision":"r16155","sourceDir":"/srv/kambrasil/staging"}'
```

A API percorre a pasta, calcula o sha256 de cada arquivo e escreve o manifesto.
Os hashes vêm sempre do disco, nunca do que foi informado.

**Não inclua** sprites, sons, músicas, `houses.dat` nem `unit.dat`. Eles vêm do
Knights and Merchants original e são gerados na máquina do jogador — a API
descarta esses caminhos automaticamente, mas o certo é não colocá-los ali.

## Checklist pós-deploy

```bash
curl https://kam-api.melhorzin.com/health          # {"status":"ok","database":"connected"}
curl https://kam-api.melhorzin.com/client/latest   # a release publicada
curl "https://kam-api.melhorzin.com/serverquery.php?rev=r16000"   # o servidor na lista
```

E confira que `GET /auth/verify` responde **403** de fora da máquina. Se
responder outra coisa, o allowlist não está valendo — provavelmente falta
`TRUST_PROXY=true`.
