# Koe15 — macOS 15 対応フォーク

[hanafusay/koe](https://github.com/hanafusay/koe) の日本語音声入力アプリを、macOS 15 SDK・Swift 6.1 で動くように変更した版です。

## できること・制限

| 機能 | Koe15 |
|---|---|
| 日本語音声入力・途中結果の入力 | 対応。Apple の SFSpeechRecognizer を使用 |
| fn 長押し・2回押しのハンズフリー | 対応。1回最大55秒。認識エンジンが先に終了した場合も確定 |
| 辞書・履歴・マイク選択・再貼り付け | 対応 |
| 選択した文章を音声指示で書き換える | 非対応。選択範囲を変更せず、理由を表示 |
| アプリ名・設定・権限 | Koe15.app / com.koe.macos15。元の Koe と別管理 |

音声は Mac 内で処理し、クラウド認識に切り替えません。macOS 26 版とは認識精度・遅延・句読点が異なります。Apple Intelligence の文章修正機能は使えません。

## ビルド・起動

macOS 15 以上、Command Line Tools（macOS 15 SDK）、Swift 6.1 以上が必要です。

```bash
git clone --branch feat/macos15-support https://github.com/nakamuraha2082/koe-macos15.git
cd koe-macos15
./build.sh
open /Applications/Koe15.app
```

build.sh はビルド・アドホック署名・配置を行います。既存の Koe15.app は置き換えますが、元の Koe.app は上書きしません。両方を同時起動すると録音キーが競合するため、片方だけ起動してください。

初回起動時にマイク・音声認識・アクセシビリティ・入力監視を Koe15 に許可し、アプリを再起動してください。日本語のオンデバイス認識モデルが使えない場合は、システム設定 → キーボード → 音声入力を日本語で有効にして、準備完了後に再試行してください。モデルをこのアプリから直接インストールする機能はありません。

## 使い方

| 操作 | 動作 |
|---|---|
| fn を押しながら話す → 離す | 音声入力して確定 |
| fn を素早く2回押す | ハンズフリー。もう一度押して確定 |
| 録音中に Esc | 取り消し |
| Control + Command + V | 直前の入力を貼り直す |
| メニューバー → 設定 | 録音キー・マイク・辞書・権限を確認 |
| 設定 → サンプル音声で確認 | マイクを使わず、付属音声で認識と入力差分の整合性を検査 |

1回55秒までです。続きは録音を開始し直してください。録音キーは右 Option・Control にも変更できます。fn で絵文字が開く場合は、システム設定のキーボード設定で地球儀キーの動作を「何もしない」にしてください。文字が選択されている場合は選択を解除してから録音してください。

## プライバシー

- Apple 純正フレームワークのみ使用。API キーは不要です。
- supportsOnDeviceRecognition を確認し、requiresOnDeviceRecognition を true に固定します。クラウドへのフォールバックはありません。
- 辞書・設定・直近10件の履歴はローカルの UserDefaults に保存します。
- ログは `~/Library/Logs/Koe15/koe.log`。起動ごとに作り直し、本人だけが読める権限で保存します。

## 検証・配布

```bash
bash scripts/check-trigger-state-machine.sh
source scripts/lib.sh && build_release && create_app_bundle && codesign_app
say -v Kyoko -o /tmp/koe15-sample.aiff "スラックで仕様を確認します"
/Applications/Koe15.app/Contents/MacOS/Koe --transcribe-file /tmp/koe15-sample.aiff --dictionary Slack=スラック
./create-dmg.sh
```

音声ファイルの検査はキー入力を送らず、認識文と入力結果を標準出力に表示します。音声認識の許可が必要です。ターミナルからの実行が別の実行元として扱われ、権限エラーになる場合は、アプリの設定にある「サンプル音声で確認」を使ってください。失敗・空の認識結果・入力結果不一致では終了コード1を返します。DMG は dist/Koe15-<version>.dmg に生成します。Developer ID による署名・公証は行っていません。

設計は [ARCHITECTURE.md](ARCHITECTURE.md)、元の使い方は [上流 README](https://github.com/hanafusay/koe#readme) を参照してください。

## ライセンス

元の著作権表示を維持した [MIT License](LICENSE) です。
