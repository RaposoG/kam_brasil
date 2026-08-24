program teste_match;
// Le a partida apontada por KAMBRASIL_MATCH_FILE e imprime o que
// KM_KamBrasilMatch entendeu. Quem confere os valores e o roda.sh ao lado.
{$MODE DELPHI}
uses
  SysUtils, KM_KamBrasilMatch;
var
  m: TKMKamBrasilMatch;
begin
  m := KamBrasilMatch;
  WriteLn('disponivel=', m.Disponivel);
  WriteLn('servidor=', m.Servidor);
  WriteLn('porta=', m.Porta);
  WriteLn('sala=', m.Sala);
  WriteLn('senha=[', m.Senha, ']');
  // O arquivo tem que sumir na leitura, como o do token de sessao.
  WriteLn('arquivo_sumiu=', not FileExists(GetEnvironmentVariable('KAMBRASIL_MATCH_FILE')));
  KamBrasilMatchUsada;
  WriteLn('apos_usada=', KamBrasilMatch.Disponivel);
end.
