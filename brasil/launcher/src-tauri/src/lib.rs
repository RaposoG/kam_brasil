mod assets;
mod auth;
mod game;
mod install;
mod original;

use auth::AppState;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![
            auth::register,
            auth::login,
            auth::logout,
            auth::restore_session,
            auth::api_base,
            install::check_update,
            install::install_update,
            game::game_status,
            game::launch_game,
            original::find_original_game,
            original::check_original_game,
            assets::assets_status,
            assets::generate_assets,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
