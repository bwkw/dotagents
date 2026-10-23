# VOICEVOXでナレーションを作る

## 導入と起動

[公式サイト](https://voicevox.hiroshiba.jp/)からOSとCPUに合うVOICEVOXを導入する。
macOSではアプリをApplicationsへ配置し、次のコマンドで起動する。

```bash
open -a VOICEVOX
curl --fail --silent http://127.0.0.1:50021/version
```

初回の案内が出た場合は画面の内容を確認し、エンジンの起動を待つ。
接続できない時はアプリの起動状態とポートを確認する。外部サービスへ自動で切り替えない。
APIだけを使う場合も、VOICEVOX本体か公式エンジンを起動しておく。

## シナリオの設定

```js
export default {
  // url、ready、scenesなどは既存のシナリオと同じ
  voicevox: {
    url: 'http://127.0.0.1:50021', // 省略可。ローカルHTTPのみ
    speaker: 2,                  // 四国めたん／ノーマル
    speedScale: 1.05,            // 話速。0より大きく2以下
  },
};
```

`speaker` はキャラクターの番号ではなく、`/speakers` が返すトーク用スタイルのID。
話者を変える場合は、起動中のエンジンに問い合わせて選ぶ。

```bash
curl --fail --silent http://127.0.0.1:50021/speakers
```

旧edge-tts用の `voice` と `rate` は使わない。指定が残っていたら `check` で移行を促す。
シナリオの `say` は引き続きナレーション本文で、macOSの同名コマンドとは関係しない。

## 音声から動画への流れ

```bash
node ${CLAUDE_SKILL_DIR}/scripts/demo.mjs tts <作業ディレクトリ>/scenario.mjs
node ${CLAUDE_SKILL_DIR}/scripts/demo.mjs record <作業ディレクトリ>/scenario.mjs
node ${CLAUDE_SKILL_DIR}/scripts/demo.mjs compose <作業ディレクトリ>/scenario.mjs
```

`tts` はローカルAPIの `/audio_query` と `/synthesis` を呼び、`audio/<シーンID>.wav` を作る。
話者、スタイル、話速、クレジットは `audio/voicevox.json` に記録する。
`record` はこの記録を読み、動画の右下に `VOICEVOX:四国めたん` などのクレジットを表示する。
`compose` はWAVを読み、AAC音声付きmp4を書き出す。
最初から全工程を作るなら従来どおり `all` が使える。

音声や話者を変更した場合は `tts` からやり直す。
旧mp3からの移行時も、音声と撮影を再生成する。
ユーザーには短いWAVを試聴用に渡し、話者の好みと読みを確認できるようにする。
音声の合成とデコードの成功を、聴感や読み方の確認済みとは扱わない。

## クレジットと根拠

[VOICEVOX公式規約](https://voicevox.hiroshiba.jp/term/)に沿って利用表記を残す。
既定の四国めたんは[音源利用ガイドライン](https://zunko.jp/con_ongen_kiyaku.html)を参照する。
別の話者へ変更した時は、その音声ライブラリの規約も確認する。
動画からクレジットを消さず、共有本文にも音声ライブラリ名を添える。

APIの呼び方は[公式VOICEVOX ENGINE](https://github.com/VOICEVOX/voicevox_engine)を根拠とする。
