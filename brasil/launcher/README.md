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

## A fazer

- [ ] Tela de login consumindo `POST /auth/login`
- [ ] Guardar o token com segurança (não em `localStorage` — a webview é acessível)
- [ ] Checagem de versão contra a API antes de liberar o "Jogar"
- [ ] Download e substituição do `KaM_Remake.exe`
- [ ] Entrega do token ao jogo — **por arquivo temporário ou stdin**, nunca por
      argumento de linha de comando: argumentos aparecem na lista de processos
      para qualquer usuário da máquina
