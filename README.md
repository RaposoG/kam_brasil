# 🇧🇷 Kam Brasil

Fork do **KaM Remake** mantido pela comunidade brasileira de Knights and Merchants.

O objetivo do projeto é oferecer à comunidade BR uma experiência online própria — contas,
servidor gerenciado por nós, atualização automática e recursos que a gente decidir construir —
sem abrir mão de continuar acompanhando o desenvolvimento do KaM Remake original.

> Este é um projeto de comunidade, sem fins lucrativos. O KaM Remake é obra de
> **Krom, Lewin, Rey, Toxic** e muitos outros. Todo o crédito pela engine é deles.
> Upstream: <https://github.com/reyandme/kam_remake>

---

## 🎯 O que estamos construindo

| Etapa | Entrega |
|---|---|
| **Fase 0** | API própria (Fastify + PostgreSQL) substituindo o master server. Só nossos servidores aparecem na lista. |
| **Fase 1a** | Launcher em Tauri + Vue: login, contas e atualização automática do cliente. |
| **Fase 1b** | Servidor dedicado validando token de verdade — o nickname passa a vir da conta. |
| **Depois** | Ranking, temporadas, torneios, navegador de mapas, replays e estatísticas. |

Contas serão **públicas e gratuitas**: qualquer pessoa cria, com email e nickname únicos.

---

## 📁 Como este repositório está organizado

Este repositório contém **apenas o jogo** — o fork do KaM Remake em Delphi/Object Pascal.

A plataforma online (API de contas e launcher) vive em repositório próprio e privado,
`RaposoG/kam-brasil-api`. Ela não depende de uma linha do código do jogo, e separá-la
deixa o deploy dela rápido em vez de arrastar 1.700 arquivos de Pascal a cada push.

As alterações que este fork faz no jogo estão catalogadas em
**[Docs/kam_brasil-local-changes.md](Docs/kam_brasil-local-changes.md)** — a maioria em
arquivos novos, justamente para que `git pull` do `reyandme/kam_remake` não conflite.
Mantenha esse arquivo atualizado; ele é o que evita surpresa em merge.

---

## 🔨 Compilando o jogo

Requer **RAD Studio / Delphi 12 Athens** (a edição Community serve). O build é **manual, pela
IDE** — a Community Edition bloqueia compilação por linha de comando, o que inutiliza os
scripts em `bat/`.

1. Abrir `KaM_Remake.dproj` no RAD Studio
2. Plataforma **Windows 32-bit**, configuração **Release** (já é o padrão)
3. **Project → Build** (`Shift+F9`)

Para gerar os sprites a partir do KaM original, veja
[Docs/kam_brasil-local-changes.md](Docs/kam_brasil-local-changes.md).

> **Lazarus/FPC não compila o cliente.** O código usa inline variables (`var x := ...`,
> Delphi 10.3+) que o Free Pascal não suporta em versão nenhuma. O **servidor dedicado**,
> por outro lado, compila com FPC normalmente — é o que permite buildá-lo em CI para Linux.

## 🖥️ API e launcher

Ficam no repositório privado `RaposoG/kam-brasil-api`, com instruções próprias.

---

## 🎮 Requisitos para jogar

É necessário possuir o **Knights and Merchants: The Peasants Rebellion** original — o Kam
Brasil, como o KaM Remake, usa os arquivos de dados do jogo comercial. A versão da GOG é a
referência de compatibilidade.

---

## 📜 Licença e créditos

O uso comercial é proibido. Nomes, símbolos e demais materiais protegidos pertencem aos
respectivos donos. Consulte [LICENSE.txt](LICENSE.txt) e a documentação original em
[Docs/Readme/](Docs/Readme/).

Este fork não é afiliado à Joymania Entertainment, à TopWare nem à equipe do KaM Remake.
