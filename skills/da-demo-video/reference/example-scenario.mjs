// 最小のシナリオ。ログイン不要の公開ページなので、セットアップ直後の動作確認に使える:
//   cp example-scenario.mjs <作業ディレクトリ>/scenario.mjs && node demo.mjs all <作業ディレクトリ>/scenario.mjs
// 実際の機能紹介では、画面を操作するシーンを run に書き足していく（SKILL.md の「シナリオを書く」）。
export default {
  url: 'https://example.com/',
  ready: (page) => page.getByRole('heading', { name: 'Example Domain' }), // 表示完了の目印
  hide: [],               // 映したくない文字列（環境名・組織名など）の正規表現
  hideSelectors: [],      // 映したくない要素の CSS セレクタ
  output: 'example.mp4',

  // 撮影で保存した変更を元に戻す。撮影の前と後（失敗時も）に走る。保存しないシナリオでは書かない
  // async cleanup(page) {},

  scenes: [
    {
      id: 'title',
      say: 'この動画は、機能紹介動画の作り方の見本です。',
      // 最初のシーンのカードは撮影開始前に出る。次のシーンがカードでなければ、終わりに消える
      card: `<div><span class="tag">見本</span></div><h1>機能紹介動画の見本</h1><div class="sub">カード・テロップ・枠・カーソル・ズーム</div>`,
    },
    {
      id: 'point',
      cap: '見せたい場所を枠で囲み、カーソルを動かす',
      say: '見せたい場所を枠で囲み、カーソルをそこへ動かします。',
      async run(h) {
        const heading = h.page.getByRole('heading', { name: 'Example Domain' });
        await h.hl(heading);
        await h.moveTo(heading);
        await h.sleep(800);
        await h.zoom(heading, 1.6); // ズームは見せるだけの場面で使う
        await h.sleep(1200);
        await h.hlOff();
        await h.unzoom();
      },
    },
    {
      id: 'summary',
      say: '最後に、まとめのカードを出して終わります。',
      card: `<h1 style="font-size:44px">まとめ</h1><div class="cols">
        <div class="col after"><h2>できること</h2><ul><li>実画面を自動で操作して撮る</li></ul></div>
        <div class="col"><h2>知っておくこと</h2><ul><li>ナレーションの長さでシーンが決まる</li></ul></div></div>`,
    },
  ],
};
