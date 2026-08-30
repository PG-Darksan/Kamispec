// ページを端まで送るための JavaScript。
//
// なぜ切り出したか:
//   「一番下までスクロールして」 が効かない、 という報告が続いた。 原因は
//   ページ側の作りの違い (body の高さが 0 / 内側の枠がスクロールする /
//   下へ行くほど中身が増える) と、 なめらか送りが裏の窓で進まないこと。
//   直した中身を**アプリ内ブラウザと外のブラウザ (CDP) の両方**で使い、
//   さらに道具から実際に試せるように、 ここに置いてある。
library;

/// 一番下 (または一番上) まで送る JS。
///
/// 戻り値は "今の位置,全体の高さ" (例 "4820,9600")。 呼ぶ側はこれを見て、
/// 位置も高さも変わらなくなるまで数回押し込む (遅延読み込み対策)。
///
/// 送る相手の決め方:
///   1. `document.scrollingElement` (ふつうのページはこれで動く)
///   2. 1 で動かなければ、 中身が一番はみ出している枠 (内側スクロール)
String scrollEndJs(bool toTop) {
  final target = toTop ? '0' : 'el.scrollHeight';
  final winTarget = toTop ? '0' : 'el.scrollHeight';
  return '(function(){'
      // 中身がはみ出している一番大きい枠を探す。
      'function inner(){var best=null,bs=0;'
      ' var all=document.querySelectorAll("div,main,section,article,ul");'
      ' for(var i=0;i<all.length&&i<3000;i++){var e=all[i];var st;'
      '  try{st=getComputedStyle(e);}catch(x){continue;}'
      '  if(!st||(st.overflowY!=="auto"&&st.overflowY!=="scroll"))continue;'
      '  var d=e.scrollHeight-e.clientHeight;'
      '  if(d>bs&&d>40&&e.clientHeight>120){bs=d;best=e;}}'
      ' return best;}'
      // なめらか送りを止める (裏の窓ではアニメーションが進まないため)。
      'try{var st=document.getElementById("__hnsb");'
      ' if(!st){st=document.createElement("style");st.id="__hnsb";'
      '  document.documentElement.appendChild(st);}'
      ' st.textContent="html,body{scroll-behavior:auto !important;}";'
      '}catch(x){}'
      'function go(el,t){'
      ' try{el.scrollTo({top:t,behavior:"instant"});}catch(x){}'
      ' try{el.scrollTop=t;}catch(x){}'
      ' return Math.round(el.scrollTop||0);}'
      'var el=document.scrollingElement||document.documentElement'
      '||document.body;'
      'var before=Math.round(el.scrollTop||window.scrollY||0);'
      'go(el,$target);'
      'try{window.scrollTo(0,$winTarget);}catch(x){}'
      'var after=Math.round(el.scrollTop||window.scrollY||0);'
      'if(after===before){var b=inner();'
      ' if(b){go(b,${toTop ? '0' : 'b.scrollHeight'});el=b;'
      '  after=Math.round(b.scrollTop||0);}}'
      'return String(after)+","+String(Math.round(el.scrollHeight||0));'
      '})();';
}
