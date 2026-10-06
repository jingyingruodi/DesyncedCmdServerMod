# Desynced Dedicated Server Launcher (UTF-8 Safe)
# PowerShell 原生 UTF-8，彻底解决中文乱码

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$SavePath  = "C:\Users\Administrator\AppData\Local\Desynced\Saved\SaveGames\LocalServerTest3.desynced"
$Port      = 10099
$QueryPort = 27015
$AdminID   = "76561199022742454"

# 直接拼接原始格式（保持与原 bat 完全一致的参数格式）
$sessionName = "镜影若滴的模组开发测试服2，QQ群：726525226。"
$SessionSettings = "{ 'name': '$sessionName', 'players': 255, 'mode': 'Separate/Versus', 'run_without_players': false, 'visibility': 'public', 'allow_faction_switch': true, 'auto_save': 10 }"
$GameSettings    = "{ 'enable_day_night': true, 'allow_race_selection': false, 'days_per_year': 20, 'day_night_ratio': 4, 'day_period': 1000, 'day_start_offset': 0.3, 'year_start_offset': 0.5, 'year_period': 20, 'peaceful': 3, 'creep': true, 'resource_inf': true, 'resource_amt': 1145.14, 'difficulty': 2, 'plateau_level': 0.15, 'water_level': -0.45, 'blight_threshold': 0.12, 'elevation_params_freq': 1.2, 'elevation_params_scale': 0.9, 'disable_minigames': true }"

Write-Host "[Launcher] Starting Desynced Dedicated Server with UTF-8 encoding..." -ForegroundColor Green
Write-Host "[Launcher] Session: $sessionName" -ForegroundColor Cyan

& ".\Binaries\Win64\DesyncedServer.exe" `
    $SavePath `
    "-Port=$Port" `
    "-QueryPort=$QueryPort" `
    "-SessionSettings=$SessionSettings" `
    "-GameSettings=$GameSettings" `
    "-UTF8Output" `
    "-moddev" `
    "-logsteam" `
    "-secure" `
    "-admin=$AdminID"
