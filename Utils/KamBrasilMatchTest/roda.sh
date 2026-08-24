#!/bin/sh
# Confere o leitor do arquivo de partida (src/net/KM_KamBrasilMatch.pas) contra
# o formato documentado no topo daquela unit -- que e o contrato com o launcher.
#
# Nao precisa do Delphi: compila so essa unit com FPC. Da raiz do repositorio:
#
#   docker run --rm -v "$PWD:/src" -w /src kam-fpc-base:latest sh Utils/KamBrasilMatchTest/roda.sh
#
# (kam-fpc-base e a mesma imagem usada para o servidor dedicado; serve qualquer
# uma com FPC 3.2+.)
set -e
raiz=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p /tmp/out
fpc -Mdelphi -Fi"$raiz" -Fu"$raiz/src/net" -FU/tmp/out "$raiz/Utils/KamBrasilMatchTest/teste_match.pas" -o/tmp/teste_match

falhas=0
caso() { # nome, conteudo do arquivo, linhas esperadas na saida
  nome="$1"; shift
  printf '%b' "$1" > /tmp/match.txt; shift
  saida=$(KAMBRASIL_MATCH_FILE=/tmp/match.txt /tmp/teste_match)
  erro=0
  for esp in "$@"; do
    if ! printf '%s\n' "$saida" | grep -qxF "$esp"; then
      echo "FALHOU [$nome]: esperava '$esp'"; erro=1
    fi
  done
  if [ "$erro" = 1 ]; then
    printf '%s\n' "$saida" | sed 's/^/    /'
    falhas=$((falhas+1))
  else
    echo "ok [$nome]"
  fi
}

caso "completo" 'servidor=203.0.113.10\nporta=56789\nsala=3\nsenha=segredo\n' \
  'disponivel=TRUE' 'servidor=203.0.113.10' 'porta=56789' 'sala=3' 'senha=[segredo]' \
  'arquivo_sumiu=TRUE' 'apos_usada=FALSE'

caso "sem porta e sem senha" 'servidor=kam.exemplo.com\nsala=0\n' \
  'disponivel=TRUE' 'porta=0' 'sala=0' 'senha=[]'

caso "ordem trocada, chave maiuscula, linha em branco e lixo" \
  '\nSALA=7\nlixo\nSenha=a=b\nServidor= 10.0.0.1 \n' \
  'disponivel=TRUE' 'servidor=10.0.0.1' 'sala=7' 'senha=[a=b]'

caso "sem servidor"           'sala=3\nporta=1234\n'                        'disponivel=FALSE'
caso "sem sala"               'servidor=10.0.0.1\n'                         'disponivel=FALSE'
caso "sala nao numerica"      'servidor=10.0.0.1\nsala=abc\n'               'disponivel=FALSE'
caso "porta fora de faixa"    'servidor=10.0.0.1\nsala=1\nporta=70000\n'    'disponivel=TRUE' 'porta=0'
caso "porta nao numerica"     'servidor=10.0.0.1\nsala=1\nporta=xx\n'       'disponivel=TRUE' 'porta=0'
caso "senha nao perde espaco" 'servidor=10.0.0.1\nsala=1\nsenha= x \n'      'senha=[ x ]'

# Jogo aberto sem launcher: nenhuma variavel de ambiente, nenhum auto-join.
if /tmp/teste_match | grep -qxF 'disponivel=FALSE'; then
  echo "ok [sem env]"
else
  echo "FALHOU [sem env]"; falhas=$((falhas+1))
fi

echo "falhas=$falhas"
test "$falhas" -eq 0
