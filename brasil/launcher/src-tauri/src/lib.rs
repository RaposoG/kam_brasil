mod auth;
mod game;
mod original;

use auth::AppState;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![
            auth::register,
            auth::login,
            auth::logout,
            auth::restore_session,
            auth::api_base,
            game::game_status,
            game::check_update,
            game::install_update,
            game::launch_game,
            original::find_original_game,
            original::check_original_game,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
