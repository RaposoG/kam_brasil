# launcher/ — Tauri + Vue

Launcher do Kam Brasil. Responsável por:

1. **Login** — a tela de conta, contra a API em [`../api`](../api)
2. **Atualização automática** — conferir a versão publicada e baixar o cliente novo
3. **Lançar o jogo** já autenticado, entregando o token ao `KaM_Remake.exe`

## Rodando

```bash
cd brasil/launcher && bun install && bun run tauri dev
```

Só o frontend, sem a janela nativa (itera mais rápido no visual):

```bash
bun run dev
```

Build de distribuição:

```bash
bun run tauri build
```

### Pré-requisitos

Rust, MSVC Build Tools e WebView2 — todos já presentes nesta máquina
(Rust 1.97.1, Visual Studio 2026, WebView2 150.x). A primeira compilação do lado
Rust leva alguns minutos porque compila as dependências do Tauri do zero; as
seguintes são incrementais.

## Por que o login mora aqui e não dentro do jogo

Três motivos práticos:

- A UI do KaM é OpenGL desenhada à mão. Campo de texto, máscara de senha e foco
  de teclado seriam trabalho considerável, e cada ajuste exigiria abrir o RAD
  Studio e recompilar.
- O cliente HTTP embutido no jogo (`KM_HTTPClientOverbyte`) faz **apenas GET, sem
  TLS**. Login com senha exigiria escrever POST + HTTPS em Pascal.
- Um executável em execução não consegue se sobrescrever no Windows. Auto-update
  **obriga** um segundo binário de qualquer forma — então o login mora onde já
  era necessário estar.

## ⚠️ O launcher é conveniência, não segurança

O cliente do jogo é open source e qualquer pessoa consegue compilar um que ignore
o launcher. Portanto:

- A validação do token **tem** que acontecer no `KaM_DedicatedServer`, no join
- O **nickname tem que vir do servidor**, derivado do token — nunca ser enviado
  pelo cliente, senão personificação é trivial

O launcher torna a experiência agradável. O servidor é o que a torna verdadeira.

## Decisões de configuração

**`identifier: br.com.kambrasil.launcher`** — identificador do bundle, precisa ser
único e estável. Mudar depois quebra a associação de instalações existentes.

**CSP restrita** em `tauri.conf.json`: `connect-src` libera apenas `localhost:3000`
(desenvolvimento) e `*.kambrasil.com.br`. Sem isso a webview poderia falar com
qualquer host — e ela vai manipular token de sessão.

**TypeScript fixado em 5.9**, não 7. O `vue-tsc` 3.3.8 ainda importa
`typescript/lib/tsc`, que o port nativo do TS 7 não exporta mais — o build quebra
com `ERR_PACKAGE_PATH_NOT_EXPORTED`. A API em `../api` roda TS 7 normalmente,
porque não usa `vue-tsc`. Subir quando o `vue-tsc` suportar.

## Onde o jogo fica

Por padrão, numa pasta `game/` ao lado do executável do launcher. Durante o
desenvolvimento dá para apontar para outro lugar sem duplicar a instalação:

```bash
KAMBRASIL_GAME_DIR=F:\projects\kam_brasil bun run tauri dev
```

O launcher registra a versão instalada em `kambrasil.json`, ao lado do
executável. É mais confiável que tentar inferir a versão do binário — o formato
mudaria a cada build do Delphi.

## Atualização

`check_update` compara `kambrasil.json` com `GET /client/latest`. Quando difere,
`install_update` baixa para `KaM_Remake.exe.download`, confere o **sha256** e só
então promove o arquivo. Se o hash não bater, o download é apagado e a instalação
atual continua intacta — nunca ficamos com um executável truncado ou adulterado
em disco.

O progresso sai pelo evento `download-progress`.

## Nickname no jogo

Antes de lançar, o launcher grava o nickname da conta em `Game/Multiplayer/@Name`
no XML de settings do KaM. Isso faz o nick da conta já valer dentro do jogo, sem
alterar uma linha de Pascal.

É **conveniência, não autoridade** — o jogador ainda pode editar o XML na mão. A
imposição de verdade vem na Fase 1b, quando o servidor dedicado derivar o
nickname do token.

## Testes

```bash
cd brasil/api && bun run dev      # em outro terminal
cd brasil/launcher/src-tauri && cargo test -- --include-ignored
```

Os testes que falam com a API são marcados `#[ignore]` para não quebrarem um
`cargo test` de quem não subiu o ambiente. `ApiClient` e `download_verified` são
deliberadamente livres de tipos do Tauri: é o que permite exercitá-los sem subir
janela nenhuma.

## A fazer

- [ ] Entrega do token ao jogo. **Bloqueado na Fase 1b**: o cliente do KaM ainda
      não tem conceito de token, então não há o que entregar. Quando houver, o
      caminho é arquivo temporário ou stdin — nunca argumento de linha de
      comando, que aparece na lista de processos para qualquer usuário.
- [ ] Ícone próprio (ainda é o padrão do Tauri)
- [ ] Auto-update do próprio launcher
