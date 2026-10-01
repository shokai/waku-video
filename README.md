# WakuVideo

画面の範囲を選択して録画し、ブラウザで再生できるmp4（H.264）で保存するmacOSのメニューバーアプリ。保存後はFinderでファイルを選択した状態で開くので、そのままブラウザにドラッグ&ドロップしてアップロードできる。

## インストール

Apple SiliconのMacと、macOS 15以降が必要。

1. [WakuVideo.zip](https://github.com/shokai/waku-video/releases/latest/download/WakuVideo.zip)をダウンロードして展開する。過去の版は[Releases](https://github.com/shokai/waku-video/releases)にある
2. `WakuVideo.app`をアプリケーションフォルダに移して開く
3. Appleの公証を受けていないので、「“WakuVideo”は開いていません」と表示されて止まる。「完了」を押してシステム設定の「プライバシーとセキュリティ」を開き、「お使いのMacを保護するために“WakuVideo”がブロックされました。」の横の「このまま開く」を押す。確認のダイアログでも「このまま開く」を押し、パスワードかTouch IDで認証する。ボタンが無い時は、もう一度WakuVideoを開いてから見る
4. 初めて録画しようとすると「画面収録の許可が必要です」と表示される。「システム設定を開く」を押し、「画面収録とシステムオーディオ録音」でWakuVideoを許可し、WakuVideoを再起動する

新しい版にする時は、WakuVideoを終了して`WakuVideo.app`を置き換える。開けない時は手順3と同じように開く。画面収録の許可は引き継がれる。

## 使い方

1. メニューバーのアイコン→「範囲を選択して録画」
2. 録画したい範囲をドラッグする。Escか右クリックでキャンセル
3. 録画中は範囲の周りに赤い枠と停止ボタンが出る（どちらも範囲の外側なので動画に映らない）。範囲の外に余白が無い時は停止ボタンは出ない
4. 停止ボタン、メニューバーの停止アイコン、macOSの画面共有表示の「共有を停止」のどれかで止めると、保存先に`2026-09-25 18.30.00.mp4`のように保存される

- 保存先は既定でデスクトップ。メニューの「保存先を変更…」で別のフォルダを選べる
- メニューの「動画をトリミング…」でmp4を選ぶと、QuickTime Playerと同じトリミング画面が開く。黄色い枠の両端を動かして「トリミング」を押すと、録画と同じ形式で書き直し、元のファイルと同じフォルダに`2026-09-25 18.30.00_2.mp4`のように別名で保存する。元のファイルはそのまま残る。名前が`_2`のように`_数字`で終わるファイルは番号を繰り上げて`_3`にし、既にある番号は飛ばす。音声付きの動画は扱えない。mp4内部のmetadata（タイトル・作成日時等）は引き継がない
- Retinaディスプレイでは物理pixelのまま、最大30fpsで録画する（画面が変化した時だけフレームを書く可変フレームレート）
- 各辺4096px、または4096×2304相当の面積を超える範囲は縮小する。VideoToolboxのH.264エンコーダが各辺4096pxまでしか書き出せない事と、H.264 Level 5.2に収めて再生できる環境を広げるため
- 音声は録音しない

## ビルドに必要なもの

- macOS 15以降
- Command Line Tools（`xcode-select --install`）。Xcodeは不要
- 自己署名のコード署名証明書（下記）
- `make probe`を使う場合はffmpeg（`brew install ffmpeg`）

## コード署名証明書の作成

画面収録の許可はアプリの署名に紐付く。ad-hoc署名ではビルドする度に許可が外れるので、自己署名の証明書で署名する。

1. `/System/Library/CoreServices/Applications/Keychain Access.app`を開く
2. メニューの「キーチェーンアクセス」→「証明書アシスタント」→「証明書を作成...」
3. 名前`WakuVideo Local Code Signing`、固有名の種類「自己署名ルート」、証明書のタイプ「コード署名」
4. 「デフォルトを無効化」にチェックして続け、有効期間を`3650`日にする。失効して作り直すと、画面収録を許可し直す事になる
5. 残りは既定のまま進めて作成する

初回の`make app`でキーチェーンへのアクセスを求められたら「常に許可」を選ぶ。別の名前の証明書を使う場合は`make app CODESIGN_IDENTITY="名前"`とする。

## 開発

```sh
make run        # ビルドして.appを起動
make test       # ユニットテスト（Swift Testing）
make format     # swift formatで整形
make lint       # swift formatでlint
make smoke      # debugビルドで主画面の中央を3秒録画して終了し、出力をffprobeで検査
make logs       # アプリのログを表示
make reset-tcc  # 画面収録・フォルダへのアクセスの許可をリセット
make zip        # 配布用のzipをbuild/WakuVideo.zipに作る
make release    # zipをGitHub Releasesに載せる（下記）
```

初回起動時は、システム設定の「プライバシーとセキュリティ」→「画面収録とシステムオーディオ録音」でWakuVideoを許可し、アプリを再起動する。

### リリース

1. `Support/Info.plist`の`CFBundleShortVersionString`と`CFBundleVersion`を上げ、mainにmergeする
2. mainをpullして`make release`を実行する。releaseビルドしたzipを、`v`+`CFBundleShortVersionString`のtagでGitHub Releasesに載せる。`gh auth login`済みである事

`make release`が途中で失敗したら、GitHubのReleasesに`v<version>`のreleaseとtagが残っていないか確かめる。zipの付いたreleaseが公開されていれば、リリースは済んでいる。作りかけのdraftやtagだけが残っていれば、GitHubのそれらと手元のtag（`git tag -d v<version>`）を消してから再実行する。

利用者の画面収録の許可は署名した証明書に紐付く。同じ名前で作り直した証明書は別物として扱われ、新しい版に置き換えた利用者全員が許可し直す事になる。別のMacでリリースする時は、キーチェーンアクセスで証明書を秘密鍵ごと書き出して移す。
