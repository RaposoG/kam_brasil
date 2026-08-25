unit KM_NetServer;
{$I KaM_Remake.inc}
interface
uses
  {$IFDEF MSWINDOWS}Windows, {$ENDIF}
   {$IFDEF WDC}KM_NetServerOverbyte, {$ENDIF}
   {$IFDEF FPC}KM_NetServerLNet, {$ENDIF}
  Classes, SysUtils, Math, VerySimpleXML,
  KM_CommonClasses, KM_NetGameInfo, KM_NetTypes,
  KM_Defaults, KM_CommonUtils, KM_CommonTypes,
  KM_HTTPClient, // kam_brasil: validacao de token contra a nossa API
  KM_GameOptions, // kam_brasil: para conferir o mkGameOptions do host
  KM_NetRanked,   // kam_brasil: reservas de sala ranqueada
  KM_NetRoom,     // kam_brasil: monta/le o mkPlayersList sem a simulacao (NET_ROOM_HEADLESS)
  {$IFDEF WDC}
    {$IFDEF CONSOLE}
      KM_ConsoleTimer
    {$ELSE}
      ExtCtrls
    {$ENDIF}
  {$ELSE}
    FPTimer
    {$IFDEF UNIX}
      , cthreads
    {$ENDIF}
  {$ENDIF};


{ Contains basic items we need for smooth Net experience:

    - start the server
    - stop the server

    - optionaly report non-important status messages

    - generate replies/messages:
      1. player# has disconnected
      2. player# binding (ID)
      3. players ping
      4. players IPs
      5. ...

    - handle orders from Host
      0. declaration of host (associate Hoster rights with this player)
      1. kick player#
      2. request for players ping
      3. request for players IPs
      4. ...
}

type
  // kam_brasil: o que a fila HTTP esta atendendo agora. Existe porque
  // TKMHTTPClient tem um unico par OnReceive/OnError -- sem o tipo do pedido em
  // curso a resposta chegaria sem dono.
  TKMHttpReqKind = (
    hrkNone,          // ocioso
    hrkAuth,          // GET /auth/verify -- resposta define quem e o cliente
    hrkRankedRooms,   // GET /internal/ranked/rooms -- resposta traz as reservas
    hrkRankedNotify   // /started e /report -- resposta so interessa para o log
  );

  TKMServerClient = class
  private
    fHandle: TKMNetHandleIndex;
    fRoom: Integer;
    fPingStarted: Cardinal;
    fPing: Word;
    fFPS: Word;
    //Each client must have their own receive buffer, so partial messages don't get mixed
    fBufferSize: Cardinal;
    fBuffer: array of Byte;
    //DoSendData(aRecipient: Integer; aData: Pointer; aLength: Cardinal);

    fQueuedPacketsCnt: Byte;
    fQueuedPacketsSize: Cardinal;
    fQueuedPackets: array of Byte;

    // kam_brasil: nickname confirmado pela nossa API. Vazio = ainda nao
    // autenticado. So e consultado quando RequireAuth esta ligado.
    fAuthNickname: AnsiString;
    // Token recebido e ainda em validacao. O cliente manda mkAuthToken e logo
    // em seguida mkJoinRoom, entao o pedido de sala quase sempre chega ANTES da
    // resposta HTTP -- precisamos segurar o join em vez de recusar.
    fAuthPending: Boolean;
    fJoinDeferred: Boolean;
    fJoinRoom: Integer;
    fJoinGameRev: TKMGameRevision;
    // TimeGet de quando o join ficou preso esperando as reservas ranqueadas.
    // 0 = nunca esperou. Serve para segurar o pedido UMA vez: a segunda passada
    // pela guarda ja e a decisao final.
    fRankedWaitSince: Cardinal;
  public
    constructor Create(aHandle: TKMNetHandleIndex; aRoom: Integer);
    procedure AddQueuedPacket(aData: Pointer; aLength: Cardinal);
    procedure ClearQueuedPackets;
    property Handle: TKMNetHandleIndex read fHandle; //ReadOnly
    property Room: Integer read fRoom write fRoom;
    property Ping: Word read fPing write fPing;
    property FPS: Word read fFPS write fFPS;
    property AuthNickname: AnsiString read fAuthNickname write fAuthNickname;
    property AuthPending: Boolean read fAuthPending write fAuthPending;
    property JoinDeferred: Boolean read fJoinDeferred write fJoinDeferred;
    property JoinRoom: Integer read fJoinRoom write fJoinRoom;
    property JoinGameRev: TKMGameRevision read fJoinGameRev write fJoinGameRev;
    property RankedWaitSince: Cardinal read fRankedWaitSince write fRankedWaitSince;
  end;


  TKMClientsList = class
  private
    fCount: Integer;
    fItems: array of TKMServerClient;
    function GetItem(aIndex: Integer):TKMServerClient;
  public
    destructor Destroy; override;
    property Count: Integer read fCount;
    procedure AddPlayer(aHandle: TKMNetHandleIndex; aRoom: Integer);
    procedure RemPlayer(aHandle: TKMNetHandleIndex);
    procedure Clear;
    property Item[aIndex: Integer]: TKMServerClient read GetItem; default;
    function GetByHandle(aHandle: TKMNetHandleIndex): TKMServerClient;
  end;


  TKMNetServer = class
  private
    {$IFDEF WDC} fServer: TKMNetServerOverbyte; {$ENDIF}
    {$IFDEF FPC} fServer: TKMNetServerLNet;     {$ENDIF}

    {$IFDEF WDC}
      {$IFDEF CONSOLE}
      fTimer: TKMConsoleTimer; //Use our custom TKMConsoleTimer instead of ExtCtrls.TTimer, to be able to use it in console application (DedicatedServer)
      {$ELSE}
      fTimer: TTimer;
      {$ENDIF}
    {$ELSE}
      fTimer: TFPTimer;
    {$ENDIF}

    fClientList: TKMClientsList;
    fListening: Boolean;
    fBytesTX: Int64; // Servers work 24/7 for weeks. We may exceed 4GB allowed by cardinal
    fBytesRX: Int64;

    fPacketsAccumulatingDelay: Integer;
    fMaxRooms: Word;
    fHTMLStatusFile: String;
    fWelcomeMessage: UnicodeString;
    fServerName: AnsiString;
    fKickTimeout: Word;
    fRoomCount: Integer;
    fEmptyGameInfo: TKMNetGameInfo;
    fGameFilter: TKMPGameFilter;
    fRoomInfo: array of record
                         HostHandle: TKMNetHandleIndex;
                         GameRevision: TKMGameRevision;
                         Password: AnsiString;
                         BannedIPs: array of String;
                         GameInfo: TKMNetGameInfo;
                       end;

    // kam_brasil: conversa com a nossa API -- autenticacao de jogadores e
    // reservas de sala ranqueada.
    //
    // TKMHTTPClient atende UMA requisicao por vez (o wrapper chama Abort a cada
    // GetURL novo), entao tudo passa por uma fila em vez de ser disparado em
    // paralelo -- senao dois jogadores entrando juntos se atropelariam e um
    // deles seria recusado sem motivo.
    fAuthRequire: Boolean;
    fAuthVerifyUrl: string;
    fHTTP: TKMHTTPClient;
    fHttpBusyKind: TKMHttpReqKind;      // hrkNone = ocioso
    fHttpBusyHandle: TKMNetHandleIndex; // so vale para hrkAuth
    fHttpBusyUrl: string;               // guardada so para aparecer no log de erro
    fHttpQueue: array of record
                          Kind: TKMHttpReqKind;
                          Handle: TKMNetHandleIndex;
                          URL: string;
                        end;
    fHttpQueueCount: Integer;

    // kam_brasil: salas ranqueadas. URL vazia = servidor comum, nada disto roda.
    fRankedUrl: string;
    fRankedSecret: string;
    fRankedRooms: TKMRankedRooms;
    fRankedLastPoll: Cardinal;

    fOnStatusMessage: TGetStrProc;

    // kam_brasil
    procedure HttpEnqueue(aKind: TKMHttpReqKind; aHandle: TKMNetHandleIndex; const aURL: string);
    procedure HttpProcessQueue;
    procedure HttpReceived(const aText: string);
    procedure HttpError(const aText: string);
    procedure AuthCompleted(aHandle: TKMNetHandleIndex; const aResponse: string);
    function AuthNicknameAllowed(aHandle: TKMNetHandleIndex; aPacket: PByte; aLength: Word): Boolean;

    // kam_brasil: ranqueada
    function RankedEnabled: Boolean;
    procedure RankedUpdate;
    procedure RankedRoomsReceived(const aText: string);
    procedure RankedImpose(aRoom: Integer);
    procedure RankedSendList(aRanked: TKMRankedRoom; aKind: TKMNetMessageKind);
    procedure RankedStart(aRanked: TKMRankedRoom);
    function RankedHostPacketTaken(aHandle: TKMNetHandleIndex; aRoom: Integer; aPacket: PByte; aLength: Word): Boolean;
    procedure RankedBindRoom(aRanked: TKMRankedRoom);
    procedure RankedObserveGameInfo(aRoom: Integer);
    procedure RankedClientGone(aHandle: TKMNetHandleIndex; aRoom: Integer);
    procedure RankedReport(aRanked: TKMRankedRoom; const aReason: string);
    function RankedBlocked(aRoom: Integer; const aWhat: string): Boolean;
    function RankedListMatches(aRanked: TKMRankedRoom; aNetRoom: TKMNetRoom): Boolean;
    function RankedRelayAllowed(aHandle: TKMNetHandleIndex; aRoom: Integer; aPacket: PByte; aLength: Word): Boolean;

    procedure Error(const aText: string);
    procedure Status(const aText: string);
    procedure ClientConnect(aHandle: TKMNetHandleIndex);
    procedure ClientDisconnect(aHandle: TKMNetHandleIndex);
    procedure PacketSend(aRecipient: TKMNetHandleIndex; aKind: TKMNetMessageKind); overload;
    procedure PacketSend(aRecipient: TKMNetHandleIndex; aKind: TKMNetMessageKind; aParam: Integer; aImmediate: Boolean = False); overload;
    procedure PacketSendInd(aRecipient: TKMNetHandleIndex; aKind: TKMNetMessageKind; aIndexOnServer: TKMNetHandleIndex; aImmediate: Boolean = False);
    procedure PacketSendA(aRecipient: TKMNetHandleIndex; aKind: TKMNetMessageKind; const aText: AnsiString);
    procedure PacketSendW(aRecipient: TKMNetHandleIndex; aKind: TKMNetMessageKind; const aText: UnicodeString);
    procedure PacketSend(aRecipient: TKMNetHandleIndex; aKind: TKMNetMessageKind; aStream: TKMemoryStream); overload;
    procedure PacketSendToRoom(aKind: TKMNetMessageKind; aRoom: Integer; aStream: TKMemoryStream); overload;
    procedure SendDataPrepare(aRecipient: TKMNetHandleIndex; aKind: TKMNetMessageKind; aStream: TKMemoryStream; aImmediate: Boolean = False);
    procedure SendDataQueue(aRecipient: TKMNetHandleIndex; aData: Pointer; aLength: Cardinal; aFlushQueue: Boolean = False);
    procedure SendDataPerform(aServerClient: TKMServerClient);
    procedure RecieveMessage(aSenderHandle: TKMNetHandleIndex; aData: Pointer; aLength: Cardinal);
    procedure DataAvailable(aHandle: TKMNetHandleIndex; aData: Pointer; aLength: Cardinal);
    procedure SaveToStream(aStream: TKMemoryStream);
    function IsValidHandle(aHandle: TKMNetHandleIndex): Boolean;
    function AddNewRoom: Boolean;
    function GetFirstAvailableRoom: Integer;
    function GetRoomClientsCount(aRoom: Integer): Integer;
    function GetFirstRoomClient(aRoom: Integer): Integer;
    procedure AddClientToRoom(aHandle: TKMNetHandleIndex; aRoom: Integer; aGameRevision: TKMGameRevision);
    procedure BanPlayerFromRoom(aHandle: TKMNetHandleIndex; aRoom: Integer);
    procedure SaveHTMLStatus;
    procedure SetPacketsAccumulatingDelay(aValue: Integer);
    procedure SetGameFilter(aGameFilter: TKMPGameFilter);
    procedure HandleMessage(aMessageKind: TKMNetMessageKind; aData: TKMemoryStream; aSenderHandle: TKMNetHandleIndex);
  public
    constructor Create(aMaxRooms, aKickTimeout: Word; const aHTMLStatusFile, aWelcomeMessage: UnicodeString;
                       aPacketsAccDelay: Integer);
    destructor Destroy; override;
    procedure StartListening(aPort: Word; const aServerName: AnsiString);
    procedure StopListening;
    procedure ClearClients;
    // kam_brasil: configurado depois do Create, como o GameFilter ja e.
    procedure SetAuth(aRequire: Boolean; const aVerifyUrl: string);
    procedure SetRanked(const aBaseUrl, aSecret: string);
    procedure MeasurePings;
    procedure UpdateStateIdle;
    procedure UpdateState(Sender: TObject);
    property OnStatusMessage: TGetStrProc write fOnStatusMessage;
    property Listening: boolean read fListening;
    function GetPlayerCount:integer;
    procedure UpdateSettings(aKickTimeout: Word; const aHTMLStatusFile: UnicodeString; const aWelcomeMessage: UnicodeString; const aServerName: AnsiString; const aPacketsAccDelay: Integer);
    procedure GetServerInfo(aList: TList);
    property PacketsAccumulatingDelay: Integer read fPacketsAccumulatingDelay write SetPacketsAccumulatingDelay;
    property GameFilter: TKMPGameFilter read fGameFilter write SetGameFilter;
  end;


implementation
uses
  //KM_Log,
  TypInfo;  // kam_brasil: nome do pacote no log de sala ranqueada

const
  //Server needs to use some text constants locally but can't know about gResTexts
  {$I KM_TextIDs.inc}
  PACKET_ACC_DELAY_MIN = 5;
  PACKET_ACC_DELAY_MAX = 200;


{ TKMServerClient }
constructor TKMServerClient.Create(aHandle: TKMNetHandleIndex; aRoom: Integer);
begin
  inherited Create;

  fHandle := aHandle;
  fRoom := aRoom;
  SetLength(fBuffer, 0);
  SetLength(fQueuedPackets, 0);
  fBufferSize := 0;
end;


procedure TKMServerClient.ClearQueuedPackets;
begin
  fQueuedPacketsCnt := 0;
  fQueuedPacketsSize := 0;
  SetLength(fQueuedPackets, 0);
end;


procedure TKMServerClient.AddQueuedPacket(aData: Pointer; aLength: Cardinal);
begin
  Inc(fQueuedPacketsCnt);
  SetLength(fQueuedPackets, fQueuedPacketsSize + aLength);

  // Append data packet to the end of cumulative packet
  Move(aData^, fQueuedPackets[fQueuedPacketsSize], aLength);
  Inc(fQueuedPacketsSize, aLength);
  //gLog.AddTime('*** add queued packet: length = %d Cnt = %d totalSize = %d', [aLength, fQueuedPacketsCnt, fQueuedPacketsSize]);
end;


{ TKMClientsList }
destructor TKMClientsList.Destroy;
begin
  Clear; //Free all clients

  inherited;
end;


function TKMClientsList.GetItem(aIndex: Integer): TKMServerClient;
begin
  Assert(InRange(aIndex, 0, fCount - 1), 'Tried to access invalid client index');
  Result := fItems[aIndex];
end;


procedure TKMClientsList.AddPlayer(aHandle: TKMNetHandleIndex; aRoom: Integer);
begin
  Inc(fCount);
  SetLength(fItems, fCount);
  fItems[fCount - 1] := TKMServerClient.Create(aHandle, aRoom);
end;


procedure TKMClientsList.RemPlayer(aHandle: TKMNetHandleIndex);
var
  I, ID: Integer;
begin
  ID := -1; //Convert Handle to Index
  for I := 0 to fCount - 1 do
    if fItems[I].Handle = aHandle then
      ID := I;

  Assert(ID <> -1, 'TKMClientsList. Can not remove player');

  fItems[ID].Free;
  for I := ID to fCount - 2 do
    fItems[I] := fItems[I+1]; //Shift only pointers

  dec(fCount);
  SetLength(fItems, fCount);
end;


procedure TKMClientsList.Clear;
var
  I: Integer;
begin
  for I := 0 to fCount - 1 do
    FreeAndNil(fItems[I]);
  fCount := 0;
end;


function TKMClientsList.GetByHandle(aHandle: TKMNetHandleIndex): TKMServerClient;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to fCount-1 do
    if fItems[I].Handle = aHandle then
      Exit(fItems[I]);
end;


{ TKMNetServer }
constructor TKMNetServer.Create(aMaxRooms, aKickTimeout: Word; const aHTMLStatusFile, aWelcomeMessage: UnicodeString;
                                aPacketsAccDelay: Integer);
begin
  inherited Create;

  fEmptyGameInfo := TKMNetGameInfo.Create;
  fEmptyGameInfo.GameTime := -1;

  fGameFilter := TKMPGameFilter.Create;

  fMaxRooms := aMaxRooms;

  if aPacketsAccDelay = -1 then
    fPacketsAccumulatingDelay := DEFAULT_PACKET_ACC_DELAY
  else
    fPacketsAccumulatingDelay := aPacketsAccDelay;

  fKickTimeout := aKickTimeout;
  fHTMLStatusFile := aHTMLStatusFile;
  fWelcomeMessage := aWelcomeMessage;
  fClientList := TKMClientsList.Create;
  {$IFDEF WDC} fServer := TKMNetServerOverbyte.Create; {$ENDIF}
  {$IFDEF FPC} fServer := TKMNetServerLNet.Create;     {$ENDIF}
  fListening := False;
  fRoomCount := 0;

  // kam_brasil
  fAuthRequire := False;
  fHttpQueueCount := 0;
  fHttpBusyKind := hrkNone;
  fHttpBusyHandle := NET_ADDRESS_EMPTY;
  fHTTP := TKMHTTPClient.Create;
  fHTTP.OnReceive := HttpReceived;
  fHTTP.OnError := HttpError;
  fRankedRooms := TKMRankedRooms.Create;
  fRankedLastPoll := 0;

  {$IFDEF WDC}
    {$IFDEF CONSOLE}
      fTimer := TKMConsoleTimer.Create;
      fTimer.OnTimerEvent := UpdateState;
    {$ELSE}
      fTimer := TTimer.Create(nil);
      fTimer.OnTimer := UpdateState;
    {$ENDIF}
    fTimer.Interval := fPacketsAccumulatingDelay;
    fTimer.Enabled  := True;
  {$ELSE}
    fTimer := TFPTimer.Create(nil);
    fTimer.OnTimer  := UpdateState;
    fTimer.Interval := fPacketsAccumulatingDelay;
    fTimer.Enabled  := True;
    fTimer.StartTimer;
  {$ENDIF}
end;


destructor TKMNetServer.Destroy;
begin
  StopListening; //Frees room info
  fServer.Free;
  fClientList.Free;
  fEmptyGameInfo.Free;
  FreeAndNil(fTimer);
  FreeAndNil(fGameFilter);
  FreeAndNil(fHTTP);        // kam_brasil
  FreeAndNil(fRankedRooms); // kam_brasil

  inherited;
end;


{ kam_brasil: autenticacao }
procedure TKMNetServer.SetAuth(aRequire: Boolean; const aVerifyUrl: string);
begin
  // Sem Status() aqui: o handler de log so e ligado em StartListening, e a
  // configuracao precisa acontecer ANTES do socket abrir. O estado e logado la.
  fAuthRequire := aRequire;
  fAuthVerifyUrl := aVerifyUrl;
end;


procedure TKMNetServer.SetRanked(const aBaseUrl, aSecret: string);
begin
  // Mesma razao do SetAuth: configurado antes de o socket abrir, quando o
  // handler de log ainda nao existe. O estado e logado no StartListening.
  fRankedUrl := aBaseUrl;
  fRankedSecret := aSecret;
end;


function TKMNetServer.RankedEnabled: Boolean;
begin
  Result := fRankedUrl <> '';
end;


procedure TKMNetServer.HttpEnqueue(aKind: TKMHttpReqKind; aHandle: TKMNetHandleIndex; const aURL: string);
var
  I: Integer;
begin
  // Um pedido por cliente (auth) e um polling de reservas por vez: reenviar
  // substitui o pendente em vez de acumular, senao um cliente malicioso -- ou
  // uma API lenta -- encheria a fila sozinho.
  if aKind in [hrkAuth, hrkRankedRooms] then
    for I := 0 to fHttpQueueCount - 1 do
      if (fHttpQueue[I].Kind = aKind) and (fHttpQueue[I].Handle = aHandle) then
      begin
        fHttpQueue[I].URL := aURL;
        Exit;
      end;

  if fHttpQueueCount >= Length(fHttpQueue) then
    SetLength(fHttpQueue, fHttpQueueCount + 8);

  fHttpQueue[fHttpQueueCount].Kind := aKind;
  fHttpQueue[fHttpQueueCount].Handle := aHandle;
  fHttpQueue[fHttpQueueCount].URL := aURL;
  Inc(fHttpQueueCount);
end;


procedure TKMNetServer.HttpProcessQueue;
var
  I: Integer;
  kind: TKMHttpReqKind;
  handle: TKMNetHandleIndex;
  url: string;
begin
  if fHttpBusyKind <> hrkNone then Exit; // ja tem uma requisicao em curso
  if fHttpQueueCount = 0 then Exit;

  kind := fHttpQueue[0].Kind;
  handle := fHttpQueue[0].Handle;
  url := fHttpQueue[0].URL;

  for I := 0 to fHttpQueueCount - 2 do
    fHttpQueue[I] := fHttpQueue[I + 1];
  Dec(fHttpQueueCount);

  // O cliente pode ter caido enquanto esperava na fila.
  if (kind = hrkAuth) and not IsValidHandle(handle) then
  begin
    HttpProcessQueue; // segue para o proximo
    Exit;
  end;

  fHttpBusyKind := kind;
  fHttpBusyHandle := handle;
  fHttpBusyUrl := url;
  fHTTP.GetURL(url, False);
end;


// Confere se o nickname anunciado ao host bate com o da conta autenticada.
//
// O mkAskToJoin nao e endereçado ao servidor -- vai para o HOST, que e um
// jogador comum e portanto nao pode julgar identidade. Como o servidor repassa
// o pacote, ele e o unico ponto onde da para verificar.
//
// Sem isto, o jogador entra com token valido e depois se apresenta no lobby com
// o nome que quiser. O portao estaria certo e a identidade errada.
//
// LIMITACAO CONHECIDA: cobre quem ENTRA numa sala, nao quem a CRIA. O primeiro
// cliente de uma sala recebe direitos de host, e nesse caso o cliente se
// adiciona localmente sem enviar mkAskToJoin (ver mkConnectedToRoom em
// KM_Networking) -- o pacote nunca passa por aqui. Fechar isso exige validar o
// mkPlayersList que o host difunde, cujo parsing e bem mais complexo.
//
// FORMATO: aPacket[0] = kind, e o payload de mkAskToJoin e
//   [solucao do challenge][Word tamanho][bytes do nickname]
// A solucao do challenge e VAZIA porque compilamos com DBG_SKIP_SECURE_AUTH
// (ver KaM_Remake.inc). Se algum dia usarmos KM_NetAuthSecure, este parsing
// precisa ser revisto -- a solucao passaria a ocupar bytes aqui.
function TKMNetServer.AuthNicknameAllowed(aHandle: TKMNetHandleIndex; aPacket: PByte; aLength: Word): Boolean;
var
  client: TKMServerClient;
  nickLen: Word;
  claimed: AnsiString;
begin
  Result := True;
  if not fAuthRequire then Exit;

  client := fClientList.GetByHandle(aHandle);
  if (client = nil) or (client.AuthNickname = '') then Exit; // o portao ja cuidou disso

  // Falha ao interpretar recusa em vez de liberar: numa verificacao de
  // identidade, o caso duvidoso tem que ser tratado como negativo.
  if aLength < 3 then
  begin
    Result := False;
    Exit;
  end;

  nickLen := PWord(aPacket + 1)^;
  if aLength < 3 + nickLen then
  begin
    Result := False;
    Exit;
  end;

  SetLength(claimed, nickLen);
  if nickLen > 0 then
    Move((aPacket + 3)^, claimed[1], nickLen);

  Result := (claimed = client.AuthNickname);

  if not Result then
    Status('Client ' + IntToStr(aHandle) + ' claimed nickname "' + string(claimed)
           + '" but is authenticated as "' + string(client.AuthNickname) + '"');
end;


procedure TKMNetServer.HttpReceived(const aText: string);
var
  kind: TKMHttpReqKind;
  handle: TKMNetHandleIndex;
begin
  kind := fHttpBusyKind;
  handle := fHttpBusyHandle;
  fHttpBusyKind := hrkNone;
  fHttpBusyHandle := NET_ADDRESS_EMPTY;

  case kind of
    hrkAuth:        AuthCompleted(handle, aText);
    hrkRankedRooms: RankedRoomsReceived(aText);
    // hrkRankedNotify: a API responde 'ok'. Nao ha decisao a tomar com isso --
    // o reporte e idempotente por match, entao nem repeticao seria problema.
  end;

  HttpProcessQueue;
end;


procedure TKMNetServer.HttpError(const aText: string);
var
  kind: TKMHttpReqKind;
  handle: TKMNetHandleIndex;
  url: string;
begin
  kind := fHttpBusyKind;
  handle := fHttpBusyHandle;

  // StringReplace com padrao vazio e comportamento que muda entre compiladores.
  url := fHttpBusyUrl;
  if fRankedSecret <> '' then
    url := StringReplace(url, fRankedSecret, '<secret>', [rfReplaceAll]);

  fHttpBusyKind := hrkNone;
  fHttpBusyHandle := NET_ADDRESS_EMPTY;

  case kind of
    hrkAuth:
      begin
        // API fora do ar derruba quem esta entrando. Preferimos isso a deixar
        // entrar sem verificar: um servidor que ignora falha de autenticacao
        // nao autentica.
        Status('Auth request failed for client ' + IntToStr(handle) + ': ' + aText);
        if IsValidHandle(handle) then
        begin
          PacketSend(handle, mkRefuseToJoin, TX_KB_NOT_AUTHENTICATED, True);
          fServer.Kick(handle);
        end;
      end;
  else
    // Reservas: a proxima tentativa vem no polling seguinte, nao ha o que fazer.
    //
    // Reportes: a URL vai junto (sem o segredo) porque este e o unico momento em
    // que um resultado pode se perder -- API reiniciando bem na hora em que a
    // partida acabou. Com a linha no log, o dono refaz a chamada na mao.
    //
    // ponytail: sem retentativa automatica. Vale a pena quando aparecer o
    // primeiro caso real -- a rota ja e idempotente por match, entao reenviar
    // e seguro; o que falta e onde guardar a fila entre reinicios do servidor.
    Status('Ranked request failed: ' + aText + ' -- ' + url);
  end;

  HttpProcessQueue;
end;


procedure TKMNetServer.AuthCompleted(aHandle: TKMNetHandleIndex; const aResponse: string);
var
  client: TKMServerClient;
  response: string;
begin
  response := Trim(aResponse);
  client := fClientList.GetByHandle(aHandle);

  if client <> nil then
  begin
    client.AuthPending := False;

    // A API responde "ok <nickname>" em texto puro.
    if Copy(response, 1, 3) = 'ok ' then
    begin
      client.AuthNickname := AnsiString(Trim(Copy(response, 4, Length(response))));
      Status('Client ' + IntToStr(aHandle) + ' authenticated as ' + string(client.AuthNickname));

      // Informa ao cliente qual nome a conta dele possui. Vai ANTES da resposta
      // do join: assim, quando ele entrar na sala -- inclusive recebendo
      // direitos de host, caso em que se adiciona sozinho -- ja esta com o nome
      // certo. A ordem do TCP garante que chega primeiro.
      PacketSendA(aHandle, mkAuthNickname, client.AuthNickname);

      // Havia um mkJoinRoom esperando a validacao: atende agora.
      if client.JoinDeferred then
      begin
        client.JoinDeferred := False;
        AddClientToRoom(aHandle, client.JoinRoom, client.JoinGameRev);
      end;
    end
    else
    begin
      Status('Client ' + IntToStr(aHandle) + ' failed authentication');
      PacketSend(aHandle, mkRefuseToJoin, TX_KB_NOT_AUTHENTICATED, True);
      fServer.Kick(aHandle);
    end;
  end;
end;


{ kam_brasil: salas ranqueadas }

// Nada disto e chamado num servidor comum -- RankedEnabled e False e a lista de
// reservas fica vazia, entao os testes de sala reservada saem no primeiro if.
procedure TKMNetServer.RankedUpdate;
var
  I, slot: Integer;
  ranked: TKMRankedRoom;
begin
  // fListening carrega o fRoomInfo: sem ele, criar sala para uma reserva
  // escreveria num array que o StopListening acabou de liberar.
  if not RankedEnabled or not fListening then Exit;

  if TimeSince(fRankedLastPoll) >= RANKED_POLL_INTERVAL then
  begin
    fRankedLastPoll := TimeGet;
    HttpEnqueue(hrkRankedRooms, NET_ADDRESS_EMPTY, fRankedUrl + '/rooms?secret=' + fRankedSecret);
  end;

  for I := fRankedRooms.Count - 1 downto 0 do
  begin
    ranked := fRankedRooms.Item(I);

    // Sem partida em curso nao ha resultado a reportar: uma reserva que nunca
    // virou jogo e cancelada pela API, nao por nos.
    if ranked.Reported or not ranked.Live then Continue;

    if ranked.ResultsComplete then
    begin
      RankedReport(ranked, 'resultado completo');
      Continue;
    end;

    // Desconexao: a janela de 3 minutos e do servidor, nao do host. Quem nao
    // voltou perde, e o time dele perde junto.
    //
    // A sala esvaziar nao e um caso a parte: quando o ultimo sai, os relogios
    // de todos ja estao correndo e o primeiro a estourar reporta a partida.
    // Reportar na hora tiraria a janela de reconexao de quem caiu junto.
    slot := ranked.TimedOutSlot;
    if slot <> -1 then
    begin
      ranked.LoseByAbandon(slot);
      RankedReport(ranked, 'abandono de ' + string(ranked.Slots[slot].Nickname));
    end;
  end;
end;


procedure TKMNetServer.RankedRoomsReceived(const aText: string);
var
  changes: string;
  I: Integer;
  client: TKMServerClient;
begin
  if not fListening then Exit; // a resposta pode chegar depois do StopListening

  changes := fRankedRooms.Merge(aText);
  if changes <> '' then
    Status('Ranked:' + changes);

  // A API reserva a sala 3 mesmo que o servidor so tenha criado a sala 0 ainda:
  // as salas nascem sob demanda. Sem isto, o jogador mandado para a sala 3
  // levaria "sala invalida" e a reserva nunca comecaria.
  for I := 0 to fRankedRooms.Count - 1 do
    while (fRoomCount <= fRankedRooms.Item(I).Room) and AddNewRoom do
      ;

  for I := 0 to fRankedRooms.Count - 1 do
    RankedBindRoom(fRankedRooms.Item(I));

  // Quem bateu na porta antes da reserva chegar ficou segurado na guarda do
  // AddClientToRoom. Agora a lista esta na mao: da para deixar entrar ou
  // recusar de verdade.
  //
  // De tras para frente porque AddClientToRoom pode expulsar, e expulsar mexe
  // na lista. AuthPending de fora: aquele JoinDeferred e do outro dono, quem o
  // atende e o AuthCompleted -- roubar o pedido dele perderia o join.
  for I := fClientList.Count - 1 downto 0 do
  begin
    client := fClientList[I];
    if client.JoinDeferred and not client.AuthPending and (client.Room = -1) then
    begin
      client.JoinDeferred := False;
      AddClientToRoom(client.Handle, client.JoinRoom, client.JoinGameRev);
    end;
  end;
end;


// Amarra aos slots da reserva os clientes que ja estao na sala.
//
// A reserva quase sempre chega antes do jogador, mas nao sempre: o launcher
// manda entrar na sala 3 no mesmo instante em que a API a reserva, e o polling
// pode estar a RANKED_POLL_INTERVAL do proximo. Sem isto, quem chegou primeiro
// ficaria numa sala reservada sem slot nenhum -- e a partida nunca poderia
// comecar, porque EveryoneHere jamais seria verdade.
procedure TKMNetServer.RankedBindRoom(aRanked: TKMRankedRoom);
var
  I, slot: Integer;
  client: TKMServerClient;
begin
  if aRanked.Live then Exit; // partida rodando nao se reconfigura
  if not InRange(aRanked.Room, 0, fRoomCount - 1) then Exit;

  // De tras para frente: expulsar alguem dispara ClientDisconnect, que mexe na
  // lista durante o laco.
  for I := fClientList.Count - 1 downto 0 do
  begin
    client := fClientList[I];
    if client.Room <> aRanked.Room then Continue;

    slot := aRanked.SlotOfNickname(client.AuthNickname);
    if slot <> -1 then
    begin
      // Handle diferente do que o slot guardava: quem reconectou ganhou outro
      // IndexOnServer, e a lista que a sala tem na tela ainda aponta para o
      // socket morto. Reimpor e o unico jeito de todo mundo voltar a apontar
      // para ele -- inclusive o mkStart, que carrega os mesmos handles.
      if aRanked.Slots[slot].Handle <> client.Handle then
        aRanked.Imposed := False;

      aRanked.Slots[slot].Handle := client.Handle;
      aRanked.Slots[slot].AwaySince := 0;
      Continue;
    end;

    // Estranho numa sala que acabou de virar reservada. So tiramos quem esta no
    // lobby: arrancar alguem de uma partida em andamento seria pior que o
    // problema que estamos consertando.
    //
    // mkKicked, e nao mkRefuseToJoin: este ja entrou na sala, entao o
    // OnDisconnect do cliente esta atribuido e o pacote tem quem o atenda.
    if fRoomInfo[aRanked.Room].GameInfo.GameState = mgsLobby then
    begin
      Status(Format('Ranked: sala %d ficou reservada, tirando %d que nao esta na reserva',
                    [aRanked.Room, client.Handle]));
      PacketSend(client.Handle, mkKicked, TX_KB_NOT_IN_MATCH, True);
      fServer.Kick(client.Handle);
    end;
  end;

  // So a primeira vez: reenviar a configuracao a cada polling seria tres
  // pacotes por sala a cada 5 segundos para nao mudar nada.
  if not aRanked.Imposed then
    RankedImpose(aRanked.Room);
end;


// Monta a lista canonica da reserva e manda para a sala.
//
// Serve para mkPlayersList e para mkStart porque os dois carregam exatamente o
// mesmo payload -- indice do host seguido do TKMNetRoom. E por isso que o
// servidor consegue originar o inicio sem inventar formato nenhum: o pacote que
// comeca a partida e a mesma lista que o lobby ja estava vendo.
procedure TKMNetServer.RankedSendList(aRanked: TKMRankedRoom; aKind: TKMNetMessageKind);
var
  netRoom: TKMNetRoom;
  M: TKMemoryStream;
  I, hostSlot: Integer;
begin
  // Unico ponto que indexa fRoomInfo pelo numero que veio da API: uma reserva
  // para uma sala que nao coube (fMaxRooms) escreveria fora do array.
  if not InRange(aRanked.Room, 0, fRoomCount - 1) then Exit;

  // kam_brasil: mesma regra do RankedImpose. Com alguem faltando, o slot dele
  // sai com handle vazio, e dois slots vazios sao indistinguiveis para o
  // cliente. Alcancavel: A e B no lobby, B cai, A clica pronto.
  if not aRanked.EveryoneHere then Exit;

  netRoom := TKMNetRoom.Create;
  try
    netRoom.HostDoesSetup := True; // ninguem escolhe local nem time: a reserva escolheu
    netRoom.RandomizeTeamLocations := False;
    netRoom.SpectatorsAllowed := False;

    hostSlot := 1;
    for I := 1 to aRanked.Count do
    begin
      netRoom.AddPlayer(aRanked.Slots[I].Nickname, aRanked.Slots[I].Handle, '');
      netRoom[netRoom.Count].Team := aRanked.Slots[I].Team;
      netRoom[netRoom.Count].StartLocation := aRanked.Slots[I].Loc;
      // Cor de bandeira: ninguem roda ValidateColors numa sala ranqueada. Era o
      // host quem rodava, dentro do StartClick, e ele nao inicia mais nada.
      // Sem isto AddPlayer deixa FlagColor em 0 e os dois times entram da mesma
      // cor invalida -- nao da desync, mas voce nao distingue suas unidades das
      // do adversario.
      netRoom[netRoom.Count].FlagColor := MP_PLAYER_COLORS[I];
      // O pronto e do jogador: aqui so espelhamos o que ele clicou.
      netRoom[netRoom.Count].ReadyToStart := aRanked.Slots[I].Ready;
      // Ter o arquivo do mapa nao e opiniao, e fato: o mapa da temporada vai na
      // release do jogo. Sem isto o jogador ficaria preso num download de um
      // arquivo que ele ja tem.
      netRoom[netRoom.Count].HasMapOrSave := True;
      if aRanked.Slots[I].Handle = fRoomInfo[aRanked.Room].HostHandle then
        hostSlot := netRoom.Count;
    end;

    M := TKMemoryStreamBinary.Create;
    M.Write(hostSlot);
    netRoom.SaveToStream(M);
    PacketSendToRoom(aKind, aRanked.Room, M);
    M.Free;
  finally
    netRoom.Free;
  end;
end;


// Manda para a sala a configuracao da reserva: mapa, opcoes e lista de
// jogadores, montada aqui e nao pelo host.
//
// LIMITE HONESTO: o cliente oficial so aplica mkPlayersList/mkGameOptions/
// mkMapSelect/mkStart quando e joiner (ver TKMNetworking.HandleMessage) -- quem
// entrou primeiro virou host e ignora os quatro. Enquanto o cliente nao tratar
// esses pacotes como palavra do servidor, esta imposicao so chega de fato em
// quem nao e host.
procedure TKMNetServer.RankedImpose(aRoom: Integer);
var
  ranked: TKMRankedRoom;
  options: TKMGameOptions;
  M: TKMemoryStream;
begin
  ranked := fRankedRooms.ByRoom(aRoom);
  if ranked = nil then Exit;

  // Com a partida rodando, mandar mkPlayersList/mkGameOptions e mexer na
  // configuracao debaixo de uma simulacao lockstep: desync na hora. Depois do
  // inicio, quem manda e o determinismo.
  if ranked.Live then Exit;

  // Impor com gente faltando geraria uma lista sem IndexOnServer real para
  // quem nao chegou, e dois slots com handle vazio sao indistinguiveis para o
  // cliente. Esperamos a sala fechar.
  if not ranked.EveryoneHere then Exit;

  // A semente e do servidor porque quem inicia a partida e ele. Sorteada uma
  // vez por reserva e mantida: reimpor com semente nova depois de alguem ja ter
  // recebido a anterior seria dois mundos diferentes na mesma partida.
  //
  // Zero nao serve -- TKMGameOptions.Reset diz que e valor invalido para o
  // KaMSeed. Vem do relogio, e nao de Random, porque o servidor dedicado nunca
  // chama Randomize: a sequencia se repetiria identica a cada restart.
  if ranked.Seed = 0 then
    ranked.Seed := Max(1, Integer(TimeGet and $7FFFFFFF));

  options := TKMGameOptions.Create;
  try
    options.Peacetime := ranked.Peacetime;
    options.SpeedPT := ranked.Speed;
    options.SpeedAfterPT := ranked.SpeedAfterPT;
    options.RandomSeed := ranked.Seed;

    // Ordem igual a do host (mapa, opcoes, lista): o cliente recalcula cores e
    // locais validos quando o mapa muda, entao a lista tem que vir depois dele.
    if ranked.MapName <> '' then
    begin
      M := TKMemoryStreamBinary.Create;
      M.WriteW(ranked.MapName);
      M.Write(ranked.MapCRC);
      PacketSendToRoom(mkMapSelect, aRoom, M);
      M.Free;
    end;

    M := TKMemoryStreamBinary.Create;
    options.Save(M);
    PacketSendToRoom(mkGameOptions, aRoom, M);
    M.Free;
  finally
    options.Free;
  end;

  RankedSendList(ranked, mkPlayersList);

  ranked.Imposed := True;
  Status('Ranked: configuracao imposta na ' + ranked.Describe);
end;


// O servidor inicia a partida.
//
// Numa sala reservada nao existe host de verdade: ninguem tem botao de comecar.
// O gatilho e "todos presentes e todos prontos", e o pacote sai daqui.
procedure TKMNetServer.RankedStart(aRanked: TKMRankedRoom);
begin
  // Marcado antes de enviar: RankedSendList entrega pela fila e um segundo
  // mkReadyToStart no meio do caminho mandaria a sala comecar duas vezes.
  aRanked.StartSent := True;

  Status(Format('Ranked: sala %d, todos prontos -- servidor iniciando match %s',
                [aRanked.Room, string(aRanked.MatchId)]));

  RankedSendList(aRanked, mkStart);
end;


// Pacotes que o cliente endereca ao host mas que, numa sala reservada, quem
// responde e o servidor. True = consumido aqui, nao repassar.
//
// Deixar qualquer um dos dois chegar ao host seria o host mexer na propria
// lista e anuncia-la; esse anuncio e justamente o pacote que RankedRelayAllowed
// recusa, e a recusa reimpoe. Era essa a briga em laco que travava o lobby.
function TKMNetServer.RankedHostPacketTaken(aHandle: TKMNetHandleIndex; aRoom: Integer;
                                            aPacket: PByte; aLength: Word): Boolean;
var
  ranked: TKMRankedRoom;
  kind: TKMNetMessageKind;
  slot: Integer;
begin
  Result := False;

  // Caminho comum de um servidor sem ranqueada: sai antes de tocar em qualquer
  // estrutura.
  if (aLength = 0) or (fRankedRooms.Count = 0) then Exit;

  kind := TKMNetMessageKind(aPacket^);
  if not (kind in [mkReadyToStart, mkHasMapOrSave]) then Exit;

  ranked := fRankedRooms.ByRoom(aRoom);
  if ranked = nil then Exit;

  // Sala reservada: os dois morrem aqui de qualquer jeito, mesmo quando nao ha
  // nada a fazer com eles.
  Result := True;

  // mkHasMapOrSave nao tem o que decidir: o mapa da temporada vai na release e
  // a lista imposta ja diz que todo mundo tem o arquivo.
  if kind = mkHasMapOrSave then Exit;

  // Partida iniciando ou rodando: um pronto atrasado nao pode remontar a lista
  // debaixo de uma simulacao lockstep.
  if ranked.Live or ranked.StartSent then Exit;

  slot := ranked.SlotOfHandle(aHandle);
  if slot = -1 then Exit;

  ranked.Slots[slot].Ready := not ranked.Slots[slot].Ready;
  if ranked.Slots[slot].Ready then
    Status(Format('Ranked: sala %d, %s deu pronto', [aRoom, string(ranked.Slots[slot].Nickname)]))
  else
    Status(Format('Ranked: sala %d, %s tirou o pronto', [aRoom, string(ranked.Slots[slot].Nickname)]));

  // Sem reenviar a lista o clique nao aparece para ninguem -- nem para quem
  // clicou, ja que a tela dele e a lista que o servidor manda. So a lista: o
  // mkMapSelect faria cada cliente recarregar o mapa do disco a cada clique.
  RankedSendList(ranked, mkPlayersList);

  if ranked.EveryoneHere and ranked.AllReady then
    RankedStart(ranked);
end;


// Confere um mkPlayersList contra a reserva.
function TKMNetServer.RankedListMatches(aRanked: TKMRankedRoom; aNetRoom: TKMNetRoom): Boolean;
var
  I, slot: Integer;
begin
  Result := False;
  if aNetRoom.Count <> aRanked.Count then Exit;

  for I := 1 to aNetRoom.Count do
  begin
    // Nada de IA nem espectador em ranqueada: sao vagas que ninguem reservou.
    if aNetRoom[I].PlayerNetType <> nptHuman then Exit;

    slot := aRanked.SlotOfNickname(aNetRoom[I].Nickname);
    if slot = -1 then Exit;
    if aNetRoom[I].Team <> aRanked.Slots[slot].Team then Exit;
    // Loc 0 na reserva significa "a API nao exigiu local".
    if (aRanked.Slots[slot].Loc <> 0) and (aNetRoom[I].StartLocation <> aRanked.Slots[slot].Loc) then Exit;
  end;

  Result := True;
end;


// Portao de tudo que o host difunde numa sala reservada.
//
// mkPlayersList, mkGameOptions, mkMapSelect e mkStart sao os quatro pacotes que
// definem a partida. Numa sala comum eles sao palavra do host; aqui eles so
// passam se disserem exatamente o que a reserva diz. E aqui que o travamento
// deixa de ser cosmetico.
function TKMNetServer.RankedRelayAllowed(aHandle: TKMNetHandleIndex; aRoom: Integer; aPacket: PByte; aLength: Word): Boolean;
const
  GUARDED: set of TKMNetMessageKind = [mkPlayersList, mkGameOptions, mkMapSelect,
                                       mkSaveSelect, mkResetMap, mkStart];
var
  ranked: TKMRankedRoom;
  kind: TKMNetMessageKind;
  netRoom: TKMNetRoom;
  options: TKMGameOptions;
  M: TKMemoryStream;
  tmpInt: Integer;
  tmpCardinal: Cardinal;
  tmpStringW: UnicodeString;
  reason: string;
begin
  Result := True;

  // Caminho comum de um servidor sem ranqueada, e de todo mkCommands durante a
  // partida: sai antes de tocar em qualquer estrutura.
  if fRankedRooms.Count = 0 then Exit;

  kind := TKMNetMessageKind(aPacket^);
  if not (kind in GUARDED) then Exit;

  ranked := fRankedRooms.ByRoom(aRoom);
  if ranked = nil then Exit;

  // Estes quatro sao pacotes de host. Vindo de outro cliente, e cliente
  // adulterado tentando reconfigurar a sala dos outros.
  if fRoomInfo[aRoom].HostHandle <> aHandle then
  begin
    Status(Format('Ranked: sala %d, pacote de configuracao veio de %d, que nao e o host', [aRoom, aHandle]));
    Exit(False);
  end;

  reason := '';
  M := TKMemoryStreamBinary.Create;
  try
    if aLength > 1 then
      M.WriteBuffer((PByte(aPacket) + 1)^, aLength - 1);
    M.Position := 0;

    // Pacote curto ou truncado nao pode derrubar o servidor: qualquer excecao
    // de leitura vira "divergente" e o pacote morre aqui.
    try
      case kind of
        mkSaveSelect:
          reason := 'ranqueada nao joga save';

        mkResetMap:
          reason := 'mapa da reserva nao pode ser limpo';

        mkMapSelect:
          begin
            M.ReadW(tmpStringW);
            M.Read(tmpCardinal);
            // MapCRC 0 = a reserva nao trouxe CRC legivel. Recusar todo mapa
            // nesse caso travaria a sala sem que ninguem pudesse consertar.
            if (ranked.MapCRC <> 0) and (tmpCardinal <> ranked.MapCRC) then
              reason := Format('mapa %s (CRC %s) nao e o da reserva (CRC %s)',
                               [tmpStringW, IntToHex(Integer(tmpCardinal), 8), IntToHex(Integer(ranked.MapCRC), 8)]);
          end;

        mkGameOptions:
          begin
            options := TKMGameOptions.Create;
            try
              options.Load(M);
              // A semente e sorteada pelo servidor (ver RankedImpose). Cliente
              // que anuncia outra esta escolhendo o mundo em que se joga --
              // e, pior, deixaria metade da sala com um sorteio e metade com o
              // outro.
              if options.RandomSeed <> ranked.Seed then
                reason := 'semente divergente da reserva'
              else
              if options.Peacetime <> ranked.Peacetime then
                reason := Format('peacetime %d, reserva pede %d', [options.Peacetime, ranked.Peacetime])
              else
              // Comparacao com folga, nao igualdade: a reserva chega como texto
              // ("spd=1.2") e o cliente manda um literal Single. Exigir os bits
              // iguais travaria a sala para sempre por causa de um ULP.
              if (Abs(options.SpeedPT - ranked.Speed) > 0.01)
              or (Abs(options.SpeedAfterPT - ranked.SpeedAfterPT) > 0.01) then
                reason := 'velocidade divergente da reserva';
            finally
              options.Free;
            end;
          end;

        // Quem inicia partida ranqueada e o servidor, quando todos deram pronto
        // (ver RankedStart). Nao ha caso legitimo de mkStart vindo de cliente:
        // ou e cliente velho, que ainda acha que e host, ou e adulterado
        // tentando comecar com gente faltando.
        mkStart:
          reason := 'so o servidor inicia partida ranqueada';

        mkPlayersList:
          begin
            netRoom := TKMNetRoom.Create;
            try
              M.Read(tmpInt); // indice do host na lista
              netRoom.LoadFromStream(M);
              if not RankedListMatches(ranked, netRoom) then
                reason := 'lista de jogadores divergente da reserva';
            finally
              netRoom.Free;
            end;
          end;
      end;
    except
      on E: Exception do
        reason := 'pacote ilegivel: ' + E.Message;
    end;
  finally
    M.Free;
  end;

  if reason = '' then Exit;

  Status(Format('Ranked: sala %d, %s descartado -- %s',
                [aRoom, GetEnumName(TypeInfo(TKMNetMessageKind), Integer(kind)), reason]));
  Result := False;

  // Reafirma a configuracao para todo mundo. Sem isto, um host divergente
  // deixaria os joiners parados com o que sobrou da ultima lista valida.
  RankedImpose(aRoom);
end;


// Le o mkSetGameInfo do host: e por ele que o resultado de cada jogador chega
// ao servidor (TKMNetGameInfo ja carrega WonOrLost por jogador).
procedure TKMNetServer.RankedObserveGameInfo(aRoom: Integer);
var
  ranked: TKMRankedRoom;
  gameInfo: TKMNetGameInfo;
  I, slot: Integer;
begin
  ranked := fRankedRooms.ByRoom(aRoom);
  if ranked = nil then Exit;

  gameInfo := fRoomInfo[aRoom].GameInfo;

  if gameInfo.GameState = mgsLobby then
  begin
    // No lobby o mkSetGameInfo e so espelho do que o host montou. Divergiu,
    // reimpomos -- o pacote em si nao decide nada, mas denuncia que a tela do
    // host saiu do lugar.
    if ranked.Imposed then
      for I := 1 to gameInfo.PlayerCount do
      begin
        slot := ranked.SlotOfNickname(gameInfo.Players[I].Name);
        if (slot = -1) or (gameInfo.Players[I].Team <> ranked.Slots[slot].Team) then
        begin
          Status(Format('Ranked: sala %d anunciou setup divergente, reimpondo', [aRoom]));
          RankedImpose(aRoom);
          Break;
        end;
      end;
    Exit;
  end;

  // Saiu do lobby: a partida existe.
  ranked.Live := True;
  // MissionTime = Tick / 24 / 60 / 60 / 10 (ver TKMGame.MissionTime), entao o
  // caminho de volta e multiplicar pelos mesmos fatores.
  if gameInfo.GameTime > 0 then
    ranked.Ticks := Round(gameInfo.GameTime * 24 * 60 * 60 * 10);

  if not ranked.Started then
  begin
    ranked.Started := True;
    Status('Ranked: match ' + string(ranked.MatchId) + ' comecou');
    HttpEnqueue(hrkRankedNotify, NET_ADDRESS_EMPTY,
                fRankedUrl + '/started?secret=' + fRankedSecret
                + '&match=' + RankedUrlEncode(ranked.MatchId)
                + '&seed=' + IntToStr(gameInfo.GameOptions.RandomSeed)
                + '&tick=' + IntToStr(ranked.Ticks));
  end;

  // O resultado so anda para frente: uma vitoria vista uma vez nao volta a
  // wolNone porque um anuncio posterior chegou sem ela.
  for I := 1 to gameInfo.PlayerCount do
    if gameInfo.Players[I].WonOrLost <> wolNone then
    begin
      slot := ranked.SlotOfNickname(gameInfo.Players[I].Name);
      if (slot <> -1) and (ranked.Slots[slot].Outcome = wolNone) then
      begin
        ranked.Slots[slot].Outcome := gameInfo.Players[I].WonOrLost;
        Status(Format('Ranked: %s %s', [string(ranked.Slots[slot].Nickname),
                                        WonOrLostText[ranked.Slots[slot].Outcome]]));
      end;
    end;
end;


procedure TKMNetServer.RankedClientGone(aHandle: TKMNetHandleIndex; aRoom: Integer);
var
  ranked: TKMRankedRoom;
  slot: Integer;
begin
  if aRoom = -1 then Exit;

  ranked := fRankedRooms.ByRoom(aRoom);
  if ranked = nil then Exit;

  slot := ranked.SlotOfHandle(aHandle);
  if slot = -1 then Exit;

  ranked.Slots[slot].Handle := NET_ADDRESS_EMPTY;
  // Max(1, ...) porque AwaySince = 0 e o nosso "esta presente". TimeGet pode
  // valer 0 no primeiro milissegundo de uptime da maquina.
  ranked.Slots[slot].AwaySince := Max(1, TimeGet);
  // Quem caiu perde o pronto e precisa confirmar de novo ao voltar. Preservar
  // seria a partida comecar no milissegundo em que o socket dele reconecta --
  // com ele ainda carregando o jogo, ou nem na frente do computador. O pronto
  // e uma declaracao de "estou aqui agora", e ele acabou de deixar de estar.
  ranked.Slots[slot].Ready := False;
  Status(Format('Ranked: %s caiu da sala %d, %d segundos para voltar',
                [string(ranked.Slots[slot].Nickname), aRoom, RANKED_ABANDON_TIMEOUT div 1000]));
end;


procedure TKMNetServer.RankedReport(aRanked: TKMRankedRoom; const aReason: string);
begin
  // Marcado antes de enfileirar: a resposta HTTP demora, e um segundo gatilho
  // no meio do caminho mandaria o mesmo resultado duas vezes.
  aRanked.Reported := True;

  Status(Format('Ranked: reportando match %s (%s), vencedor "%s", %d ticks',
                [string(aRanked.MatchId), aReason, aRanked.WinnerTeam, aRanked.Ticks]));

  HttpEnqueue(hrkRankedNotify, NET_ADDRESS_EMPTY,
              fRankedUrl + '/report?secret=' + fRankedSecret + '&' + aRanked.ReportQuery);
end;


// True quando o pedido do host tem que ser engolido por ser sala ranqueada.
function TKMNetServer.RankedBlocked(aRoom: Integer; const aWhat: string): Boolean;
begin
  Result := fRankedRooms.IsReserved(aRoom);
  if Result then
    Status(Format('Ranked: sala %d, %s do host ignorado', [aRoom, aWhat]));
end;


//There's an error in fServer, perhaps fatal for multiplayer.
procedure TKMNetServer.Error(const aText: string);
begin
  Status(aText);
end;


//There's an error in fServer, perhaps fatal for multiplayer.
procedure TKMNetServer.Status(const aText: string);
begin
  if Assigned(fOnStatusMessage) then fOnStatusMessage('Server: ' + aText);
end;


procedure TKMNetServer.StartListening(aPort: Word; const aServerName: AnsiString);
begin
  fRoomCount := 0;
  Assert(AddNewRoom); //Must succeed

  fServerName := aServerName;
  fServer.OnError := Error;
  fServer.OnClientConnect := ClientConnect;
  fServer.OnClientDisconnect := ClientDisconnect;
  fServer.OnDataAvailable := DataAvailable;
  fServer.StartListening(aPort);
  Status('Listening on port ' + IntToStr(aPort));

  // kam_brasil: registra a politica de autenticacao em vigor. Fica aqui porque
  // e o primeiro ponto onde o handler de log ja esta ligado.
  if fAuthRequire then
    Status('Kam Brasil auth ENABLED, verifying against ' + fAuthVerifyUrl)
  else
    Status('Kam Brasil auth disabled (open server)');

  if RankedEnabled then
    Status('Kam Brasil ranked ENABLED, polling ' + fRankedUrl + '/rooms')
  else
    Status('Kam Brasil ranked disabled (no reserved rooms)');

  fListening := True;
  SaveHTMLStatus;
end;


procedure TKMNetServer.StopListening;
var
  I: Integer;
begin
  fOnStatusMessage := nil;
  fServer.StopListening;
  fListening := False;
  for I := 0 to fRoomCount - 1 do
  begin
    FreeAndNil(fRoomInfo[I].GameInfo);
    SetLength(fRoomInfo[I].BannedIPs, 0);
  end;
  SetLength(fRoomInfo,0);
  fRoomCount := 0;
end;


procedure TKMNetServer.ClearClients;
begin
  fClientList.Clear;
end;


procedure TKMNetServer.MeasurePings;
var
  I: Integer;
  M: TKMemoryStream;
  tickCount: DWord;
begin
  tickCount := TimeGet;
  //Sends current ping info to everyone
  M := TKMemoryStreamBinary.Create;
  M.Write(fClientList.Count);
  for I := 0 to fClientList.Count - 1 do
  begin
    M.Write(fClientList[I].Handle);
    M.Write(fClientList[I].Ping);
    M.Write(fClientList[I].FPS);
    //gLog.AddTime('Client %d measured ping = %d FPS = %d', [fClientList[I].Handle, fClientList[I].Ping, fClientList[I].FPS]);
  end;
  PacketSend(NET_ADDRESS_ALL, mkPingFpsInfo, M);
  M.Free;

  //Measure pings. Iterate backwards so the indexes are maintained after kicking clients
  for I:=fClientList.Count-1 downto 0 do
    if fClientList[I].fPingStarted = 0 then //We have recieved mkPong for our previous measurement, so start a new one
    begin
      fClientList[I].fPingStarted := tickCount;
      PacketSend(fClientList[I].fHandle, mkPing);
    end
    else
      //If they don't respond within a reasonable time, kick them
      if TimeSince(fClientList[I].fPingStarted) > fKickTimeout*1000 then
      begin
        Status('Client timed out ' + inttostr(fClientList[I].fHandle));
        PacketSend(fClientList[I].fHandle, mkKicked, TX_NET_KICK_TIMEOUT, True);
        fServer.Kick(fClientList[I].fHandle);
      end;
end;


procedure TKMNetServer.UpdateStateIdle;
begin
  {$IFDEF FPC} fServer.UpdateStateIdle; {$ENDIF}

  // kam_brasil: no FPC o cliente HTTP so avanca quando bombeado daqui.
  if fAuthRequire or RankedEnabled then
  begin
    fHTTP.UpdateStateIdle;
    RankedUpdate;
    HttpProcessQueue;
  end;
end;


function TKMNetServer.GetPlayerCount:integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to fClientList.fCount - 1 do
    if fClientList.Item[I].fRoom <> -1 then
      Inc(Result);
end;


procedure TKMNetServer.UpdateSettings(aKickTimeout: Word; const aHTMLStatusFile: UnicodeString; const aWelcomeMessage: UnicodeString;
                                      const aServerName: AnsiString; const aPacketsAccDelay: Integer);
begin
  fKickTimeout := aKickTimeout;
  fHTMLStatusFile := aHTMLStatusFile;
  fWelcomeMessage := aWelcomeMessage;
  if aPacketsAccDelay = -1 then
    PacketsAccumulatingDelay := DEFAULT_PACKET_ACC_DELAY
  else
    PacketsAccumulatingDelay := aPacketsAccDelay;
  if fServerName <> aServerName then
    PacketSendA(NET_ADDRESS_ALL, mkServerName, aServerName);
  fServerName := aServerName;
end;


procedure TKMNetServer.GetServerInfo(aList: TList);
var
  I: Integer;
begin
  Assert(aList <> nil);
  for I := 0 to fRoomCount - 1 do
    if GetRoomClientsCount(I) > 0 then
      aList.Add(fRoomInfo[I].GameInfo);
end;


//Someone has connected to us. We can use supplied Handle to negotiate
procedure TKMNetServer.ClientConnect(aHandle: TKMNetHandleIndex);
begin
  fClientList.AddPlayer(aHandle, -1); //Clients are not initially put into a room, they choose a room later
  PacketSendA(aHandle, mkNetProtocolVersion, NET_PROTOCOL_REVISON); //First make sure they are using the right version
  if fWelcomeMessage <> '' then PacketSendW(aHandle, mkWelcomeMessage, fWelcomeMessage); //Welcome them to the server
  PacketSendA(aHandle, mkServerName, fServerName);
  PacketSendInd(aHandle, mkIndexOnServer, aHandle); //This is the signal that the client may now start sending
end;


procedure TKMNetServer.AddClientToRoom(aHandle: TKMNetHandleIndex; aRoom: Integer; aGameRevision: TKMGameRevision);
var
  I, rankedSlot: Integer;
  M: TKMemoryStream;
  ranked: TKMRankedRoom;
  client: TKMServerClient;
begin
  // kam_brasil: nil explicito. `ranked` so recebe valor dentro da guarda de
  // ranqueada, e e lido no fim da rotina para decidir o RankedImpose -- num
  // servidor casual aquele ramo nunca roda. O FPC deixa passar; o Delphi
  // recusa com E1036, e esta certo: sem isto o teste final leria lixo de pilha.
  ranked := nil;

  if fClientList.GetByHandle(aHandle).Room <> -1 then exit; //Changing rooms is not allowed yet

  if aRoom = fRoomCount then
  begin
    if not AddNewRoom then //Create a new room for this client
    begin
      PacketSend(aHandle, mkRefuseToJoin, TX_NET_INVALID_ROOM, True);
      fServer.Kick(aHandle);
      Exit;
    end;
  end
  else
    if aRoom = -1 then
    begin
      aRoom := GetFirstAvailableRoom; //Take the first one which has a space (or create a new one if none have spaces)
      if aRoom = -1 then //No rooms available
      begin
        PacketSend(aHandle, mkRefuseToJoin, TX_NET_INVALID_ROOM, True);
        fServer.Kick(aHandle);
        Exit;
      end;
    end
    else
      //If the room is outside the valid range
      if not InRange(aRoom, 0, fRoomCount - 1) then
      begin
        PacketSend(aHandle, mkRefuseToJoin, TX_NET_INVALID_ROOM, True);
        fServer.Kick(aHandle);
        Exit;
      end;

  //Make sure the client is not banned by host from this room
  for I := 0 to Length(fRoomInfo[aRoom].BannedIPs) - 1 do
    if fRoomInfo[aRoom].BannedIPs[I] = fServer.GetIP(aHandle) then
    begin
      PacketSend(aHandle, mkRefuseToJoin, TX_NET_BANNED_BY_HOST, True);
      fServer.Kick(aHandle);
      Exit;
    end;

  // kam_brasil: num servidor de ranqueada, so entra quem a fila pareou -- e so
  // na sala reservada para ele.
  //
  // A guarda e por SERVIDOR, nao por sala. Antes ela testava `ranked <> nil`,
  // ou seja, so protegia sala COM reserva ativa: com a fila vazia nenhuma sala
  // estava reservada e o servidor de ranqueada aceitava qualquer um, como um
  // servidor comum. Sala sem reserva nao e "sala livre" aqui, e sala em que
  // ninguem tem o que fazer.
  //
  // Num servidor CASUAL nada disto roda: RankedEnabled e False (fRankedUrl
  // vazio), o polling nunca acontece e ninguem e barrado.
  //
  // A identidade usada e a do AuthNickname -- o nome que a nossa API confirmou
  // para o token, nao o que o cliente diz chamar-se. Fica antes da atribuicao
  // de host de proposito: um estranho recusado nao pode virar dono da sala no
  // caminho para a porta.
  if RankedEnabled then
  begin
    client := fClientList.GetByHandle(aHandle);
    ranked := fRankedRooms.ByRoom(aRoom);

    rankedSlot := -1;
    if (ranked <> nil) and (client <> nil) then
      rankedSlot := ranked.SlotOfNickname(client.AuthNickname);

    if rankedSlot = -1 then
    begin
      // A reserva pode estar a caminho: o launcher manda entrar na sala no
      // mesmo instante em que a API a reserva, e o nosso polling pode estar a
      // RANKED_POLL_INTERVAL do proximo. Segura o pedido UMA vez, pede a lista
      // agora e decide quando ela chegar -- recusar de cara derrubaria
      // justamente o par legitimo que chegou rapido demais.
      //
      // ponytail: se o GET /rooms falhar, ninguem retoma este join e o cliente
      // cai no JOIN_TIMEOUT dele (8s, "tempo esgotado") em vez de ouvir "voce
      // nao esta nesta partida". E o caso de API fora do ar, em que nao haveria
      // reserva nenhuma para entrar. Se isso incomodar, varra os JoinDeferred
      // vencidos no RankedUpdate.
      if (client <> nil) and (client.RankedWaitSince = 0) then
      begin
        client.RankedWaitSince := TimeGet;
        client.JoinDeferred := True;
        client.JoinRoom := aRoom; // ja resolvido: nao recria sala na segunda volta
        client.JoinGameRev := aGameRevision;
        fRankedLastPoll := 0; // busca as reservas no proximo tick, sem esperar
        Exit;
      end;

      Status('Client ' + IntToStr(aHandle) + ' is not on the reservation for room ' + IntToStr(aRoom));
      PacketSend(aHandle, mkRefuseToJoin, TX_KB_NOT_IN_MATCH, True);
      fServer.Kick(aHandle);
      Exit;
    end;

    ranked.Slots[rankedSlot].Handle := aHandle;
    ranked.Slots[rankedSlot].AwaySince := 0; // voltou dentro da janela
  end;

  //Let the first client be a Host
  if fRoomInfo[aRoom].HostHandle = NET_ADDRESS_EMPTY then
  begin
    fRoomInfo[aRoom].HostHandle := aHandle;
    //Setup revision for room on first host connection
    //other players should not be able to override it due to exe-CRC check
    fRoomInfo[aRoom].GameRevision := aGameRevision;
    Status('Host rights assigned to ' + IntToStr(fRoomInfo[aRoom].HostHandle));
  end
  else
  if fRoomInfo[aRoom].GameRevision <> aGameRevision then //Usually should never happen
  begin
    PacketSend(aHandle, mkRefuseToJoin, TX_NET_HOST_GAME_VERSION_DONT_MATCH, True);
    fServer.Kick(aHandle);
    Exit;
  end;

  Status('Client ' + IntToStr(aHandle) + ' has connected to room ' + IntToStr(aRoom));
  fClientList.GetByHandle(aHandle).Room := aRoom;

  M := TKMemoryStreamBinary.Create;
  M.Write(fRoomInfo[aRoom].HostHandle);
  fGameFilter.Save(M);
  PacketSend(aHandle, mkConnectedToRoom, M);
  M.Free;

  MeasurePings;
  SaveHTMLStatus;

  // kam_brasil: com a sala fechada, a configuracao da reserva vale a partir de
  // agora. Fica depois do mkConnectedToRoom porque quem acabou de chegar
  // precisa estar na sala para receber o mkPlayersList.
  if ranked <> nil then
    RankedImpose(aRoom);
end;


procedure TKMNetServer.BanPlayerFromRoom(aHandle: TKMNetHandleIndex; aRoom:integer);
begin
  SetLength(fRoomInfo[aRoom].BannedIPs, Length(fRoomInfo[aRoom].BannedIPs) + 1);
  fRoomInfo[aRoom].BannedIPs[Length(fRoomInfo[aRoom].BannedIPs) - 1] := fServer.GetIP(aHandle);
end;


//Someone has disconnected from us.
procedure TKMNetServer.ClientDisconnect(aHandle: TKMNetHandleIndex);
var
  room: Integer;
  client: TKMServerClient;
  M: TKMemoryStream;
begin
  client := fClientList.GetByHandle(aHandle);
  if client = nil then
  begin
    Status('Warning: Client ' + inttostr(aHandle) + ' was already disconnected');
    Exit;
  end;
  room := client.Room;
  if room <> -1 then
    Status('Client '+inttostr(aHandle)+' has disconnected'); //Only log messages for clients who entered a room

  // kam_brasil: em sala reservada, a saida liga o relogio dos 3 minutos. Nao e
  // abandono ainda -- queda de rede e reconexao acontecem o tempo todo.
  RankedClientGone(aHandle, room);

  fClientList.RemPlayer(aHandle);

  if room = -1 then Exit; //The client was not assigned a room yet

  //Send message to all remaining clients that client has disconnected
  PacketSendInd(NET_ADDRESS_ALL, mkClientLost, aHandle);

  //Assign a new host
  if fRoomInfo[room].HostHandle = aHandle then
  begin
    if GetRoomClientsCount(room) = 0 then
    begin
      fRoomInfo[room].HostHandle := NET_ADDRESS_EMPTY; //Room is now empty so we don't need a new host
      fRoomInfo[room].Password := '';
      fRoomInfo[room].GameInfo.Free;
      fRoomInfo[room].GameInfo := TKMNetGameInfo.Create;
      SetLength(fRoomInfo[room].BannedIPs, 0);
    end
    else
    begin
      fRoomInfo[room].HostHandle := GetFirstRoomClient(room); //Assign hosting rights to the first client in the room

      //Tell everyone about the new host and password/description (so new host knows it)
      M := TKMemoryStreamBinary.Create;
      M.Write(fRoomInfo[room].HostHandle);
      M.WriteA(fRoomInfo[room].Password);
      M.WriteW(fRoomInfo[room].GameInfo.Description);
      PacketSendToRoom(mkReassignHost, room, M);
      M.Free;

      Status('Reassigned hosting rights for room ' + inttostr(room) + ' to ' + inttostr(fRoomInfo[room].HostHandle));
    end;
  end;
  SaveHTMLStatus;
end;


procedure TKMNetServer.PacketSend(aRecipient: TKMNetHandleIndex; aKind: TKMNetMessageKind);
var
  M: TKMemoryStream;
begin
  M := TKMemoryStreamBinary.Create; //Send empty stream
  SendDataPrepare(aRecipient, aKind, M);
  M.Free;
end;


procedure TKMNetServer.PacketSend(aRecipient: TKMNetHandleIndex; aKind: TKMNetMessageKind; aParam: Integer; aImmediate: Boolean = False);
var
  M: TKMemoryStream;
begin
  M := TKMemoryStreamBinary.Create;
  M.Write(aParam);
  SendDataPrepare(aRecipient, aKind, M, aImmediate);
  M.Free;
end;


procedure TKMNetServer.PacketSendInd(aRecipient: TKMNetHandleIndex; aKind: TKMNetMessageKind; aIndexOnServer: TKMNetHandleIndex; aImmediate: Boolean = False);
var
  M: TKMemoryStream;
begin
  M := TKMemoryStreamBinary.Create;
  M.Write(aIndexOnServer);
  SendDataPrepare(aRecipient, aKind, M, aImmediate);
  M.Free;
end;


procedure TKMNetServer.PacketSendA(aRecipient: TKMNetHandleIndex; aKind: TKMNetMessageKind; const aText: AnsiString);
var
  M: TKMemoryStream;
begin
  Assert(NetPacketType[aKind] = pfStringA);

  M := TKMemoryStreamBinary.Create;
  M.WriteA(aText);
  SendDataPrepare(aRecipient, aKind, M);
  M.Free;
end;


procedure TKMNetServer.PacketSendW(aRecipient: TKMNetHandleIndex; aKind: TKMNetMessageKind; const aText: UnicodeString);
var
  M: TKMemoryStream;
begin
  Assert(NetPacketType[aKind] = pfStringW);

  M := TKMemoryStreamBinary.Create;
  M.WriteW(aText);
  SendDataPrepare(aRecipient, aKind, M);
  M.Free;
end;


procedure TKMNetServer.PacketSend(aRecipient: TKMNetHandleIndex; aKind: TKMNetMessageKind; aStream: TKMemoryStream);
begin
  //Send stream without changes
  SendDataPrepare(aRecipient, aKind, aStream);
end;


procedure TKMNetServer.PacketSendToRoom(aKind: TKMNetMessageKind; aRoom: Integer; aStream: TKMemoryStream);
var
  I: Integer;
begin
  //Iterate backwards because sometimes calling Send results in ClientDisconnect (LNet only?)
  for I := fClientList.Count - 1 downto 0 do
    if fClientList[i].Room = aRoom then
      PacketSend(fClientList[i].Handle, aKind, aStream);
end;


//Assemble the packet as [Sender.Recepient.Length.Data]
procedure TKMNetServer.SendDataPrepare(aRecipient: TKMNetHandleIndex; aKind: TKMNetMessageKind; aStream: TKMemoryStream; aImmediate: Boolean = False);
var
  I: Integer;
  M: TKMemoryStream;
begin
  M := TKMemoryStreamBinary.Create;
  try
    //Header
    M.Write(TKMNetHandleIndex(NET_ADDRESS_SERVER)); //Make sure constant gets treated as 4byte integer
    M.Write(aRecipient);
    M.Write(Word(1 + aStream.Size)); //Message kind + data size

    //Contents
    M.Write(Byte(aKind));
    aStream.Position := 0;
    M.CopyFrom(aStream, aStream.Size);

    if M.Size > MAX_PACKET_SIZE then
    begin
      Status('Error: Packet over size limit');
      Exit;
    end;

    if aRecipient = NET_ADDRESS_ALL then
      //Iterate backwards because sometimes calling Send results in ClientDisconnect (LNet only?)
      for I := fClientList.Count - 1 downto 0 do
        SendDataQueue(fClientList[i].Handle, M.Memory, M.Size, aImmediate)
    else
      SendDataQueue(aRecipient, M.Memory, M.Size, aImmediate);
  finally
    M.Free;
  end;
end;


procedure TKMNetServer.SendDataPerform(aServerClient: TKMServerClient);
var
  P: Pointer;
  totalSize: Cardinal;
begin
  if aServerClient.fQueuedPacketsCnt > 0 then
  begin
    totalSize := aServerClient.fQueuedPacketsSize + 1; //+1 byte for packets count
    GetMem(P, totalSize);
    try
      // Packets Count goes into 1st byte (guaranteed to be <256)
      PByte(P)^ := aServerClient.fQueuedPacketsCnt;
      // Copy collected packets data with 1 byte shift
      Move(aServerClient.fQueuedPackets[0], Pointer(NativeUInt(P) + 1)^, aServerClient.fQueuedPacketsSize);

      Inc(fBytesTX, totalSize);
      //Inc(PacketsSent);
      //gLog.AddTime('++++ send data to ' + GetNetAddressStr(aServerClient.fHandle) + ' length = ' + IntToStr(totalSize));
      fServer.SendData(aServerClient.fHandle, P, totalSize);

      aServerClient.ClearQueuedPackets;
    finally
      FreeMem(P);
    end;
  end;
end;


procedure TKMNetServer.SetPacketsAccumulatingDelay(aValue: Integer);
begin
  fPacketsAccumulatingDelay := EnsureRange(aValue, PACKET_ACC_DELAY_MIN, PACKET_ACC_DELAY_MAX);
  fTimer.Interval := fPacketsAccumulatingDelay;
end;


procedure TKMNetServer.SetGameFilter(aGameFilter: TKMPGameFilter);
begin
  FreeAndNil(fGameFilter);
  fGameFilter := aGameFilter;
end;


procedure TKMNetServer.UpdateState(Sender: TObject);
var
  I: Integer;
begin
  for I := 0 to fClientList.Count - 1 do
  begin
    //if (fGlobalTickCount mod SCHEDULE_PACKET_SEND_SPLIT) = (I mod SCHEDULE_PACKET_SEND_SPLIT) then
    SendDataPerform(fClientList[I]);
  end;
end;


procedure TKMNetServer.SendDataQueue(aRecipient: TKMNetHandleIndex; aData: Pointer; aLength: Cardinal; aFlushQueue: Boolean = False);
var
  senderClient: TKMServerClient;
begin
  senderClient := fClientList.GetByHandle(aRecipient);

  if senderClient = nil then Exit;

  if (senderClient.fQueuedPacketsSize + aLength > MAX_CUMULATIVE_PACKET_SIZE)
    or (senderClient.fQueuedPacketsCnt = 255) then //Max number of packets = 255 (we use 1 byte for that)
  begin
    //gLog.AddTime('@@@ FLUSH fQueuedPacketsSize + aLength = %d > %d', [SenderClient.fQueuedPacketsSize + aLength, MAX_CUMULATIVE_PACKET_SIZE]);
    SendDataPerform(senderClient);
  end;

  senderClient.AddQueuedPacket(aData, aLength);

  if aFlushQueue then
    SendDataPerform(senderClient);
end;


procedure TKMNetServer.RecieveMessage(aSenderHandle: TKMNetHandleIndex; aData: Pointer; aLength: Cardinal);
var
  dataStream: TKMemoryStream;
  messageKind: TKMNetMessageKind;
begin
  Assert(aLength >= SizeOf(messageKind), 'Unexpectedly short message');

  dataStream := TKMemoryStreamBinary.Create;
  try
    dataStream.WriteBuffer(aData^, aLength);
    dataStream.Position := 0;
    dataStream.Read(messageKind, SizeOf(messageKind));

    //Sometimes client disconnects then we recieve a late packet (e.g. mkPong), in which case ignore it
    if fClientList.GetByHandle(aSenderHandle) = nil then
    begin
      Status('Warning: Received data from an unassigned client');
      Exit;
    end;

    HandleMessage(messageKind, dataStream, aSenderHandle);
  finally
    dataStream.Free;
  end;
end;


procedure TKMNetServer.HandleMessage(aMessageKind: TKMNetMessageKind; aData: TKMemoryStream; aSenderHandle: TKMNetHandleIndex);
var
  // We can not use inline vars here. FPC does not support them
  M2: TKMemoryStream;
  tmpInt: Integer;
  gameRev: TKMGameRevision;
  tmpSmallInt: TKMNetHandleIndex;
  tmpStringA: AnsiString;
  client: TKMServerClient;
  senderIsHost: Boolean;
  senderRoom: Integer;
begin
  senderRoom := fClientList.GetByHandle(aSenderHandle).Room;
  senderIsHost := (senderRoom <> -1) and (fRoomInfo[senderRoom].HostHandle = aSenderHandle);

  case aMessageKind of
    // kam_brasil: cliente manda o token da conta logo apos conectar.
    mkAuthToken:
            begin
              aData.ReadA(tmpStringA);
              if fAuthRequire then
              begin
                client := fClientList.GetByHandle(aSenderHandle);
                if client <> nil then
                  client.AuthPending := True;
                HttpEnqueue(hrkAuth, aSenderHandle,
                            fAuthVerifyUrl + '?token=' + UnicodeString(tmpStringA));
              end;
              // Com auth desligada o pacote e simplesmente ignorado, o que
              // mantem clientes novos compativeis com servidores antigos.
            end;

    mkJoinRoom:
            begin
              aData.Read(tmpInt); //Room to join
              aData.Read(gameRev);

              // kam_brasil: sem conta validada nao entra em sala nenhuma.
              // Esta e a fronteira que realmente vale -- o mkAskToJoin (nickname)
              // vai para o host, que e um jogador e nao decide isto.
              if fAuthRequire then
              begin
                client := fClientList.GetByHandle(aSenderHandle);
                if (client <> nil) and (client.AuthNickname = '') then
                begin
                  if client.AuthPending then
                  begin
                    // Validacao em curso: guarda o pedido e responde quando a
                    // API voltar. Recusar aqui seria uma corrida perdida, ja que
                    // o mkJoinRoom vem logo atras do mkAuthToken.
                    client.JoinDeferred := True;
                    client.JoinRoom := tmpInt;
                    client.JoinGameRev := gameRev;
                    Exit;
                  end;

                  // Nenhum token foi enviado: cliente sem launcher.
                  // mkRefuseToJoin, e nao mkKicked: nesta fase o cliente ainda
                  // nao atribuiu OnDisconnect, e chama-lo seria ponteiro nulo.
                  PacketSend(aSenderHandle, mkRefuseToJoin, TX_KB_NOT_AUTHENTICATED, True);
                  fServer.Kick(aSenderHandle);
                  Exit;
                end;
              end;

              if InRange(tmpInt, 0, Length(fRoomInfo)-1)
              and (fRoomInfo[tmpInt].HostHandle <> NET_ADDRESS_EMPTY)
              //Once game has started don't ask for passwords so clients can reconnect
              and (fRoomInfo[tmpInt].GameInfo.GameState = mgsLobby)
              and (fRoomInfo[tmpInt].Password <> '') then
                PacketSend(aSenderHandle, mkReqPassword)
              else
                AddClientToRoom(aSenderHandle, tmpInt, gameRev);
            end;
    mkPassword:
            begin
              aData.Read(tmpInt); //Room to join
              aData.Read(gameRev);
              aData.ReadA(tmpStringA); //Password
              if InRange(tmpInt, 0, Length(fRoomInfo)-1)
              and (fRoomInfo[tmpInt].HostHandle <> NET_ADDRESS_EMPTY)
              and (fRoomInfo[tmpInt].Password = tmpStringA) then
                AddClientToRoom(aSenderHandle, tmpInt, gameRev)
              else
                PacketSend(aSenderHandle, mkReqPassword);
            end;
    mkSetPassword:
            if senderIsHost then
            begin
              // kam_brasil: senha numa sala reservada trancaria fora justamente
              // quem a fila mandou entrar.
              if RankedBlocked(senderRoom, 'mkSetPassword') then Exit;
              aData.ReadA(tmpStringA); //Password
              fRoomInfo[senderRoom].Password := tmpStringA;
            end;
    mkSetGameInfo:
            if senderIsHost then
            begin
              fRoomInfo[senderRoom].GameInfo.LoadFromStream(aData);
              // kam_brasil: este pacote e o unico caminho pelo qual o resultado
              // de cada jogador chega ao servidor. Ver RankedObserveGameInfo.
              RankedObserveGameInfo(senderRoom);
              SaveHTMLStatus;
            end;
    mkKickPlayer:
            if senderIsHost then
            begin
              // kam_brasil: o host de uma ranqueada e um dos jogadores. Expulsar
              // o adversario para ganhar por W.O. seria o cheat mais barato que
              // existe.
              if RankedBlocked(senderRoom, 'mkKickPlayer') then Exit;
              aData.Read(tmpSmallInt);
              if fClientList.GetByHandle(tmpSmallInt) <> nil then
              begin
                PacketSend(tmpSmallInt, mkKicked, TX_NET_KICK_BY_HOST, True);
                fServer.Kick(tmpSmallInt);
              end;
            end;
    mkBanPlayer:
            if senderIsHost then
            begin
              // kam_brasil: pior que o kick -- o banido nem consegue voltar.
              if RankedBlocked(senderRoom, 'mkBanPlayer') then Exit;
              aData.Read(tmpSmallInt);
              if fClientList.GetByHandle(tmpSmallInt) <> nil then
              begin
                BanPlayerFromRoom(tmpSmallInt, senderRoom);
                PacketSend(tmpSmallInt, mkKicked, TX_NET_BANNED_BY_HOST, True);
                fServer.Kick(tmpSmallInt);
              end;
            end;
    mkGiveHost:
            if senderIsHost then
            begin
              // kam_brasil: passar o host adiante e passar adiante o poder que
              // acabamos de tirar dele.
              if RankedBlocked(senderRoom, 'mkGiveHost') then Exit;
              aData.Read(tmpSmallInt);
              if fClientList.GetByHandle(tmpSmallInt) <> nil then
              begin
                fRoomInfo[senderRoom].HostHandle := tmpSmallInt;
                //Tell everyone about the new host and password/description (so new host knows it)
                M2 := TKMemoryStreamBinary.Create;
                M2.Write(fRoomInfo[senderRoom].HostHandle);
                M2.WriteA(fRoomInfo[senderRoom].Password);
                M2.WriteW(fRoomInfo[senderRoom].GameInfo.Description);
                PacketSendToRoom(mkReassignHost, senderRoom, M2);
                M2.Free;
              end;
            end;
    mkResetBans:
            if senderIsHost then
            begin
              SetLength(fRoomInfo[senderRoom].BannedIPs, 0);
            end;
    mkGetServerInfo:
            begin
              M2 := TKMemoryStreamBinary.Create;
              SaveToStream(M2);
              PacketSend(aSenderHandle, mkServerInfo, M2);
              M2.Free;
            end;
    mkFPS:  begin
              client := fClientList.GetByHandle(aSenderHandle);
              aData.Read(tmpInt);
              // We use Integer for exchange (standard data type), but we can store and send out Word for compactness
              client.FPS := Word(tmpInt);
            end;
    mkPong:
            begin
              client := fClientList.GetByHandle(aSenderHandle);
              if (client.fPingStarted <> 0) then
              begin
                client.Ping := Math.Min(TimeSince(client.fPingStarted), High(Word));
                client.fPingStarted := 0;
              end;
            end;
  end;
end;


//Someone has send us something
//Send only complete messages to allow to add server messages inbetween
procedure TKMNetServer.DataAvailable(aHandle: TKMNetHandleIndex; aData: Pointer; aLength: Cardinal);
//  function GetMessKind(aSenderHandle: TKMNetHandleIndex; aData: Pointer; aLength: Cardinal): TKMNetMessageKind;
//  var
//    M: TKMemoryStream;
//  begin
//    M := TKMemoryStream.Create;
//    M.WriteBuffer(aData^, aLength);
//    M.Position := 0;
//    M.Read(Result, SizeOf(Result));
//    M.Free;
//  end;

var
  I, senderRoom: Integer;
  packetSender, packetRecipient: TKMNetHandleIndex;
  packetLength: Word;
  senderClient: TKMServerClient;
//  Kind: TKMNetMessageKind;
begin
  Inc(fBytesRX, aLength);
  senderClient := fClientList.GetByHandle(aHandle);
  if senderClient = nil then
  begin
    Status('Warning: Data Available from an unassigned client');
//    gLog.AddTime('Warning: Data Available from an unassigned client');
    Exit;
  end;

  //Append new data to buffer
  SetLength(senderClient.fBuffer, senderClient.fBufferSize + aLength);
  Move(aData^, senderClient.fBuffer[senderClient.fBufferSize], aLength);
  senderClient.fBufferSize := senderClient.fBufferSize + aLength;

//  gLog.AddTime('----  Received data from ' + GetNetAddressStr(aHandle) + ': length = ' + IntToStr(aLength));

  //Try to read data packet from buffer
  while senderClient.fBufferSize >= 6 do
  begin
    packetSender := PKMNetHandleIndex(@senderClient.fBuffer[0])^;
    packetRecipient := PKMNetHandleIndex(@senderClient.fBuffer[2])^;
    packetLength := PWord(@senderClient.fBuffer[4])^;

    //Do some simple range checking to try to detect when there is a serious error or flaw in the code (i.e. Random data in the buffer)
    if not (IsValidHandle(packetRecipient) and IsValidHandle(packetSender) and (packetLength <= MAX_PACKET_SIZE)) then
    begin
      //When we receive corrupt data kick the client since we have no way to recover (if in-game client will auto reconnect)
      Status('Warning: Corrupt data received, kicking client ' + IntToStr(aHandle));
      senderClient.fBufferSize := 0;
      SetLength(senderClient.fBuffer, 0);
      fServer.Kick(aHandle);
      Exit;
    end;

    if packetLength > senderClient.fBufferSize - 6 then
      Exit; //This message was split, so we must wait for the remainder of the message to arrive

    senderRoom := fClientList.GetByHandle(aHandle).Room;

    //If sender from packet contents doesn't match the socket handle, don't process this packet (client trying to fake sender)
    if packetSender = aHandle then
    begin
//      Kind := GetMessKind(PacketSender, @SenderClient.fBuffer[6], PacketLength);
//      gLog.AddTime('Got msg %s from %d to %d', [GetEnumName(TypeInfo(TKMNetMessageKind), Integer(Kind)), PacketSender, PacketRecipient]);

      // kam_brasil: numa sala reservada, os pacotes que definem a partida
      // (lista, opcoes, mapa, inicio) so trafegam se baterem com a reserva.
      //
      // A conferencia vem aqui, e nao no HandleMessage, porque esses pacotes
      // nao sao enderecados ao servidor: o host os difunde e o servidor apenas
      // repassa. Este e o unico ponto por onde eles passam sob nosso controle.
      if (packetLength > 0) and (senderRoom <> -1)
      and not RankedRelayAllowed(aHandle, senderRoom, @senderClient.fBuffer[6], packetLength) then
      begin
        // Descartado. O ajuste de indices no fim do laco ainda roda, entao o
        // buffer avanca normalmente e a conexao segue viva.
      end
      else
      case packetRecipient of
        NET_ADDRESS_OTHERS: //Transmit to all except sender
                //Iterate backwards because sometimes calling Send results in ClientDisconnect (LNet only?)
                for I := fClientList.Count - 1 downto 0 do
                  if (aHandle <> fClientList[i].Handle) and (senderRoom = fClientList[i].Room) then
                    SendDataQueue(fClientList[i].Handle, @senderClient.fBuffer[0], packetLength+6);
        NET_ADDRESS_ALL: //Transmit to all including sender (used mainly by TextMessages)
                //Iterate backwards because sometimes calling Send results in ClientDisconnect (LNet only?)
                for I := fClientList.Count - 1 downto 0 do
                  if senderRoom = fClientList[i].Room then
                    SendDataQueue(fClientList[i].Handle, @senderClient.fBuffer[0], packetLength+6);
        NET_ADDRESS_HOST:
                // kam_brasil: o mkAskToJoin carrega o nickname e vai para o host.
                // Este e o unico ponto por onde ele passa sob nosso controle.
                if (packetLength > 0)
                and (TKMNetMessageKind(senderClient.fBuffer[6]) = mkAskToJoin)
                and not AuthNicknameAllowed(aHandle, @senderClient.fBuffer[6], packetLength) then
                begin
                  PacketSend(aHandle, mkRefuseToJoin, TX_KB_NICKNAME_MISMATCH, True);
                  fServer.Kick(aHandle);
                  Exit;
                end
                else
                if senderRoom <> -1 then
                begin
                  // kam_brasil: numa sala reservada, parte do que seria decisao
                  // do host (o pronto de cada jogador) e decisao do servidor.
                  // Esses pacotes param aqui em vez de chegar ao host.
                  if not RankedHostPacketTaken(aHandle, senderRoom, @senderClient.fBuffer[6], packetLength) then
                    SendDataQueue(fRoomInfo[senderRoom].HostHandle, @senderClient.fBuffer[0], packetLength+6);
                end;
        NET_ADDRESS_SERVER:
                RecieveMessage(packetSender, @senderClient.fBuffer[6], packetLength);
        else    SendDataQueue(packetRecipient, @senderClient.fBuffer[0], packetLength+6);
      end;
    end;

    //Processing that packet may have caused this client to be kicked (joining room where banned)
    //and in that case SenderClient is invalid so we must exit immediately
    if fClientList.GetByHandle(aHandle) = nil then
      Exit;

    if senderClient.fBufferSize > 6 + packetLength then //Check range
      Move(senderClient.fBuffer[6 + packetLength], senderClient.fBuffer[0], senderClient.fBufferSize-packetLength-6);
    senderClient.fBufferSize := senderClient.fBufferSize - packetLength - 6;
  end;
end;


procedure TKMNetServer.SaveToStream(aStream: TKMemoryStream);
var
  I, roomsNeeded, emptyRoomID: Integer;
  needEmptyRoom: boolean;
begin
  roomsNeeded := 0;
  for I := 0 to fRoomCount - 1 do
    if GetRoomClientsCount(I) > 0 then
      Inc(roomsNeeded);

  if roomsNeeded < fMaxRooms then
  begin
    Inc(roomsNeeded); //Need 1 empty room at the end, if there is space
    needEmptyRoom := True;
  end
  else
    needEmptyRoom := False;

  aStream.Write(roomsNeeded);
  emptyRoomID := fRoomCount;
  for I := 0 to fRoomCount - 1 do
  begin
    if GetRoomClientsCount(I) = 0 then
    begin
      if emptyRoomID = fRoomCount then
        emptyRoomID := I;
    end
    else
    begin
      aStream.Write(I); //RoomID
      aStream.Write(fRoomInfo[I].GameRevision);
      fRoomInfo[I].GameInfo.SaveToStream(aStream);
    end;
  end;
  //Write out the empty room at the end
  if needEmptyRoom then
  begin
    aStream.Write(emptyRoomID); //RoomID
    aStream.Write(TKMGameRevision(EMPTY_ROOM_DEFAULT_GAME_REVISION)); //no game revision was set yet
    fEmptyGameInfo.SaveToStream(aStream);
  end;
end;


function TKMNetServer.IsValidHandle(aHandle: TKMNetHandleIndex): Boolean;
begin
  //Can not use "in [...]" with negative numbers
  Result := (aHandle = NET_ADDRESS_OTHERS) or (aHandle = NET_ADDRESS_ALL)
         or (aHandle = NET_ADDRESS_HOST) or (aHandle = NET_ADDRESS_SERVER)
         or fServer.IsValidHandle(aHandle);
end;


function TKMNetServer.AddNewRoom: Boolean;
begin
  if fRoomCount = fMaxRooms then
    Exit(False);

  Result := True;
  Inc(fRoomCount);
  SetLength(fRoomInfo, fRoomCount);
  fRoomInfo[fRoomCount-1].HostHandle := NET_ADDRESS_EMPTY;
  fRoomInfo[fRoomCount-1].GameRevision := 0;
  fRoomInfo[fRoomCount-1].Password := '';
  fRoomInfo[fRoomCount-1].GameInfo := TKMNetGameInfo.Create;
  SetLength(fRoomInfo[fRoomCount-1].BannedIPs, 0);
end;


function TKMNetServer.GetFirstAvailableRoom: Integer;
var
  I: Integer;
begin
  for I := 0 to fRoomCount-1 do
    // kam_brasil: sala reservada nao entra no rodizio de "primeira vaga livre".
    // Sem isto, quem clica em Multijogador cai justamente na sala que a fila
    // separou para uma partida ranqueada.
    if (GetRoomClientsCount(I) = 0) and not fRankedRooms.IsReserved(I) then
      Exit(I);

  // Otherwise we must create a room
  if AddNewRoom then
    Result := fRoomCount-1
  else
    Result := -1;
end;


function TKMNetServer.GetRoomClientsCount(aRoom: Integer): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to fClientList.Count - 1 do
    if fClientList[I].Room = aRoom then
      Inc(Result);
end;


function TKMNetServer.GetFirstRoomClient(aRoom: Integer): Integer;
var
  I: Integer;
begin
  for I := 0 to fClientList.Count - 1 do
    if fClientList[I].Room = aRoom then
      Exit(fClientList[I].fHandle);

  raise Exception.Create('Error in GetFirstRoomClient');
end;


procedure TKMNetServer.SaveHTMLStatus;

  function AddThousandSeparator(const aStr: string; aChr: Char=','): string;
  var
    I: Integer;
  begin
    Result := aStr;
    I := Length(aStr) - 2;
    while I > 1 do
    begin
      Insert(aChr, Result, I);
      I := I - 3;
    end;
  end;

  function ColorToText(aCol: Cardinal): string;
  begin
    Result := '#' + IntToHex(aCol and $FF, 2) + IntToHex((aCol shr 8) and $FF, 2) + IntToHex((aCol shr 16) and $FF, 2);
  end;

const
  BOOL_TEXT: array[Boolean] of string = ('0', '1');
var
  I, K, playerCount, clientCount, roomCount: Integer;
  xml: TXmlVerySimple;
  html: string;
  roomCountNode, clientCountNode, playerCountNode, node: TXmlNode;
  myFile: TextFile;
begin
  if fHTMLStatusFile = '' then exit; //Means do not write status

  roomCount := 0;
  playerCount := 0;
  clientCount := 0;

  xml := TXmlVerySimple.Create;

  try
    //HTML header
    html := '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">'+sLineBreak+
            '<HTML>'+sLineBreak+'<HEAD>'+sLineBreak+'  <TITLE>KaM Remake Server Status</TITLE>'+sLineBreak+
            '  <meta http-equiv="content-type" content="text/html; charset=utf-8">'+sLineBreak+'</HEAD>'+sLineBreak;
    html := html + '<BODY>'+sLineBreak;
    html := html + '<TABLE border="1">'+sLineBreak+'<TR><TD><b>Room ID</b></TD><TD><b>State</b><TD><b>Player Count</b></TD></TD><TD><b>Map</b></TD><TD><b>Game Time</b></TD><TD><b>Player Names</b></TD></TR>'+sLineBreak;

    //XML header
    xml.Root.NodeName := 'server';
    roomCountNode := xml.Root.AddChild('roomcount'); //Set it later
    playerCountNode := xml.Root.AddChild('playercount');
    clientCountNode := xml.Root.AddChild('clientcount');
    xml.Root.AddChild('bytessent').Text := IntToStr(fBytesTX);
    xml.Root.AddChild('bytesreceived').Text := IntToStr(fBytesRX);

    for I:=0 to fRoomCount-1 do
      if GetRoomClientsCount(I) > 0 then
      begin
        inc(roomCount);
        inc(playerCount, fRoomInfo[I].GameInfo.PlayerCount);
        inc(clientCount, fRoomInfo[I].GameInfo.ConnectedPlayerCount);
        //HTML room info
        html := html + '<TR><TD>'+IntToStr(I)+
                       '</TD><TD>r'+ IntToStr(fRoomInfo[I].GameRevision) +
                       '</TD><TD>'+XMLEscape(GameStateText[fRoomInfo[I].GameInfo.GameState])+
                       '</TD><TD>'+IntToStr(fRoomInfo[I].GameInfo.ConnectedPlayerCount)+
                       '</TD><TD>'+XMLEscape(fRoomInfo[I].GameInfo.Map)+
                       '&nbsp;</TD><TD>'+XMLEscape(fRoomInfo[I].GameInfo.GetFormattedTime)+
                       //HTMLPlayersList does escaping itself
                       '&nbsp;</TD><TD>'+fRoomInfo[I].GameInfo.HTMLPlayersList+'</TD></TR>'+sLineBreak;
        //XML room info
        node := xml.Root.AddChild('room');
        node.Attribute['id'] := IntToStr(I);
        node.AddChild('state').Text := GameStateText[fRoomInfo[I].GameInfo.GameState];
        node.AddChild('roomplayercount').Text := IntToStr(fRoomInfo[I].GameInfo.PlayerCount);
        node.AddChild('map').Text := fRoomInfo[I].GameInfo.Map;
        node.AddChild('gametime').Text := fRoomInfo[I].GameInfo.GetFormattedTime;
        with node.AddChild('players') do
        begin
          for K:=1 to fRoomInfo[I].GameInfo.PlayerCount do
            with AddChild('player') do
            begin
              Text := UnicodeString(fRoomInfo[I].GameInfo.Players[K].Name);
              SetAttribute('color', ColorToText(fRoomInfo[I].GameInfo.Players[K].Color));
              SetAttribute('connected', BOOL_TEXT[fRoomInfo[I].GameInfo.Players[K].Connected]);
              SetAttribute('type', NetPlayerTypeName[fRoomInfo[I].GameInfo.Players[K].PlayerType]);
              SetAttribute('langcode', UnicodeString(fRoomInfo[I].GameInfo.Players[K].LangCode));
              SetAttribute('team', IntToStr(fRoomInfo[I].GameInfo.Players[K].Team));
              SetAttribute('spectator', BOOL_TEXT[fRoomInfo[I].GameInfo.Players[K].IsSpectator]);
              SetAttribute('host', BOOL_TEXT[fRoomInfo[I].GameInfo.Players[K].IsHost]);
              SetAttribute('won_or_lost', WonOrLostText[fRoomInfo[I].GameInfo.Players[K].WonOrLost]);
            end;
        end;
      end;
    //Set counts in XML
    roomCountNode.Text := IntToStr(roomCount);
    playerCountNode.Text := IntToStr(playerCount);
    clientCountNode.Text := IntToStr(clientCount);

    //HTML footer
    html := html + '</TABLE>'+sLineBreak+
                   '<p>Total sent: '+AddThousandSeparator(IntToStr(fBytesTX))+' bytes</p>'+sLineBreak+
                   '<p>Total received: '+AddThousandSeparator(IntToStr(fBytesRX))+' bytes</p>'+sLineBreak+
                   '</BODY>'+sLineBreak+'</HTML>';

    //Write HTML
    AssignFile(myFile, fHTMLStatusFile);
    ReWrite(myFile);
    Write(myFile,html);
    CloseFile(myFile);
    //Write XML
    xml.SaveToFile(ChangeFileExt(fHTMLStatusFile,'.xml'));
  finally
    xml.Free;
  end;
end;


end.

