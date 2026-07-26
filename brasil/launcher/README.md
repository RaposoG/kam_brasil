# launcher/ — Tauri + Vue

Ainda não inicializado. O launcher é responsável por:

1. **Login** — a tela de conta do Kam Brasil
2. **Atualização automática** — conferir a versão publicada na API e baixar o cliente novo
3. **Lançar o jogo** já autenticado, entregando o token ao `KaM_Remake.exe`

## Por que o login mora aqui e não dentro do jogo

Três motivos práticos:

- A UI do KaM é OpenGL desenhada à mão. Campo de texto, máscara de senha e foco de teclado
  seriam trabalho considerável, e cada ajuste exigiria abrir o RAD Studio e recompilar.
- O cliente HTTP embutido no jogo (`KM_HTTPClientOverbyte`) faz **apenas GET, sem TLS**.
  Login com senha exigiria escrever POST + HTTPS em Pascal. Aqui isso já vem pronto.
- Um executável em execução não consegue se sobrescrever no Windows. Auto-update **obriga**
  um segundo binário de qualquer forma — então o login mora onde já era necessário estar.

## ⚠️ O launcher é conveniência, não segurança

O cliente do jogo é open source e qualquer pessoa consegue compilar um que ignore o
launcher. Portanto:

- A validação do token **tem** que acontecer no `KaM_DedicatedServer`, no momento do join
- O **nickname tem que vir do servidor**, derivado do token — nunca ser enviado pelo cliente,
  senão personificação é trivial

O launcher torna a experiência agradável. O servidor é o que a torna verdadeira.

## Inicializando

Requer **Rust** ([rustup.rs](https://rustup.rs)) e o **Microsoft C++ Build Tools** —
nenhum dos dois está instalado nesta máquina ainda.

```bash
cd brasil && bun create tauri-app launcher --template vue-ts --manager bun
```

Usamos o scaffold oficial em vez de escrever a estrutura à mão: ele configura a ponte
Rust ↔ Vue, os ícones e o `tauri.conf.json` corretos para a versão atual do Tauri.

## Detalhe de implementação a não esquecer

Ao passar o token para o jogo, **não use argumento de linha de comando** — argumentos ficam
visíveis na lista de processos para qualquer usuário da máquina. Use arquivo temporário com
permissão restrita, ou stdin.
