unit KM_KamBrasilMatch;
{$I KaM_Remake.inc}
interface

// Partida da fila ranqueada, entregue pelo launcher.
//
// Mesmo canal do token de sessao (ver KM_KamBrasilAuth): o launcher grava um
// arquivo temporario e passa o CAMINHO dele pela variavel de ambiente
// KAMBRASIL_MATCH_FILE. Nao vai por argumento de linha de comando -- argumento
// aparece na lista de processos para qualquer usuario da maquina, e a senha da
// sala iria junto.
//
// ---------------------------------------------------------------------------
// FORMATO DO ARQUIVO  (este e o contrato com o lado Rust -- launcher/src-tauri)
// ---------------------------------------------------------------------------
// Texto puro, uma chave por linha, `chave=valor`. Exemplo completo:
//
//     servidor=203.0.113.10
//     porta=56789
//     sala=3
//     senha=
//
//   servidor  OBRIGATORIO. IP ou hostname do servidor dedicado.
//             A chave chama-se "servidor", NAO "ip" -- do lado do launcher o
//             campo se chama `ip`, e escrever `ip=` aqui nao le nada.
//   sala      OBRIGATORIO. Numero da sala reservada, o mesmo que a API devolveu.
//   porta     OPCIONAL. Ausente, vazia, 0 ou fora de 1..65535 => o jogo usa a
//             porta padrao dele.
//   senha     OPCIONAL. Ausente ou vazia => sala sem senha. E o caso normal da
//             ranqueada: o servidor recusa mkSetPassword em sala reservada.
//
// Regras de leitura:
//   - linhas em branco e chaves desconhecidas sao ignoradas;
//   - o nome da chave nao diferencia maiuscula de minuscula, o valor sim;
//   - o valor e o resto da linha depois do primeiro '=', cru. Nada de aspas:
//     `senha="x"` entrega a senha `"x"`, com aspas e tudo;
//   - espaco em volta e removido de servidor/porta/sala, NAO da senha;
//   - a ordem das linhas nao importa;
//   - sem servidor ou sem sala o arquivo inteiro e descartado -- meia reserva
//     mandaria o jogador para uma sala qualquer, que e pior que nao entrar.
//
// O arquivo e lido UMA vez e apagado em seguida, pelo mesmo motivo do token: se
// ficasse em disco, a proxima abertura do jogo tentaria entrar numa sala que ja
// acabou.
//
// Sem launcher (jogo aberto direto), Disponivel = False e o menu multijogador
// se comporta exatamente como sempre.

type
  TKMKamBrasilMatch = record
    Disponivel: Boolean;
    Servidor: string;
    Porta: Word;       // 0 = usar a porta padrao do jogo
    Sala: Integer;
    Senha: AnsiString; // '' = sala sem senha
  end;

// Le (na primeira chamada) e devolve a partida pendente. Chamadas seguintes
// devolvem a mesma coisa sem tocar em disco.
function KamBrasilMatch: TKMKamBrasilMatch;

// Marca a partida como consumida. Quem mandou entrar na sala chama isto para
// que uma volta ao menu nao tente entrar de novo.
procedure KamBrasilMatchUsada;


// ---------------------------------------------------------------------------
// SINAL "ESTOU NUMA SALA RANQUEADA"
// ---------------------------------------------------------------------------
// Numa sala ranqueada quem monta a partida e o servidor dedicado: ele manda
// mkMapSelect / mkGameOptions / mkPlayersList com a configuracao da reserva.
// O cliente oficial so aplicava esses tres sendo JOINER, entao quem entrasse
// primeiro virava host, ignorava a imposicao e anunciava o proprio estado. O
// servidor recusava e reimpunha, para sempre -- a briga em laco do teste ao
// vivo. Este sinal existe para o host tambem obedecer.
//
// LIGA: KamBrasilEntrouNaRanqueada, chamado no auto-join
//   (TKMMenuMultiplayer.MP_KamBrasilAutoJoin), logo antes de conectar. E o
//   unico ponto do jogo que sabe que a sala veio da fila.
//
// DESLIGA: KamBrasilSaiuDaRanqueada, chamado em TKMNetworking.Disconnect.
//   Disconnect e o funil por onde se sai de QUALQUER sala -- voltar do lobby,
//   ser kickado, falhar a conexao/senha, e o fim da partida (gGameApp.StopGame
//   desconecta antes de voltar ao menu). Amarrar o desligamento a ele e de
//   proposito: enquanto ha conexao a sala e a mesma, e sem conexao nao existe
//   ranqueada. Ficar preso em True faria o proximo jogo casual do jogador abrir
//   com o lobby travado e o host obedecendo pacote que ninguem mandou.
//   (AttemptReconnection chama Join, nao Disconnect, entao reconectar no meio
//   de uma ranqueada mantem o sinal ligado -- que e o certo.)
//
// ISTO NAO E SEGURANCA, E COOPERACAO. Um cliente adulterado simplesmente nao
// chama KamBrasilEntrouNaRanqueada e volta a se comportar como host comum.
// Quem GARANTE a configuracao e o servidor dedicado, que se recusa a repassar
// mkMapSelect/mkGameOptions/mkPlayersList/mkStart divergentes da reserva (ver
// TKMNetServer.RankedRelayAllowed) e reimpoe a configuracao correta. O sinal
// daqui so serve para o cliente honesto obedecer sem brigar, e para o jogador
// nao clicar num controle cujo efeito o servidor ja vai descartar.
function KamBrasilEmRanqueada: Boolean;
procedure KamBrasilEntrouNaRanqueada;
procedure KamBrasilSaiuDaRanqueada;

implementation
uses
  SysUtils, Classes;

const
  MATCH_ENV_VAR = 'KAMBRASIL_MATCH_FILE';

var
  gMatch: TKMKamBrasilMatch;
  gLoaded: Boolean;
  gEmRanqueada: Boolean;


function KamBrasilMatch: TKMKamBrasilMatch;
var
  path: string;
  porta: Integer;
  sl: TStringList;
begin
  if not gLoaded then
  begin
    gLoaded := True;
    gMatch.Disponivel := False;
    gMatch.Servidor := '';
    gMatch.Porta := 0;
    gMatch.Sala := -1;
    gMatch.Senha := '';

    path := GetEnvironmentVariable(MATCH_ENV_VAR);
    if (path <> '') and FileExists(path) then
    begin
      sl := TStringList.Create;
      try
        try
          sl.NameValueSeparator := '=';
          sl.LoadFromFile(path);

          gMatch.Servidor := Trim(sl.Values['servidor']);
          gMatch.Sala     := StrToIntDef(Trim(sl.Values['sala']), -1);
          gMatch.Senha    := AnsiString(sl.Values['senha']);

          // Porta fora de faixa vira 0 (= padrao do jogo) em vez de estourar um
          // Word: numero digitado errado no launcher nao pode virar excecao aqui.
          porta := StrToIntDef(Trim(sl.Values['porta']), 0);
          if (porta > 0) and (porta <= 65535) then
            gMatch.Porta := porta;

          gMatch.Disponivel := (gMatch.Servidor <> '') and (gMatch.Sala >= 0);
        except
          // Arquivo ilegivel e o mesmo que nao ter partida: o jogo abre no menu.
          gMatch.Disponivel := False;
        end;
      finally
        sl.Free;
      end;

      SysUtils.DeleteFile(path);
    end;
  end;

  Result := gMatch;
end;


procedure KamBrasilMatchUsada;
begin
  KamBrasilMatch; // garante que o arquivo ja foi lido e apagado
  gMatch.Disponivel := False;
end;


function KamBrasilEmRanqueada: Boolean;
begin
  Result := gEmRanqueada;
end;


procedure KamBrasilEntrouNaRanqueada;
begin
  gEmRanqueada := True;
end;


procedure KamBrasilSaiuDaRanqueada;
begin
  gEmRanqueada := False;
end;


initialization
  gLoaded := False;
  gMatch.Disponivel := False;
  gEmRanqueada := False;

end.
