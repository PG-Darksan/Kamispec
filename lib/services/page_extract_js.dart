// ページの中身を取り出す JavaScript と、 ログを控える仕掛け。
//
// = ユーザー要望「スクショ以外にも色んなデータを取得してこれるように」。
//
// ★ 切り出してある理由: 引用符の入れ子が壊れやすいので、 道具から
//   本物のブラウザに流して確かめられるようにするため
//   (tool/cdp_data_check.dart)。
library;

import 'dart:convert';

/// ページの中身を取り出す JS。
///
/// [mode] は 'text' / 'html' / 'table' / 'links'。
/// [selector] が空ならページ全体。
String extractJs(String mode, String selector) {
  final sel = jsonEncode(selector);
  switch (mode) {
    case 'html':
      return '(function(){try{var s=$sel;'
          'var e=s?document.querySelector(s):document.documentElement;'
          'return e?e.outerHTML:"";}catch(e){return "";}})();';
    case 'links':
      return '(function(){try{var s=$sel;'
          'var root=s?document.querySelector(s):document;'
          'if(!root) return "";'
          'var a=root.querySelectorAll("a[href]");var out=[];'
          'for(var i=0;i<a.length&&i<2000;i++){'
          ' var t=(a[i].innerText||"").trim().replace(/\\s+/g," ");'
          ' out.push(t+"\\t"+a[i].href);}'
          'return out.join("\\n");}catch(e){return "";}})();';
    case 'table':
      // CSV にする。 引用符は String.fromCharCode(34) で作って、
      //   Dart 側と JS 側の入れ子のエスケープを避ける。
      return '(function(){try{var s=$sel;'
          'var t=document.querySelector(s||"table");'
          'if(!t) return "";'
          'var Q=String.fromCharCode(34);'
          'function q(v){v=(v==null?"":String(v)).trim()'
          '.replace(/\\s+/g," ");'
          ' if(v.indexOf(",")>=0||v.indexOf(Q)>=0||v.indexOf("\\n")>=0){'
          '  return Q+v.split(Q).join(Q+Q)+Q;}'
          ' return v;}'
          'var rows=t.rows,out=[];'
          'for(var i=0;i<rows.length;i++){var cs=rows[i].cells,line=[];'
          ' for(var j=0;j<cs.length;j++)'
          '  line.push(q(cs[j].innerText||cs[j].textContent));'
          ' out.push(line.join(","));}'
          'return out.join("\\n");}catch(e){return "";}})();';
    default:
      return '(function(){try{var s=$sel;'
          'var e=s?document.querySelector(s):document.body;'
          'return e?(e.innerText||e.textContent||""):"";'
          '}catch(e){return "";}})();';
  }
}

/// 押す物 (リンク / ボタン) の飛び先を読み取る JS。
String hrefOfJs(String selector, String text) {
  final sel = jsonEncode(selector);
  final txt = jsonEncode(text);
  return '(function(){try{'
      'var sel=$sel, txt=$txt, el=null;'
      'if(sel) el=document.querySelector(sel);'
      'if(!el&&txt){var a=Array.prototype.slice.call('
      ' document.querySelectorAll("a,button,[download]"));'
      ' for(var i=0;i<a.length;i++){'
      '  var t=(a[i].innerText||a[i].textContent||"").trim();'
      '  if(t.indexOf(txt)>=0){el=a[i];break;}}}'
      'if(!el) return "";'
      'var h=el.getAttribute("href")||el.getAttribute("data-href")||"";'
      'if(!h) return "";'
      'return new URL(h, location.href).href;'
      '}catch(e){return "";}})();';
}

/// アプリの中のブラウザ用: console と例外を控えておく仕掛け。
///
/// 外のブラウザ (CDP) は本体の仕組みでログを拾えるが、 アプリ内の
/// WebView には覗く口が無いので、 ページ側に控えを作らせる。
const String consoleHookJs = '(function(){'
    'window.__hnLogs=window.__hnLogs||[];'
    'window.__hnReset=function(){window.__hnLogs=[];};'
    'if(window.__hnHooked) { return "ok"; }'
    'window.__hnHooked=true;'
    'function push(kind,args){try{'
    ' var p=[];for(var i=0;i<args.length;i++){var a=args[i];'
    '  p.push(typeof a==="string"?a:(function(){try{'
    '   return JSON.stringify(a);}catch(e){return String(a);}})());}'
    ' window.__hnLogs.push("["+kind+"] "+p.join(" "));'
    ' if(window.__hnLogs.length>400) window.__hnLogs.shift();'
    '}catch(e){}}'
    'var ms=["log","info","warn","error","debug"];'
    'for(var i=0;i<ms.length;i++){(function(m){var o=console[m];'
    ' console[m]=function(){push(m,arguments);'
    '  try{o.apply(console,arguments);}catch(e){}};})(ms[i]);}'
    'window.addEventListener("error",function(e){'
    ' push("error",[(e.message||"")+" ("+(e.filename||"")+":"'
    '  +(e.lineno||"")+")"]);});'
    'window.addEventListener("unhandledrejection",function(e){'
    ' push("error",["未処理の失敗: "+((e.reason&&e.reason.message)'
    '  ||e.reason||"")]);});'
    'return "ok";})();';


// ─── Google 検索の広告落とし ─────────────────────────────────────────
//
// = ユーザー要望「google 検索に Jev を導入して広告ブロックする機能」。
//
// ★ 2 段構え。
//   1 段目 (無料・即時): 名前で分かる広告の入れ物を CSS で隠す。 通信も
//      判断も要らないので、 Jev を切っていてもここだけは効く。
//   2 段目 (Jev): 1 段目で判別できなかった塊だけを取り出して
//      「これは広告か」 を聞き、 返ってきた物を隠す。
//
// ★ なぜ CSS で隠すだけか: webview_windows 0.2.2 には**要求を止める口が
//   無い** (contentBlockers は flutter_inappwebview 側だけの機能)。
//   Windows では通信は出るので、 見えなくなるだけ。 Android 側だけ
//   ネットワークごと止めると挙動が食い違うので、 表示を消す所は両方で
//   同じやり方に揃えてある。
//
// ★ Google は SPA。 検索し直しても document は変わらないので、
//   MutationObserver で入れ直す。 差し込みは何度走っても平気な形
//   (id で見て作り直さない) にしてある。
//
// ★ 難読化されたクラス名 (uEierd 等) は Google が頻繁に変える。 消えると
//   困るのは organic を隠してしまう事なので、 **安定した目印**
//   (#tads / [data-text-ad] / aria-label) を主にし、 クラス名は補助に
//   留めている。

/// 隠す目印。 ここだけ直せば全部の画面に効く。
const String kGoogleAdSelectors = '#tads,#tadsb,#bottomads,#tvcap,'
    '#taw > div[data-text-ad],'
    '[data-text-ad],[data-pla],'
    '.commercial-unit-desktop-top,.commercial-unit-desktop-rhs,'
    '.commercial-unit-mobile-top,.commercial-unit-mobile-bottom,'
    '.pla-unit,.pla-exp-container,.mnr-c.pla-unit,'
    'g-scrolling-carousel.pla-carousel,'
    '[aria-label="広告"],[aria-label="Ads"],[aria-label="Sponsored"],'
    '[aria-label="광고"],[aria-label="广告"]';

/// 広告の帯を隠す CSS。 style 要素の id は使い回す (何度入れても 1 つ)。
const String kGoogleAdBlockStyleId = 'mmAdBlockStyle';

/// 差し込む JS。 style を入れて、 SPA でも消えないよう見張る。
///
/// [labelHunt] を true にすると「スポンサー」「Sponsored」 の札が付いた
/// 塊も探して隠す (札は言語で変わるので、 文字で当てる方が持つ)。
String googleAdBlockInstallJs({bool labelHunt = true}) {
  final sel = jsonEncode(kGoogleAdSelectors);
  final styleId = jsonEncode(kGoogleAdBlockStyleId);
  final labels = jsonEncode(<String>[
    'スポンサー', // スポンサー
    'Sponsored',
    '広告', // 広告
    '赞助商', // 赞助商
    '광고', // 광고
    'Anuncio',
    'Annonce',
    'Werbung',
    'Anúncio',
    'Реклама', // Реклама
  ]);
  return '(function(){try{'
      'var SEL=$sel, SID=$styleId, LABELS=$labels, HUNT=${labelHunt ? 1 : 0};'
      // ── 1 段目: CSS で隠す ──
      'function style(){'
      ' var e=document.getElementById(SID);'
      ' if(e) return;'
      ' e=document.createElement("style");e.id=SID;'
      ' e.textContent=SEL+"{display:none !important}"'
      '  +"[data-mmad-hide=\\"1\\"]{display:none !important}";'
      ' (document.head||document.documentElement).appendChild(e);}'
      // ── 札 (スポンサー等) が付いた塊を探して目印を付ける ──
      // 結果 1 件の入れ物は Google では [data-hveid] か .g。 札から上へ
      // たどって、 最初に見付かった入れ物を隠す。
      'function container(el){'
      ' var n=el;'
      ' for(var i=0;i<8&&n;i++){'
      '  if(n.matches&&(n.matches("[data-hveid]")||n.matches(".g")'
      '   ||n.matches("[data-sokoban-container]"))) return n;'
      '  n=n.parentElement;}'
      ' return null;}'
      'function hunt(){'
      ' if(!HUNT) return;'
      ' var root=document.querySelector("#search,#rso,#main")||document.body;'
      ' if(!root) return;'
      ' var spans=root.querySelectorAll("span,div[role=heading]");'
      ' for(var i=0;i<spans.length&&i<4000;i++){'
      '  var el=spans[i];'
      '  if(el.children.length>0) continue;'
      '  var t=(el.innerText||el.textContent||"").trim();'
      '  if(!t||t.length>14) continue;'
      '  var hit=false;'
      '  for(var j=0;j<LABELS.length;j++){ if(t===LABELS[j]){hit=true;break;} }'
      '  if(!hit) continue;'
      '  var c=container(el);'
      '  if(c) c.setAttribute("data-mmad-hide","1");}}'
      'function apply(){style();hunt();}'
      'apply();'
      // ── SPA 対策: 検索し直しても document は変わらないので見張る ──
      'if(!window.__mmAdObs){'
      ' var tid=null;'
      ' window.__mmAdObs=new MutationObserver(function(){'
      '  if(tid) return;'
      '  tid=setTimeout(function(){tid=null;try{apply();}catch(e){}},150);});'
      ' try{window.__mmAdObs.observe(document.documentElement,'
      '  {childList:true,subtree:true});}catch(e){}}'
      'return "ok";}catch(e){return "err:"+e;}})();';
}

/// 隠すのをやめる (設定を切った時)。 次の読み込みからではなく即座に戻す。
const String googleAdBlockRemoveJs = '(function(){try{'
    'if(window.__mmAdObs){window.__mmAdObs.disconnect();window.__mmAdObs=null;}'
    'var e=document.getElementById("mmAdBlockStyle");'
    'if(e&&e.parentNode) e.parentNode.removeChild(e);'
    'var m=document.querySelectorAll("[data-mmad-hide]");'
    'for(var i=0;i<m.length;i++) m[i].removeAttribute("data-mmad-hide");'
    'var k=document.querySelectorAll("[data-mmad]");'
    'for(var i=0;i<k.length;i++) k[i].removeAttribute("data-mmad");'
    'return "ok";}catch(e){return "err:"+e;}})();';

/// 判別が付かなかった塊を取り出す JS。 戻りは JSON 文字列
/// `[{"id":"a3","text":"…"}]`。
///
/// ★ 送るのは**塊ごとの短い抜粋だけ**。 ページ全体は送らない。
/// ★ 既に隠した物・既に見た物 (data-mmad) は出さないので、 同じ塊で
///   何度も課金しない。
String googleAdCandidatesJs({int maxBlocks = 12, int chars = 200}) {
  return '(function(){try{'
      'var MAX=$maxBlocks, CH=$chars;'
      'var root=document.querySelector("#search,#rso,#main")||document.body;'
      'if(!root) return "[]";'
      'var seen=0,out=[];'
      'var blocks=root.querySelectorAll("[data-hveid],.g");'
      'for(var i=0;i<blocks.length&&out.length<MAX;i++){'
      ' var b=blocks[i];'
      ' if(b.getAttribute("data-mmad")) continue;'
      ' if(b.getAttribute("data-mmad-hide")==="1") continue;'
      // 入れ子になった内側の塊は見ない (親だけを 1 件として扱う)。
      ' if(b.parentElement&&b.parentElement.closest'
      '  &&b.parentElement.closest("[data-hveid],.g")) continue;'
      ' var t=(b.innerText||b.textContent||"").trim()'
      '  .replace(/\\s+/g," ");'
      ' if(t.length<12) continue;'
      ' seen++;'
      ' var id="a"+seen;'
      ' b.setAttribute("data-mmad",id);'
      ' out.push({id:id,text:t.slice(0,CH)});}'
      'return JSON.stringify(out);}catch(e){return "[]";}})();';
}

/// Jev が「広告」 と言った塊を隠す JS。
String googleAdApplyJs(List<String> adIds) {
  final ids = jsonEncode(adIds);
  return '(function(){try{'
      'var IDS=$ids;'
      'for(var i=0;i<IDS.length;i++){'
      ' var e=document.querySelector("[data-mmad=\\""+IDS[i]+"\\"]");'
      ' if(e) e.setAttribute("data-mmad-hide","1");}'
      'return "ok";}catch(e){return "err:"+e;}})();';
}
