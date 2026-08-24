unit KM_NetRanked;
{$I KaM_Remake.inc}
interface
uses
  Classes, SysUtils,
  KM_CommonTypes, KM_Defaults, KM_NetTypes;

// kam_brasil: as reservas de sala ranqueada, do jeito que a API as descreve.
//
// Esta unit nao fala rede nem HTTP. Ela so guarda "quem devia estar na sala 3,
// em que time, em que local, e como a partida terminou". Quem busca o texto da
// API e quem envia os pacotes e o TKMNetServer.
//
// A separacao existe porque o parsing das reservas e a maquina de estado do
// resultado sao justamente a parte que erra em silencio -- resultado perdido,
// abandono nao contado -- e da para ler os dois inteiros num arquivo so.

const
  // Decisao do dono: quem cai tem 3 minutos para voltar. Passou disso, a
  // partida e reportada como abandono: derrota para quem saiu, vitoria para o
  // outro time.
  RANKED_ABANDON_TIMEOUT = 3 * 60 * 1000;

  // Intervalo do polling das reservas. Mesmo numero que a rota /rooms documenta
  // do lado da API. Rapido o bastante para o jogador que acabou de sair da fila
  // nao esperar, devagar o bastante para nao ser trafego a toa num servidor que
  // fica ligado 24/7.
  RANKED_POLL_INTERVAL = 3000;

  // Times da reserva. A API fala 'A' e 'B'; o jogo fala Team: Integer.
  RANKED_TEAM_A = 1;
  RANKED_TEAM_B = 2;

type
  TKMRankedSlot = record
    Nickname: AnsiString;
    Team: Integer;               // RANKED_TEAM_A / RANKED_TEAM_B
    Loc: Integer;                // local inicial exigido; 0 = a reserva nao exige um
    Handle: TKMNetHandleIndex;   // NET_ADDRESS_EMPTY enquanto nao esta conectado
    AwaySince: Cardinal;         // TimeGet da queda; 0 = presente (ou nunca chegou)
    Outcome: TWonOrLost;
    Abandoned: Boolean;
  end;

  // Uma sala reservada. Metade reserva (o que a API mandou), metade estado vivo
  // (quem esta conectado agora, quem ja tem resultado).
  TKMRankedRoom = class
  public
    Room: Integer;
    MatchId: AnsiString;
    MapCRC: Cardinal;
    MapName: UnicodeString;      // vazio quando a reserva nao trouxe o nome do arquivo
    Peacetime: Word;
    Speed: Single;
    Count: Integer;
    Slots: array [1 .. MAX_LOBBY_SLOTS] of TKMRankedSlot;

    Live: Boolean;               // a partida saiu do lobby e esta rodando
    Started: Boolean;            // /started ja foi enviado
    Reported: Boolean;           // /report ja foi enviado
    Imposed: Boolean;            // a configuracao canonica ja foi empurrada para a sala
    Ticks: Integer;              // duracao vista no ultimo mkSetGameInfo
    // Ultima semente vista no mkGameOptions do host.
    //
    // Guardada porque a configuracao que impomos tem que ser fiel a ultima
    // valida, e nao a um TKMGameOptions recem-criado: reimpor com semente 0
    // depois de o host ja ter sorteado a dele daria desync na hora.
    Seed: Integer;

    function SlotOfNickname(const aNick: AnsiString): Integer;
    function SlotOfHandle(aHandle: TKMNetHandleIndex): Integer;
    function ConnectedCount: Integer;
    function EveryoneHere: Boolean;
    function ResultsComplete: Boolean;
    function TimedOutSlot: Integer;
    function WinnerTeam: string;
    procedure LoseByAbandon(aSlotIndex: Integer);
    function ReportQuery: string;
    function Describe: string;
  end;

  TKMRankedRooms = class
  private
    fList: TList;
    function ParseLine(const aLine: string; aRoom: TKMRankedRoom): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function Count: Integer;
    function Item(aIndex: Integer): TKMRankedRoom;
    function ByRoom(aRoom: Integer): TKMRankedRoom;
    function IsReserved(aRoom: Integer): Boolean;
    procedure Remove(aRoom: TKMRankedRoom);
    // Devolve um resumo do que mudou, para o log. Texto vazio = nada mudou.
    function Merge(const aText: string): string;
  end;

// Publicas porque o TKMNetServer monta a querystring de /started com as mesmas
// regras de escape.
function RankedTeamLetter(aTeam: Integer): string;
function RankedTeamFromLetter(const aLetter: string): Integer;
function RankedUrlEncode(const aText: AnsiString): string;

implementation
uses
  StrUtils,
  KM_CommonUtils;


// Percent-encoding byte a byte.
//
// O UrlEncode do URLUtils nao serve para nickname: ele encoda o Ord de cada
// WideChar em dois digitos hex, entao um 'c'-cedilha viraria %E7 -- Latin-1,
// nao os dois bytes de UTF-8 -- e a API decodificaria lixo. Aqui os bytes do
// AnsiString vao exatamente como estao.
//
// Escapamos tudo que nao e alfanumerico de proposito: e mais barato que
// carregar a tabela de caracteres reservados e o resultado decodifica igual.
function RankedUrlEncode(const aText: AnsiString): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(aText) do
    if aText[I] in ['0'..'9', 'A'..'Z', 'a'..'z'] then
      Result := Result + Char(aText[I])
    else
      Result := Result + '%' + IntToHex(Ord(aText[I]), 2);
end;


// Divide aText em aSep e joga os pedacos em aList.
//
// Nao usamos DelimitedText do TStringList de proposito: ele ainda interpreta
// aspas mesmo com StrictDelimiter, e um nickname com aspas quebraria a linha
// inteira em silencio.
procedure SplitChar(const aText: string; aSep: Char; aList: TStringList);
var
  I, start: Integer;
begin
  aList.Clear;
  start := 1;
  for I := 1 to Length(aText) do
    if aText[I] = aSep then
    begin
      aList.Add(Copy(aText, start, I - start));
      start := I + 1;
    end;
  aList.Add(Copy(aText, start, Length(aText) - start + 1));
end;


// StrToFloat depende do separador decimal do locale. A API sempre manda ponto,
// entao converter na mao evita que um servidor com locale pt_BR leia "1.5"
// como 15 e imponha velocidade 15x.
function StrToFloatDot(const aText: string; aDefault: Single): Single;
var
  I, dot: Integer;
  intPart, fracPart: Integer;
  scale: Single;
  neg: Boolean;
  s: string;
begin
  s := Trim(aText);
  if s = '' then Exit(aDefault);

  neg := s[1] = '-';
  if neg or (s[1] = '+') then
    s := Copy(s, 2, Length(s));

  dot := Pos('.', s);
  if dot = 0 then
  begin
    Result := StrToIntDef(s, Round(aDefault));
    if neg then Result := -Result;
    Exit;
  end;

  intPart := StrToIntDef(Copy(s, 1, dot - 1), 0);
  fracPart := 0;
  scale := 1;
  for I := dot + 1 to Length(s) do
  begin
    if not (s[I] in ['0'..'9']) then Exit(aDefault);
    fracPart := fracPart * 10 + (Ord(s[I]) - Ord('0'));
    scale := scale * 10;
  end;

  Result := intPart + fracPart / scale;
  if neg then Result := -Result;
end;


function RankedTeamLetter(aTeam: Integer): string;
begin
  case aTeam of
    RANKED_TEAM_A: Result := 'A';
    RANKED_TEAM_B: Result := 'B';
  else
    Result := '';
  end;
end;


function RankedTeamFromLetter(const aLetter: string): Integer;
begin
  if SameText(aLetter, 'A') then
    Result := RANKED_TEAM_A
  else
  if SameText(aLetter, 'B') then
    Result := RANKED_TEAM_B
  else
    Result := 0;
end;


{ TKMRankedRoom }
function TKMRankedRoom.SlotOfNickname(const aNick: AnsiString): Integer;
var
  I: Integer;
begin
  Result := -1;
  if aNick = '' then Exit;

  for I := 1 to Count do
    if Slots[I].Nickname = aNick then
      Exit(I);
end;


function TKMRankedRoom.SlotOfHandle(aHandle: TKMNetHandleIndex): Integer;
var
  I: Integer;
begin
  Result := -1;
  if aHandle = NET_ADDRESS_EMPTY then Exit;

  for I := 1 to Count do
    if Slots[I].Handle = aHandle then
      Exit(I);
end;


function TKMRankedRoom.ConnectedCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to Count do
    if Slots[I].Handle <> NET_ADDRESS_EMPTY then
      Inc(Result);
end;


function TKMRankedRoom.EveryoneHere: Boolean;
begin
  Result := (Count > 0) and (ConnectedCount = Count);
end;


function TKMRankedRoom.ResultsComplete: Boolean;
var
  I: Integer;
begin
  Result := Count > 0;
  for I := 1 to Count do
    if Slots[I].Outcome = wolNone then
      Exit(False);
end;


// Primeiro jogador que caiu e nao voltou dentro da janela, ou -1.
function TKMRankedRoom.TimedOutSlot: Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 1 to Count do
    if (Slots[I].AwaySince <> 0) and (TimeSince(Slots[I].AwaySince) > RANKED_ABANDON_TIMEOUT) then
      Exit(I);
end;


// 'A', 'B' ou '' quando nao da para dizer.
//
// Vazio inclui o caso em que os dois times tem vencedor: isso so acontece com
// resultado inconsistente (desync, cliente adulterado) e a API precisa poder
// invalidar a partida em vez de sortear um vencedor.
function TKMRankedRoom.WinnerTeam: string;
var
  I, winner: Integer;
begin
  winner := 0;
  for I := 1 to Count do
    if Slots[I].Outcome = wolWon then
    begin
      if (winner <> 0) and (winner <> Slots[I].Team) then
        Exit('');
      winner := Slots[I].Team;
    end;

  Result := RankedTeamLetter(winner);
end;


// Abandono: quem saiu perde, o time dele perde junto, o outro time ganha.
// Decisao do dono, item 3 do plano.
procedure TKMRankedRoom.LoseByAbandon(aSlotIndex: Integer);
var
  I: Integer;
begin
  Slots[aSlotIndex].Abandoned := True;
  Slots[aSlotIndex].Outcome := wolLost;

  for I := 1 to Count do
    if I <> aSlotIndex then
    begin
      if Slots[I].Team = Slots[aSlotIndex].Team then
        Slots[I].Outcome := wolLost
      else
        Slots[I].Outcome := wolWon;
    end;
end;


// Querystring do /internal/ranked/report, sem o secret (quem chama tem ele).
//
//   match=<uuid>&winner=A&ticks=18240&p=nick:A:won&p=nick:B:abandon
//
// Abandono vai no terceiro campo do p=, e nao numa chave separada: e o formato
// que a rota le (routes/ranked-internal.ts, parseJogador). Para o rating,
// 'abandon' conta como derrota; a diferenca e que ele tambem abre ficha de
// suspensao na conta.
function TKMRankedRoom.ReportQuery: string;
var
  I: Integer;
  outcome: string;
begin
  Result := 'match=' + RankedUrlEncode(MatchId)
          + '&winner=' + WinnerTeam
          + '&ticks=' + IntToStr(Ticks);

  for I := 1 to Count do
  begin
    if Slots[I].Abandoned then
      outcome := 'abandon'
    else
      case Slots[I].Outcome of
        wolWon:  outcome := 'won';
        wolLost: outcome := 'lost';
      else
        outcome := 'none';
      end;

    Result := Result + '&p=' + RankedUrlEncode(Slots[I].Nickname)
                     + ':' + RankedTeamLetter(Slots[I].Team)
                     + ':' + outcome;
  end;
end;


function TKMRankedRoom.Describe: string;
var
  I: Integer;
begin
  Result := Format('room %d match %s map %s (%d players)',
                   [Room, string(MatchId), IntToHex(Integer(MapCRC), 8), Count]);
  for I := 1 to Count do
    Result := Result + Format(' [%s %s loc %d]',
                              [string(Slots[I].Nickname), RankedTeamLetter(Slots[I].Team), Slots[I].Loc]);
end;


{ TKMRankedRooms }
constructor TKMRankedRooms.Create;
begin
  inherited;

  fList := TList.Create;
end;


destructor TKMRankedRooms.Destroy;
var
  I: Integer;
begin
  for I := 0 to fList.Count - 1 do
    TKMRankedRoom(fList[I]).Free;
  fList.Free;

  inherited;
end;


function TKMRankedRooms.Count: Integer;
begin
  Result := fList.Count;
end;


function TKMRankedRooms.Item(aIndex: Integer): TKMRankedRoom;
begin
  Result := TKMRankedRoom(fList[aIndex]);
end;


function TKMRankedRooms.ByRoom(aRoom: Integer): TKMRankedRoom;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to fList.Count - 1 do
    if TKMRankedRoom(fList[I]).Room = aRoom then
      Exit(TKMRankedRoom(fList[I]));
end;


function TKMRankedRooms.IsReserved(aRoom: Integer): Boolean;
begin
  Result := ByRoom(aRoom) <> nil;
end;


procedure TKMRankedRooms.Remove(aRoom: TKMRankedRoom);
begin
  fList.Remove(aRoom);
  aRoom.Free;
end;


// Le uma linha do /internal/ranked/rooms:
//
//   room=3;match=<uuid>;mapcrc=A1B2C3D4;map=Cursed Ravine;pt=15;spd=1;lock=1;p=nick:A:0;p=nick:B:1
//
// Chaves desconhecidas sao ignoradas de proposito: a API pode ganhar campos
// novos sem que um servidor antigo pare de aceitar reservas.
//
// Devolve False se a linha nao tem o minimo (sala, match e pelo menos um
// jogador) -- reserva pela metade e pior que reserva nenhuma, porque a sala
// ficaria travada sem nunca poder comecar.
function TKMRankedRooms.ParseLine(const aLine: string; aRoom: TKMRankedRoom): Boolean;
var
  fields: TStringList;
  I, eq, colon1, colon2: Integer;
  key, value, nick, teamStr: string;
begin
  Result := False;

  aRoom.Room := -1;
  aRoom.MatchId := '';
  aRoom.MapCRC := 0;
  aRoom.MapName := '';
  aRoom.Peacetime := 0;
  aRoom.Speed := 1;
  aRoom.Count := 0;

  fields := TStringList.Create;
  try
    SplitChar(aLine, ';', fields);

    for I := 0 to fields.Count - 1 do
    begin
      eq := Pos('=', fields[I]);
      if eq = 0 then Continue;

      key := LowerCase(Trim(Copy(fields[I], 1, eq - 1)));
      value := Trim(Copy(fields[I], eq + 1, Length(fields[I])));

      if key = 'room' then
        aRoom.Room := StrToIntDef(value, -1)
      else
      if key = 'match' then
        aRoom.MatchId := AnsiString(value)
      else
      if key = 'mapcrc' then
        aRoom.MapCRC := Cardinal(StrToInt64Def('$' + value, 0))
      else
      if key = 'map' then
        aRoom.MapName := UnicodeString(value)
      else
      if key = 'pt' then
        aRoom.Peacetime := StrToIntDef(value, 0)
      else
      if key = 'spd' then
        aRoom.Speed := StrToFloatDot(value, 1)
      else
      if key = 'p' then
      begin
        if aRoom.Count >= MAX_LOBBY_SLOTS then Continue;

        // Lido da direita para a esquerda: o nickname e a unica parte que pode
        // conter ':' sem quebrar o resto.
        colon2 := LastDelimiter(':', value);
        if colon2 = 0 then Continue;
        colon1 := LastDelimiter(':', Copy(value, 1, colon2 - 1));
        if colon1 = 0 then Continue;

        nick := Copy(value, 1, colon1 - 1);
        teamStr := Copy(value, colon1 + 1, colon2 - colon1 - 1);
        if nick = '' then Continue;

        Inc(aRoom.Count);
        aRoom.Slots[aRoom.Count].Nickname := AnsiString(nick);
        aRoom.Slots[aRoom.Count].Team := RankedTeamFromLetter(teamStr);
        aRoom.Slots[aRoom.Count].Loc := StrToIntDef(Copy(value, colon2 + 1, Length(value)), 0);
        aRoom.Slots[aRoom.Count].Handle := NET_ADDRESS_EMPTY;
        aRoom.Slots[aRoom.Count].AwaySince := 0;
        aRoom.Slots[aRoom.Count].Outcome := wolNone;
        aRoom.Slots[aRoom.Count].Abandoned := False;
      end;
    end;
  finally
    fields.Free;
  end;

  Result := (aRoom.Room >= 0) and (aRoom.MatchId <> '') and (aRoom.Count > 0);
end;


// Reconcilia a resposta da API com o que ja temos.
//
// Regra que importa: uma reserva que ja esta em andamento NUNCA e substituida
// pelo texto novo. O estado vivo (quem conectou, quem ganhou, quem caiu as
// 14:32) so existe aqui na memoria -- reparsear por cima dele apagaria o
// resultado de uma partida em curso a cada 5 segundos.
function TKMRankedRooms.Merge(const aText: string): string;
var
  lines: TStringList;
  fresh, existing: TKMRankedRoom;
  seen: array of Integer;
  I, K: Integer;
  keep: Boolean;
begin
  Result := '';

  lines := TStringList.Create;
  fresh := TKMRankedRoom.Create;
  try
    lines.Text := aText;
    SetLength(seen, 0);

    for I := 0 to lines.Count - 1 do
    begin
      if Trim(lines[I]) = '' then Continue;
      if not ParseLine(lines[I], fresh) then
      begin
        Result := Result + ' | linha ignorada: ' + Trim(lines[I]);
        Continue;
      end;

      SetLength(seen, Length(seen) + 1);
      seen[High(seen)] := fresh.Room;

      existing := ByRoom(fresh.Room);
      if existing <> nil then
      begin
        // Mesma reserva de antes: nada a fazer, o estado vivo continua valendo.
        if existing.MatchId = fresh.MatchId then Continue;

        // Reserva diferente numa sala que ainda tem partida para reportar.
        // Deixamos a antiga terminar; a nova entra no proximo polling.
        if existing.Live and not existing.Reported then
        begin
          Result := Result + Format(' | sala %d ainda reportando %s, nova reserva adiada',
                                    [existing.Room, string(existing.MatchId)]);
          Continue;
        end;

        Remove(existing);
      end;

      // Copia por valor: o 'fresh' e reaproveitado na proxima linha.
      existing := TKMRankedRoom.Create;
      existing.Room := fresh.Room;
      existing.MatchId := fresh.MatchId;
      existing.MapCRC := fresh.MapCRC;
      existing.MapName := fresh.MapName;
      existing.Peacetime := fresh.Peacetime;
      existing.Speed := fresh.Speed;
      existing.Count := fresh.Count;
      for K := 1 to fresh.Count do
        existing.Slots[K] := fresh.Slots[K];
      fList.Add(existing);

      Result := Result + ' | nova reserva: ' + existing.Describe;
    end;

    // Sumiu da lista da API: a reserva foi cancelada ou ja foi consumida.
    // So soltamos o que nao tem resultado pendente.
    for I := fList.Count - 1 downto 0 do
    begin
      existing := TKMRankedRoom(fList[I]);
      keep := False;
      for K := 0 to High(seen) do
        if seen[K] = existing.Room then
          keep := True;

      if not keep and not (existing.Live and not existing.Reported) then
      begin
        Result := Result + Format(' | reserva da sala %d liberada', [existing.Room]);
        Remove(existing);
      end;
    end;
  finally
    fresh.Free;
    lines.Free;
  end;
end;


end.
