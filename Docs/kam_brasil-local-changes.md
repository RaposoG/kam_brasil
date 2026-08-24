# Divergências locais do kam_brasil em relação ao upstream

Registro das alterações que este fork carrega sobre o `reyandme/kam_remake`. Todas são
pontuais e reversíveis. Mantenha esta lista atualizada — ela é o que evita que um
`git pull` do upstream traga surpresa.

Base: KaM Remake Beta **r16155** (`KM_Revision.inc`), protocolo de rede r16000.

---

## 1. `KaM_Remake.inc` — `USE_MAD_EXCEPT` desligado

```diff
-    {$DEFINE USE_MAD_EXCEPT}
+    {.$DEFINE USE_MAD_EXCEPT}
```

**Por quê:** o madExcept não está instalado nesta máquina. Ele é só o mecanismo de relatório
de crash ("Send Bug Report"); nada de gameplay depende dele.

**Como reverter:** instalar o madCollection (madshi.net) e reativar o define.

---

## 2. `KaM_Remake.inc` — `DBG_SKIP_SECURE_AUTH` ligado

```diff
-{.$DEFINE DBG_SKIP_SECURE_AUTH}
+{$DEFINE DBG_SKIP_SECURE_AUTH}
```

**Por quê:** `src/net/KM_NetAuthSecure.pas` não existe neste repositório — ele vem do repo
privado `kam_remake_private`, ao qual não temos acesso. O próprio `.inc` documenta este
define como a saída oficial para quem não tem o arquivo. Com ele, `KM_Networking` usa
`KM_NetAuthUnsecure`, um stub onde `GenerateChallenge` não faz nada e `ValidateSolution`
sempre retorna `True`.

**Efeito colateral:** `KM_Defaults.pas` carimba a versão do build com o sufixo ` [UNSECURE]`.

**Como reverter:** obter acesso ao repo privado e remover o define.

---

## 3. `src/common/KM_Defaults.pas` — `ALLOW_MP_MODS` forçado a `True`

```diff
-  ALLOW_MP_MODS           :Boolean = DEBUG_CFG;
+  ALLOW_MP_MODS           :Boolean = True;
```

**Por quê:** ao clicar em Multijogador, `TKMGameApp.CheckDATConsistency` compara

```pascal
gRes.GetDATCRC = DEFINES_CRC   // $28810991
```

onde `GetDATCRC = Houses xor Units xor MapElements xor Tileset` (Adler32 de cada conjunto,
ver `KM_Resource.pas`). Nossa combinação não bate e o jogo bloqueia a entrada com o texto
`TX_ERROR_MODS` ("Modificações no jogo não são permitidas no multiplayer").

Diagnóstico dos quatro componentes:

| Componente | Origem | Adler32 |
|---|---|---|
| `houses.dat` | KaM TPR local | `0x2FAB928B` |
| `unit.dat` | KaM TPR local | `0x912710A5` |
| `mapelem.dat` | repo (commit de 2013) | `0xEF363050` |
| Tileset (`tiles.json`) | repo (commit de 2022) | teria que ser `0x793BBBEF` |

A constante `DEFINES_CRC` foi revisada pela última vez em 2025-11-30, portanto é posterior
aos dois arquivos versionados no repo — eles estão corretos. O desvio está em `houses.dat`
e/ou `unit.dat`, extraídos de uma edição de TPR diferente da que o Remake usa como
referência. O próprio código já registra histórico de confusão com variantes
(`KM_GameApp.pas`: *"wrong defines\unit.dat was used by mistake (Scout sight = 18)"*).

### ⚠️ Consequência de manter isto ligado

Esta verificação existe para garantir que todos numa partida online usem os mesmos dados de
unidades e casas. Com ela desligada:

- **Partidas contra clientes com os `.dat` oficiais vão dessincronizar.** Os dados de
  gameplay são genuinamente diferentes, não é só um carimbo.
- Só jogue multiplayer entre builds que compartilhem **exatamente** estes mesmos
  `houses.dat` e `unit.dat`.
- Servidores públicos da comunidade assumem dados oficiais. Não é o lugar para este build.

### Correção de verdade (que dispensa esta alteração)

Substituir `data/defines/houses.dat` (51 KB) e `data/defines/unit.dat` (340 KB) pelos de uma
instalação TPR padrão — a versão **GOG** é a citada como compatível em
`Docs/Readme/getting-started_eng.md`. Feito isso, reverter `ALLOW_MP_MODS` para `DEBUG_CFG`.
Não exige recompilar nada além dessa reversão.

---

## 4. `KaM_Remake.inc` — `DBG_RNG_SPY` virou condicional

```diff
-{$DEFINE DBG_RNG_SPY}
+{$IFNDEF NO_RNG_SPY}
+  {$DEFINE DBG_RNG_SPY}
+{$ENDIF}
```

**Por quê:** o servidor dedicado não compilava com FPC. A cadeia é indireta:

```
KaM_DedicatedServer.dpr
  └─ KM_CommonUtils          {$IFDEF DBG_RNG_SPY} KM_RandomChecks
       └─ KM_RandomChecks    usa KM_GameSettings
            └─ KM_GameSettings  48 inline vars → FPC não compila
```

Como `DBG_RNG_SPY` estava ligado incondicionalmente, o servidor arrastava o
módulo de configuração do cliente inteiro. **Isto é um bug do upstream**: o
build dos servidores Linux (`bat/build_linux_servers.bat`, que usa `lazbuild`)
está quebrado no master atual pelo mesmo motivo.

O padrão `{$IFNDEF NO_...}` já é usado no mesmo arquivo para `LOAD_GAME_RES_ASYNC`,
então isso segue o idioma da casa. **O comportamento padrão não muda** — sem
`-dNO_RNG_SPY`, `DBG_RNG_SPY` continua definido exatamente como antes.

Bom candidato a PR para o upstream: conserta o build deles sem alterar default.

### Compilando o servidor dedicado com FPC

Não precisa de Delphi. Com o Lazarus instalado:

```
fpc -Mdelphi -O2 -dNO_RNG_SPY -Fi<repo> \
    -Fu<todos os subdiretorios de src, exceto unused/Samples/Virtual-TreeView/Overbyte> \
    -FuC:\lazarus\lcl\units\x86_64-win64 \
    -FuC:\lazarus\lcl\units\x86_64-win64\nogui \
    -FuC:\lazarus\components\lazutils\lib\x86_64-win64 \
    Utils\DedicatedServer\KaM_DedicatedServer.dpr
```

O widgetset `nogui` é o correto aqui: o `.dpr` puxa `Interfaces` da LCL mesmo
sendo aplicação console. É isso que abre caminho para buildar o servidor em CI,
sem depender da IDE do Delphi.

---

## 5. Autenticação de contas no multiplayer (Fase 1b)

Conjunto de mudanças que faz o servidor dedicado exigir conta do Kam Brasil.
**Desligado por padrão** (`KamBrasilRequireAuth=0`): um servidor exigindo token
antes de os clientes saberem enviá-lo deixaria a comunidade sem jogar.

### Arquivos tocados

| Arquivo | O quê |
|---|---|
| `src/net/KM_KamBrasilAuth.pas` | **novo** — lê o token entregue pelo launcher |
| `src/net/KM_NetTypes.pas` | `mkAuthToken`, `mkAuthNickname` + entradas em `NetPacketType` |
| `src/net/KM_NetConsts.pas` | `mkAuthNickname` na whitelist de `lgsConnecting` e `lgsReconnecting` |
| `src/net/KM_NetServer.pas` | fila de validação, recusa no join, imposição de nickname |
| `src/net/KM_Networking.pas` | envia o token, adota o nickname do servidor |
| `src/settings/KM_ServerSettings.pas` | `KamBrasilRequireAuth`, `KamBrasilAuthVerifyUrl` |
| `src/gui/pages_menu/KM_GUIMenuMultiplayer.pas` | campo de nickname vira `ReadOnly` |
| `KM_TextIDs.inc` + `.libx` | textos 1605 e 1606 |

### Como funciona

```
launcher → arquivo temporário + KAMBRASIL_TOKEN_FILE
         → jogo lê uma vez e apaga
         → mkAuthToken ao conectar
         → servidor: GET /auth/verify → "ok <nickname>"
         → mkAuthNickname de volta, ANTES da resposta do join
         → join liberado
```

### Armadilhas que custaram depuração

**Adicionar um `TKMNetMessageKind` exige três lugares.** O enum e o array
`NetPacketType` o compilador cobra. A whitelist `NET_ALLOWED_PACKETS_SET` ele
**não** cobra — o pacote é descartado em silêncio, em runtime.

**Recusar durante o join precisa ser `mkRefuseToJoin`, não `mkKicked`.** O
handler de `mkKicked` chama `OnDisconnect`, que só é atribuído depois de entrar
no lobby — antes disso é ponteiro nulo e o cliente estoura com access violation.

**A validação é assíncrona; o join chega antes.** O cliente manda `mkAuthToken`
e `mkJoinRoom` em sequência, e a resposta HTTP demora. O pedido de sala fica
guardado e é atendido quando a API responde.

**Fila, não paralelismo.** `TKMHTTPClient` atende uma requisição por vez — o
wrapper chama `Abort` a cada `GetURL` novo.

### Limitação conhecida

A verificação de `mkAskToJoin` cobre quem **entra** numa sala, não quem a
**cria**: o host se adiciona localmente sem enviar esse pacote. Para o cliente
oficial isso está resolvido (ele adota o nickname que o servidor manda), mas um
**cliente modificado que hospede** ainda pode usar qualquer nome. Fechar isso
exige validar o `mkPlayersList` difundido pelo host.

### Dependência frágil

O parsing do `mkAskToJoin` assume que a solução do challenge é vazia, o que só
vale porque compilamos com `DBG_SKIP_SECURE_AUTH`. Com `KM_NetAuthSecure` esse
trecho precisa ser revisto — está comentado no local.

---

## 6. Servidor dedicado como dono da sala ranqueada (Fase 0/1)

O servidor dedicado passa a consultar a API pelas **reservas de sala** e a impor a
configuração da partida, em vez de aceitar o que o host mandar. **Desligado por padrão**
(`KamBrasilRankedUrl` vazio): sem a URL configurada, nada disto roda e o servidor se
comporta exatamente como antes.

### Arquivos tocados

| Arquivo | O quê |
|---|---|
| `src/net/KM_NetRanked.pas` | **novo** — reservas, parsing do `/rooms` e máquina de resultado |
| `src/net/KM_NetServer.pas` | fila HTTP generalizada, imposição, bloqueios, reporte |
| `src/net/KM_NetRoom.pas` | `LoadFromStream` valida o `fCount` que vem da rede |
| `src/settings/KM_ServerSettings.pas` | `KamBrasilRankedUrl`, `KamBrasilRankedSecret` |
| `Utils/DedicatedServer/KaM_DedicatedServer.dpr` | liga `KM_NetRoom` + `KM_NetRanked` |
| `Utils/DedicatedServer/KM_NetRankedCheck.dpr` | **novo** — autoteste do `KM_NetRanked` |
| `KM_TextIDs.inc` + `.libx` | texto 1607 |

### Como funciona

```
API  ──GET /internal/ranked/rooms──►  servidor guarda a reserva da sala N
jogador entra na sala N            ►  só passa quem o AuthNickname coloca na reserva
sala fecha                         ►  servidor envia mkMapSelect/mkGameOptions/mkPlayersList
host difunde configuração          ►  só é repassada se bater com a reserva
partida sai do lobby               ►  GET /internal/ranked/started (semente + tick)
todos com WonOrLost, ou 3 min fora ►  GET /internal/ranked/report
```

### `NET_ROOM_HEADLESS`

`KM_NetRoom` linka no servidor dedicado sem arrastar `KM_Hand`/`KM_ResLocales` — ou seja,
sem a simulação e a pilha gráfica, que não compilam com FPC. O define é passado só no build
do servidor (`-dNET_ROOM_HEADLESS`, ver o `Dockerfile` do `gameserver`). O cliente Delphi
continua compilando a versão completa, sem define nenhum.

### Limite conhecido: o host ignora o `mkPlayersList` do servidor

`TKMNetworking.HandleMessage` só aplica `mkPlayersList`, `mkGameOptions` e `mkMapSelect`
quando o cliente é **joiner** — o host os descarta. Então a imposição prende os joiners, e
o host é preso pelas outras duas metades: o lobby travado no cliente e a recusa de repassar
qualquer pacote dele que divirja da reserva. Enquanto o cliente não souber montar o lobby a
partir da reserva, o `mkStart` de uma sala ranqueada é sempre recusado — de propósito.

---

## Arquivos copiados para dentro do repo (não versionados)

Tudo abaixo é coberto pelo `.gitignore`, então a working tree permanece limpa:

| Caminho | Origem |
|---|---|
| `data/gfx/*.bbm`, `*.lbm`, `*.dat` | `KaM - The Peasants Rebellion/data/gfx/` |
| `data/defines/houses.dat`, `unit.dat` | idem `data/defines/` |
| `data/sfx/` | idem (463 arquivos) |
| `Music/*.mp2` | `data/sfx/songs/*.sng` renomeados |
| `data/Sprites/*.rxx` | gerados pelo `Utils/RXXPacker` |
| `Maps/`, `MapsMP/`, `Campaigns/`, `Tutorials/` | `reyandme/kam_remake_maps` |

Regeneração dos sprites:

```
Utils/RXXPacker/RXXPacker.exe srx "<kam_remake_resources>\SpriteResource\" d "<repo>\data\Sprites\" all
```

O `SpriteResource` precisa conter tanto as pastas numeradas `2,3,4,5,7` do repo
`kam_remake_resources` quanto os `.rx` originais copiados de
`KaM - The Peasants Rebellion/data/gfx/res/`.

---

## Nota sobre compilação

O build é feito com **RAD Studio 12 Athens, edição Community**, e precisa ser **manual, pela
IDE** (Win32 / Release, já é o default do `.dproj`). O CE bloqueia compilação por linha de
comando — `dcc32.exe` responde *"This version of the product does not support command line
compiling"* —, o que inutiliza `bat/build_exe.bat` e os demais scripts baseados em msbuild.

Lazarus/FPC **não é alternativa**: o código usa inline variables (`var x := ...`, Delphi
10.3+) em 99 pontos de 18 arquivos, e o FPC não suporta essa sintaxe em versão nenhuma.
