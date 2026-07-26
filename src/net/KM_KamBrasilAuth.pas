unit KM_KamBrasilAuth;
{$I KaM_Remake.inc}
interface

// Token de sessao do Kam Brasil, entregue pelo launcher.
//
// O launcher grava o token num arquivo temporario e passa o caminho pela
// variavel de ambiente KAMBRASIL_TOKEN_FILE. NAO usamos argumento de linha de
// comando: argumentos ficam visiveis na lista de processos para qualquer
// usuario da maquina, e um token de sessao ali seria um vazamento.
//
// O arquivo e lido uma unica vez e apagado em seguida -- token esquecido em
// disco e token esperando para vazar.
//
// Sem launcher (jogo aberto direto), devolve string vazia. Servidores com
// KamBrasilRequireAuth desligado nao se importam; os que exigem vao recusar,
// que e o comportamento desejado.
function KamBrasilSessionToken: AnsiString;

implementation
uses
  SysUtils, Classes;

const
  TOKEN_ENV_VAR = 'KAMBRASIL_TOKEN_FILE';

var
  gToken: AnsiString;
  gLoaded: Boolean;


function KamBrasilSessionToken: AnsiString;
var
  path: string;
  sl: TStringList;
begin
  if not gLoaded then
  begin
    gLoaded := True;
    gToken := '';

    path := GetEnvironmentVariable(TOKEN_ENV_VAR);
    if (path <> '') and FileExists(path) then
    begin
      sl := TStringList.Create;
      try
        try
          sl.LoadFromFile(path);
          if sl.Count > 0 then
            gToken := AnsiString(Trim(sl[0]));
        except
          // Arquivo ilegivel e o mesmo que nao ter token: seguimos sem ele.
          gToken := '';
        end;
      finally
        sl.Free;
      end;

      SysUtils.DeleteFile(path);
    end;
  end;

  Result := gToken;
end;


initialization
  gLoaded := False;
  gToken := '';

end.
