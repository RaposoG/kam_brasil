unit KM_GUIMenuMain;
{$I KaM_Remake.inc}
interface
uses
  Math, SysUtils,
  KM_Controls, KM_ControlsBase, KM_ControlsEdit,
  KM_Pics, KM_InterfaceDefaults, KM_InterfaceTypes;


type
  TKMMenuMain = class(TKMMenuPageCommon)
  private
    fOnPageChange: TKMMenuChangeEventText;
    fAutoJoinTentado: Boolean; // kam_brasil
    procedure ButtonClick(Sender: TObject);
  protected
    Panel_MainMenu: TKMPanel;
    Panel_MMButtons: TKMPanel;
    Button_MM_SinglePlayer: TKMButton;
    Button_MM_MultiPlayer: TKMButton;
    Button_MM_MapEd: TKMButton;
    Button_MM_Replays: TKMButton;
    Button_MM_Options: TKMButton;
    Button_MM_Credits: TKMButton;
    Button_MM_Quit: TKMButton;
  public
    constructor Create(aParent: TKMPanel; aOnPageChange: TKMMenuChangeEventText);
    procedure Show;
    procedure UpdateState;
  end;


implementation
uses
  KM_Main,
  KM_GameApp,
  KM_KamBrasilMatch, // kam_brasil: sala reservada entregue pelo launcher
  KM_ResTexts, KM_ResFonts, KM_ResTypes,
  KM_RenderUI;


{ TKMMenuMain }
constructor TKMMenuMain.Create(aParent: TKMPanel; aOnPageChange: TKMMenuChangeEventText);
begin
  inherited Create(gpMainMenu);

  fOnPageChange := aOnPageChange;

  //Without anchors this page is centered on resize
  Panel_MainMenu := TKMPanel.Create(aParent, 0, 0, aParent.Width, aParent.Height);
  Panel_MainMenu.AnchorsCenter;
    TKMImage.Create(Panel_MainMenu, 300, 120, 423, 164, 4, rxGuiMain);
    TKMLabel.Create(Panel_MainMenu, 512, 300, 'Remake', fntMetal, taCenter);

    with TKMImage.Create(Panel_MainMenu,  50, 220, Round(218*1.3), Round(291*1.3), 5, rxGuiMain) do
      ImageStretch;
    with TKMImage.Create(Panel_MainMenu, 705, 220, Round(207*1.3), Round(295*1.3), 6, rxGuiMain) do
      ImageStretch;

    Panel_MMButtons := TKMPanel.Create(Panel_MainMenu, 337, 340, 350, 400);
      Button_MM_SinglePlayer := TKMButton.Create(Panel_MMButtons,0,  0,350,30,gResTexts[TX_MENU_SINGLEPLAYER],bsMenu);
      Button_MM_MultiPlayer  := TKMButton.Create(Panel_MMButtons,0, 40,350,30,gResTexts[TX_MENU_MULTIPLAYER],bsMenu);
      Button_MM_MapEd        := TKMButton.Create(Panel_MMButtons,0, 80,350,30,gResTexts[TX_MENU_MAP_EDITOR],bsMenu);
      Button_MM_Replays      := TKMButton.Create(Panel_MMButtons,0,120,350,30,gResTexts[TX_MENU_REPLAYS],bsMenu);
      Button_MM_Options      := TKMButton.Create(Panel_MMButtons,0,160,350,30,gResTexts[TX_MENU_OPTIONS],bsMenu);
      Button_MM_Credits      := TKMButton.Create(Panel_MMButtons,0,200,350,30,gResTexts[TX_MENU_CREDITS],bsMenu);
      Button_MM_Quit         := TKMButton.Create(Panel_MMButtons,0,290,350,30,gResTexts[TX_MENU_QUIT],bsMenu);
      Button_MM_SinglePlayer.OnClick := ButtonClick;
      Button_MM_MultiPlayer.OnClick  := ButtonClick;
      Button_MM_MapEd.OnClick        := ButtonClick;
      Button_MM_Replays.OnClick      := ButtonClick;
      Button_MM_Options.OnClick      := ButtonClick;
      Button_MM_Credits.OnClick      := ButtonClick;
      Button_MM_Quit.OnClick         := ButtonClick;
end;


procedure TKMMenuMain.ButtonClick(Sender: TObject);
begin
  if Sender = Button_MM_SinglePlayer then
    fOnPageChange(gpSinglePlayer);

  if Sender = Button_MM_MultiPlayer then
  begin
    if gMain.LockMutex then
    begin
      if not gGameApp.CheckDATConsistency then
      begin
        fOnPageChange(gpError, gResTexts[TX_ERROR_MODS]);
        gMain.UnlockMutex;
      end
      else
        fOnPageChange(gpMultiplayer);
    end
    else
      fOnPageChange(gpError, gResTexts[TX_MULTIPLE_INSTANCES]);
  end;

  if Sender = Button_MM_MapEd then
    fOnPageChange(gpMapEditor);

  if Sender = Button_MM_Replays then
    fOnPageChange(gpReplays);

  if Sender = Button_MM_Options then
    fOnPageChange(gpOptions);

  if Sender = Button_MM_Credits then
    fOnPageChange(gpCredits);

  if Sender = Button_MM_Quit then
    gMain.Stop(Self);
end;


procedure TKMMenuMain.Show;
begin
  Panel_MainMenu.Show;
end;


// kam_brasil: com partida reservada pelo launcher, o jogo vai sozinho para o
// multijogador -- de la KM_GUIMenuMultiplayer entra na sala.
//
// Daqui e nao de dentro de Show: Show roda no meio de PageChange, e trocar de
// pagina ali deixaria fMenuPage apontando para a pagina errada (o PageChange de
// fora ainda faz o seu `fMenuPage := fMenuMain` depois de nos).
//
// Passa por ButtonClick, e nao direto por fOnPageChange, para nao duplicar o
// mutex de instancia unica e a checagem dos .dat que o botao ja faz.
//
// Uma vez so: se o multijogador estiver barrado (outra instancia aberta, dat
// alterado) ButtonClick manda para a tela de erro, e insistir a cada volta ao
// menu prenderia o jogador nela.
procedure TKMMenuMain.UpdateState;
begin
  if fAutoJoinTentado or not Panel_MainMenu.Visible then Exit;

  fAutoJoinTentado := True;
  if KamBrasilMatch.Disponivel then
    ButtonClick(Button_MM_MultiPlayer);
end;


end.
