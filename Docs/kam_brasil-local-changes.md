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
