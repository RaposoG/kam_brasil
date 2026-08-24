program KM_NetRankedCheck;
{$I ..\..\KaM_Remake.inc}
{$IFDEF MSWindows}
  {$APPTYPE CONSOLE}
{$ENDIF}

// kam_brasil: autoteste do KM_NetRanked.
//
// O parsing das reservas e a maquina de resultado sao a parte que erra em
// silencio -- uma vitoria perdida so aparece como "o rank nao mexeu". Este
// programa e a coisa mais barata que quebra quando ela quebra.
//
// Roda no mesmo FPC do servidor dedicado, com a mesma linha de -Fu:
//
//   fpc -Px86_64 -Mdelphi -dNET_ROOM_HEADLESS <-Fu de sempre> KM_NetRankedCheck.dpr
//   ./KM_NetRankedCheck    # exit 0 = tudo passou
//
// Sem framework de proposito: Check() abaixo e tudo que ele precisa, e Assert
// do FPC depende de flag de compilacao que o build do servidor nao liga.

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  KM_CommonTypes,
  KM_NetTypes,
  KM_NetRanked;

var
  gFailures: Integer;

procedure Check(aCondition: Boolean; const aWhat: string);
begin
  if aCondition then Exit;

  Inc(gFailures);
  Writeln('FALHOU: ', aWhat);
end;

procedure CheckStr(const aGot, aWant, aWhat: string);
begin
  if aGot = aWant then Exit;

  Inc(gFailures);
  Writeln('FALHOU: ', aWhat);
  Writeln('  esperado: ', aWant);
  Writeln('  obtido:   ', aGot);
end;


const
  LINE_2V2 = 'room=3;match=m-1;mapcrc=A1B2C3D4;map=Cursed Ravine;pt=15;spd=1.5;lock=1;'
           + 'p=ana:A:1;p=bia:A:2;p=caio:B:3;p=dudu:B:4';
  LINE_1V1 = 'room=0;match=m-2;mapcrc=DEADBEEF;pt=0;spd=1;p=alice:A:1;p=bob:B:2';


procedure TestParse;
var
  rooms: TKMRankedRooms;
  r: TKMRankedRoom;
begin
  rooms := TKMRankedRooms.Create;
  try
    rooms.Merge(LINE_2V2);
    Check(rooms.Count = 1, 'uma reserva parseada');

    r := rooms.ByRoom(3);
    Check(r <> nil, 'reserva indexada pela sala');
    if r = nil then Exit;

    CheckStr(string(r.MatchId), 'm-1', 'match id');
    Check(r.MapCRC = $A1B2C3D4, 'mapcrc lido como hexadecimal');
    CheckStr(r.MapName, 'Cursed Ravine', 'nome do mapa com espaco');
    Check(r.Peacetime = 15, 'peacetime');
    // spd=1.5 tem que virar 1.5 mesmo num locale que usa virgula decimal.
    Check(Abs(r.Speed - 1.5) < 0.0001, 'velocidade com ponto decimal');
    Check(r.Count = 4, 'quatro jogadores');
    CheckStr(string(r.Slots[1].Nickname), 'ana', 'primeiro nickname');
    Check(r.Slots[1].Team = RANKED_TEAM_A, 'time A');
    Check(r.Slots[3].Team = RANKED_TEAM_B, 'time B');
    Check(r.Slots[4].Loc = 4, 'local inicial');
    Check(r.Slots[1].Handle = NET_ADDRESS_EMPTY, 'ninguem conectado ainda');
    Check(r.SlotOfNickname('caio') = 3, 'busca por nickname');
    Check(r.SlotOfNickname('estranho') = -1, 'nickname de fora nao acha slot');
  finally
    rooms.Free;
  end;
end;


procedure TestParseTolerancia;
var
  rooms: TKMRankedRooms;
  r: TKMRankedRoom;
begin
  rooms := TKMRankedRooms.Create;
  try
    // Chave desconhecida no meio nao pode derrubar a linha: a API vai ganhar
    // campos e um servidor antigo tem que continuar aceitando reservas.
    rooms.Merge('room=1;match=m-9;futuro=xyz;mapcrc=1;p=zed:A:1');
    Check(rooms.ByRoom(1) <> nil, 'chave desconhecida ignorada');

    // Linha sem jogador nenhum e reserva pela metade: travaria a sala sem
    // nunca poder comecar.
    rooms.Merge('room=1;match=m-9;futuro=xyz;mapcrc=1;p=zed:A:1' + sLineBreak + 'room=2;match=m-8;mapcrc=1');
    Check(rooms.ByRoom(2) = nil, 'linha sem jogadores recusada');

    // Nickname com ':' -- lemos da direita para a esquerda justamente por isso.
    rooms.Merge('room=5;match=m-7;mapcrc=1;p=a:b:A:7');
    r := rooms.ByRoom(5);
    Check(r <> nil, 'linha com nickname esquisito aceita');
    if r <> nil then
    begin
      CheckStr(string(r.Slots[1].Nickname), 'a:b', 'nickname com dois-pontos');
      Check(r.Slots[1].Loc = 7, 'local depois do nickname esquisito');
    end;
  finally
    rooms.Free;
  end;
end;


procedure TestMergePreservaEstado;
var
  rooms: TKMRankedRooms;
  r: TKMRankedRoom;
begin
  rooms := TKMRankedRooms.Create;
  try
    rooms.Merge(LINE_1V1);
    r := rooms.ByRoom(0);
    Check(r <> nil, 'reserva criada');
    if r = nil then Exit;

    // Estado vivo: so existe na memoria do servidor.
    r.Slots[1].Handle := 42;
    r.Slots[1].Outcome := wolWon;
    r.Live := True;

    // O polling roda a cada 5s com o mesmo texto. Se ele reparseasse por cima,
    // apagaria o resultado de uma partida em curso a cada volta.
    rooms.Merge(LINE_1V1);
    r := rooms.ByRoom(0);
    Check(r <> nil, 'reserva sobreviveu ao merge repetido');
    if r = nil then Exit;
    Check(r.Slots[1].Handle = 42, 'handle preservado');
    Check(r.Slots[1].Outcome = wolWon, 'resultado preservado');

    // Reserva nova na mesma sala nao pode atropelar partida por reportar.
    rooms.Merge('room=0;match=m-OUTRO;mapcrc=1;p=zed:A:1');
    r := rooms.ByRoom(0);
    CheckStr(string(r.MatchId), 'm-2', 'reserva nova adiada enquanto ha resultado pendente');

    // Sumiu da lista da API, mas ainda tem resultado a mandar: seguramos.
    rooms.Merge('');
    Check(rooms.ByRoom(0) <> nil, 'partida viva nao e liberada por sumir da lista');

    // Depois de reportada, a sala pode ser solta.
    rooms.ByRoom(0).Reported := True;
    rooms.Merge('');
    Check(rooms.ByRoom(0) = nil, 'reserva reportada e liberada');
  finally
    rooms.Free;
  end;
end;


procedure TestResultado;
var
  rooms: TKMRankedRooms;
  r: TKMRankedRoom;
begin
  rooms := TKMRankedRooms.Create;
  try
    rooms.Merge(LINE_1V1);
    r := rooms.ByRoom(0);
    if r = nil then
    begin
      Check(False, 'reserva 1v1 criada');
      Exit;
    end;

    Check(not r.ResultsComplete, 'sem resultado no comeco');
    CheckStr(r.WinnerTeam, '', 'sem vencedor no comeco');

    r.Slots[1].Outcome := wolWon;
    Check(not r.ResultsComplete, 'resultado de um so nao fecha a partida');

    r.Slots[2].Outcome := wolLost;
    Check(r.ResultsComplete, 'todos com resultado fecha a partida');
    CheckStr(r.WinnerTeam, 'A', 'vencedor pelo time de quem ganhou');

    // Dois times "vencedores" so acontece com resultado inconsistente. A API
    // precisa poder invalidar a partida, entao nao sorteamos um vencedor.
    r.Slots[2].Outcome := wolWon;
    CheckStr(r.WinnerTeam, '', 'vitoria dos dois lados nao elege vencedor');

    r.Ticks := 100;
    r.Slots[1].Outcome := wolWon;
    r.Slots[2].Outcome := wolLost;
    // O '-' do uuid sai como %2D: escapamos tudo que nao e alfanumerico, e a
    // API decodifica de volta. Nickname vai byte a byte, entao acento nenhum
    // chega truncado do outro lado.
    CheckStr(r.ReportQuery,
             'match=m%2D2&winner=A&ticks=100&p=alice:A:won&p=bob:B:lost',
             'querystring do report');
    CheckStr(RankedUrlEncode('a b'), 'a%20b', 'espaco escapado no nickname');
    CheckStr(RankedUrlEncode(#$C3#$A7), '%C3%A7', 'utf-8 escapado byte a byte');
  finally
    rooms.Free;
  end;
end;


procedure TestAbandono;
var
  rooms: TKMRankedRooms;
  r: TKMRankedRoom;
begin
  rooms := TKMRankedRooms.Create;
  try
    rooms.Merge(LINE_2V2);
    r := rooms.ByRoom(3);
    if r = nil then
    begin
      Check(False, 'reserva 2v2 criada');
      Exit;
    end;

    // Decisao do dono: quem sai perde, o time dele perde junto, o outro ganha.
    r.LoseByAbandon(2); // bia, time A
    Check(r.Slots[2].Outcome = wolLost, 'quem abandonou perde');
    Check(r.Slots[2].Abandoned, 'quem abandonou fica marcado');
    Check(r.Slots[1].Outcome = wolLost, 'o time de quem abandonou perde junto');
    Check(not r.Slots[1].Abandoned, 'quem ficou nao e marcado como abandono');
    Check(r.Slots[3].Outcome = wolWon, 'o outro time ganha');
    Check(r.Slots[4].Outcome = wolWon, 'o outro time inteiro ganha');
    CheckStr(r.WinnerTeam, 'B', 'vencedor por abandono');
    Check(Pos('p=bia:A:abandon', r.ReportQuery) > 0, 'abandono vai no terceiro campo do p=');

    // Relogio dos 3 minutos: so conta para quem esta fora.
    Check(r.TimedOutSlot = -1, 'ninguem fora, ninguem estourado');
    r.Slots[3].AwaySince := 1; // TimeGet=1 e um passado remoto o suficiente
    Check(r.TimedOutSlot = 3, 'quem esta fora ha muito tempo estoura');
  finally
    rooms.Free;
  end;
end;


procedure TestPresenca;
var
  rooms: TKMRankedRooms;
  r: TKMRankedRoom;
begin
  rooms := TKMRankedRooms.Create;
  try
    rooms.Merge(LINE_1V1);
    r := rooms.ByRoom(0);
    if r = nil then
    begin
      Check(False, 'reserva 1v1 criada');
      Exit;
    end;

    Check(not r.EveryoneHere, 'sala vazia nao esta cheia');
    r.Slots[1].Handle := 10;
    Check(r.ConnectedCount = 1, 'um conectado');
    Check(not r.EveryoneHere, 'faltando um, a sala nao fecha');
    r.Slots[2].Handle := 11;
    Check(r.EveryoneHere, 'todos presentes fecha a sala');
    Check(r.SlotOfHandle(11) = 2, 'busca por handle');
    Check(r.SlotOfHandle(NET_ADDRESS_EMPTY) = -1, 'handle vazio nunca casa com quem nao chegou');
  finally
    rooms.Free;
  end;
end;


begin
  gFailures := 0;

  TestParse;
  TestParseTolerancia;
  TestMergePreservaEstado;
  TestResultado;
  TestAbandono;
  TestPresenca;

  if gFailures = 0 then
    Writeln('KM_NetRanked: OK')
  else
    Writeln('KM_NetRanked: ', gFailures, ' verificacao(oes) falharam');

  ExitCode := Ord(gFailures <> 0);
end.
