// Versao do Kam Brasil exibida ao jogador -- canto do menu, titulo da janela,
// log e banner do servidor dedicado.
//
// E SO exibicao. Compatibilidade de save, replay e protocolo continua nos
// numeros do upstream (KM_Revision.inc e KM_NetProtocolRevision.inc), que sao
// inteiros e tem semantica propria: um save so carrega na mesma revisao, e o
// master server so lista servidores do mesmo protocolo.
//
// Suba este numero SEMPRE que rebuildar o cliente, e publique a release da API
// com o mesmo numero. Se voce publicar uma versao que so muda conteudo (mapas,
// textos) sem rebuildar, o executavel vai continuar dizendo o numero anterior
// -- o que e verdade, porque o binario nao mudou.
// Sem ponto-e-virgula no fim: ele vem depois do {$I ...} em KM_Defaults.pas,
// como nos .inc de revisao do upstream. Com um aqui, a declaracao fecha duas
// vezes e o Delphi para em "Declaration expected but ';' found".
KAM_BRASIL_VERSION = '1.0.5'
