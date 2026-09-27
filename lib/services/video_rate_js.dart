// 動画の再生速度を「押し合わずに」 保つための JS (= ユーザー報告:
// 「youtube の再生速度倍率が広告には適用されなくなった」)。
//
// ── なぜ効かなくなっていたか ────────────────────────────────────
//  YouTube は**広告の間だけ**再生速度を 1.0 に戻す。 こちらが 200ms ごとに
//  押し返していた頃は、 押す → 戻される → 押す … を 1 秒に何度も繰り返し、
//  そのたびに `ratechange` が飛んで音の通り道が組み直され、 **広告中の音が
//  途切れ途切れ**になっていた (= 別のユーザー報告)。 b438 ではそれを
//  「広告の間は速度に触らない」 (`if (isAd()) return;`) で止めたので、
//  音切れは直った代わりに**広告だけ等速**になった。
//
// ── ここでの直し方: 押し返すのをやめて、書かせない ──────────────
//  `HTMLMediaElement.prototype.playbackRate` の **setter を横取り**して、
//  向こうが書いてくる 1.0 を**値を動かさずに握りつぶす**。 値が変わらないので
//  `ratechange` は飛ばず、 音の通り道も組み直されない。
//  → 「広告にも倍率が乗る」 と 「音が切れない」 が同時に立つ。
//
//  `defaultPlaybackRate` も一緒に押さえるのが要点。 広告 ↔ 本編の差し替えは
//  HTML の media load algorithm を通り、 その中で `playbackRate` が
//  `defaultPlaybackRate` の値に**戻される** (これは JS の setter を通らない)。
//  ここを押さえないと境目で必ず 1.0 に落ちる。
//
// ── 触る相手を絞る ──────────────────────────────────────────────
//  錠を掛けるのは **YouTube のページの `<video>` だけ** (`_hostOk`)。
//  ・他所のサイトは、 そのサイト自身の速度 UI を殺さないため素通り。
//  ・アプリ自前の mp4 プレイヤー HTML (data: / file:) も素通り
//    (あちらは `window.__MM_RATE__` を自分で見ている)。
//  ・利用者が自分で操作した直後 (900ms) の書き込みは通す。 これが無いと
//    YouTube 自身の速度メニューが「選べるのに変わらない」 という一番
//    分かりにくい壊れ方をする。
//  ・等速 (1.0) の時は錠を掛けない (= 何も干渉しない)。
//
// ── 保険 ────────────────────────────────────────────────────────
//  錠が掛けられない環境 (`defineProperty` が通らない等) では、 今までどおり
//  値を書きに行く形へ自動で落ちる。 その時だけは広告の門を残す
//  (= b438 が潰した音切れを蘇らせない)。 見回りも 2.5 秒に 1 度と緩く、
//  値が合っていれば書かないので `ratechange` は飛ばない。
library;

/// 錠前を **document start** で流し込む形。
///
/// ページを読み込み直した直後 (= プリロール広告が始まる時間帯) は、 まだ
/// Dart 側の `_injectPlaybackRate()` が走っていない。 そこで前の文書で
/// 控えておいた倍率 (`sessionStorage`) を自分で拾って当てる。
///
/// [fallbackRate] は**控えがまだ無い時だけ**使う (= その WebView で初めて
/// その入れ物を開いた時)。 控えがある時は必ずそちらが勝つので、 途中で
/// 速度を変えた後にページを読み直しても古い値へ戻らない。
String videoRateLockInstallJs({double fallbackRate = 1.0}) {
  final r = fallbackRate.clamp(0.25, 16.0).toDouble().toStringAsFixed(3);
  return '$_kRateLockBody\ntry{window.__MM_bootRate&&window.__MM_bootRate($r);}'
      'catch(e){}';
}

/// 錠前を入れた上で、 倍率 [rate] を当てる。 Dart 側から速度を変えた時に使う。
String videoRateApplyJs(double rate) {
  final r = rate.clamp(0.25, 16.0).toDouble().toStringAsFixed(3);
  return '$_kRateLockBody\ntry{window.__MM_setRate($r);}catch(e){}';
}

/// 本体。 二度流し込んでも一度しか仕掛けない。
///
/// 公開する物:
///   * `window.__MM_setRate(r)` … 目標の倍率を決めて、 今ある `<video>` に当てる
///   * `window.__MM_RATE__`     … 目標の倍率 (自前 mp4 プレイヤー HTML と共通)
///   * `window.__MM_bootRate()` … 控えてある倍率を拾って当てる (document start 用)
const String _kRateLockBody = r'''
(function(){
try{
  if (window.__MM_RATE_CORE__) return;
  window.__MM_RATE_CORE__ = true;

  var KEY = '__mm_video_rate';

  function hostOk(){
    try{
      var h = (location.hostname || '').toLowerCase();
      return h.indexOf('youtube.com') >= 0 ||
             h.indexOf('youtu.be') >= 0 ||
             h.indexOf('youtube-nocookie.com') >= 0;
    }catch(e){ return false; }
  }

  function want(){
    var r = Number(window.__MM_RATE__);
    return (r && isFinite(r) && r > 0) ? r : 1;
  }

  function save(r){
    try{ window.sessionStorage.setItem(KEY, String(r)); }catch(e){}
  }

  // ── setter の横取り ──
  var proto = window.HTMLMediaElement && window.HTMLMediaElement.prototype;
  var dP = null, dD = null;
  try{
    dP = proto && Object.getOwnPropertyDescriptor(proto, 'playbackRate');
    dD = proto && Object.getOwnPropertyDescriptor(proto, 'defaultPlaybackRate');
  }catch(e){}

  var locked = false;
  if (dP && dP.get && dP.set) {
    try{
      // 利用者が自分で触った直後だけは向こうの書き込みを通す
      // (= YouTube 自身の速度メニューを殺さないため)。
      window.__MM_userRateUntil = 0;
      var mark = function(){
        try{ window.__MM_userRateUntil = (new Date()).getTime() + 900; }catch(e){}
      };
      document.addEventListener('pointerdown', mark, true);
      document.addEventListener('keydown', mark, true);

      var swallow = function(el, val){
        // 錠を掛けた要素で、 等速でない時だけ握りつぶす。
        if (!el || !el.__MM_RATE_LOCKED__) return false;
        var w = want();
        if (w === 1) return false;
        var now = 0;
        try{ now = (new Date()).getTime(); }catch(e){}
        if (now < (window.__MM_userRateUntil || 0)) {
          // 利用者の操作 → その値を新しい狙いにする (次からはこれを守る)。
          var nv = Number(val);
          if (nv && isFinite(nv) && nv > 0) {
            window.__MM_RATE__ = nv;
            window.__mmVideoRate = nv;
            save(nv);
          }
          return false;
        }
        return Math.abs((Number(val) || 1) - w) > 0.001;
      };

      Object.defineProperty(proto, 'playbackRate', {
        configurable: true,
        enumerable: dP.enumerable,
        get: function(){ return dP.get.call(this); },
        set: function(val){
          try{ if (swallow(this, val)) return; }catch(e){}
          dP.set.call(this, val);
        }
      });
      if (dD && dD.get && dD.set) {
        Object.defineProperty(proto, 'defaultPlaybackRate', {
          configurable: true,
          enumerable: dD.enumerable,
          get: function(){ return dD.get.call(this); },
          set: function(val){
            try{ if (swallow(this, val)) return; }catch(e){}
            dD.set.call(this, val);
          }
        });
      }
      locked = true;
    }catch(e){ locked = false; }
  }
  window.__MM_RATE_LOCKED_OK__ = locked;

  // 錠が掛からなかった時だけ使う広告の門 (= 押し合いで音が切れるのを防ぐ。
  // 錠が効いていれば押し合い自体が起きないので、 門は要らない)。
  function adBlocked(){
    if (locked) return false;
    try{
      if (window.__MM_isAd && window.__MM_isAd()) return true;
      if (document.querySelector(
          '#movie_player.ad-showing, .html5-video-player.ad-showing, ' +
          '#movie_player.ad-interrupting, .html5-video-player.ad-interrupting')) {
        return true;
      }
    }catch(e){}
    return false;
  }

  function applyOne(v){
    if (!v) return;
    try{
      var r = want();
      if (r !== 1 && hostOk()) v.__MM_RATE_LOCKED__ = true;
      if (adBlocked()) return;
      // 値が合っていれば書かない (= ratechange を飛ばさない)。
      if (Math.abs((Number(v.playbackRate) || 1) - r) > 0.001) v.playbackRate = r;
      if ('defaultPlaybackRate' in v &&
          Math.abs((Number(v.defaultPlaybackRate) || 1) - r) > 0.001) {
        v.defaultPlaybackRate = r;
      }
    }catch(e){}
  }

  function applyAll(){
    try{
      var vs = document.querySelectorAll('video');
      for (var i = 0; i < vs.length; i++) applyOne(vs[i]);
    }catch(e){}
  }

  window.__MM_setRate = function(r){
    try{
      var n = Number(r);
      if (!n || !isFinite(n) || n <= 0) n = 1;
      window.__MM_RATE__ = n;
      window.__mmVideoRate = n;
      save(n);
      applyAll();
    }catch(e){}
  };

  window.__MM_bootRate = function(fallback){
    try{
      var s = null;
      try{ s = window.sessionStorage.getItem(KEY); }catch(e){}
      var n = Number(s);
      if (!(n && isFinite(n) && n > 0)) n = Number(fallback);
      if (n && isFinite(n) && n > 0) window.__MM_setRate(n);
    }catch(e){}
  };

  // ── 掛け直しの口 ──
  //   差し替えの境目 (広告 ↔ 本編) はこの 4 つのどれかで必ず来る。
  //   値が合っていれば書かないので、 ここでの ratechange は「実際に
  //   掛け直した時」 の 1〜2 発だけ。
  var boundary = function(e){
    try{
      var t = e && e.target;
      if (t && t.tagName === 'VIDEO') applyOne(t);
    }catch(e2){}
  };
  ['loadedmetadata', 'loadeddata', 'canplay', 'playing'].forEach(function(n){
    try{ document.addEventListener(n, boundary, true); }catch(e){}
  });

  // ── 最後の砦 ──
  //   錠が外された / 掛け直しの口が一度も飛ばなかった時のための緩い見回り。
  //   2.5 秒に 1 度、 値が食い違っている時だけ書く。
  try{
    if (window.__MM_RATE_SWEEP__) clearInterval(window.__MM_RATE_SWEEP__);
    window.__MM_RATE_SWEEP__ = setInterval(function(){
      try{ if (want() !== 1) applyAll(); }catch(e){}
    }, 2500);
  }catch(e){}
}catch(e){}
})();
''';
