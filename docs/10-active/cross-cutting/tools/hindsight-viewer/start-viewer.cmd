@echo off
rem 分类：只测试（Test-only）。启动 Hindsight 只读查看器并打开浏览器。
chcp 65001 >nul
cd /d "%~dp0"
echo Hindsight 只读查看器：http://127.0.0.1:18940/
echo 关掉本窗口即停止。
start "" "http://127.0.0.1:18940/"
python -B viewer.py %*
pause
