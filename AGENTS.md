## 実装後の動作チェック手順（Godot 4）

コンソールから毎回チェックできるように、以下のコマンドを使います。プロジェクトルートは `/Users/s18329/WorkSpace/shiraFZu/Game/Farkov` 前提。

### 1) シーンをヘッドレス実行してスクリプト／リソースエラー確認
```
/Applications/Godot.app/Contents/MacOS/Godot --path /Users/s18329/WorkSpace/shiraFZu/Game/Farkov scenes/WorldView.tscn --headless --verbose
```
- スクリプトのパースエラー、依存リソース欠如があればここで表示されます。

### 2) エディタをコンソール付きで起動（必要時）
```
/Applications/Godot.app/Contents/MacOS/Godot --path /Users/s18329/WorkSpace/shiraFZu/Game/Farkov --editor --verbose
```
- エディタ起動中の警告/エラーをコンソールで確認できます。

### 3) 実行前の簡易チェック
- Godot 4.5.1 を使用（コンソールにバージョン表示）。
- `scenes/WorldView.tscn` がメインシーン。

### 運用メモ
- 変更を入れたら上記 (1) を必ず実行し、エラーが無いことを確認してから Play。
