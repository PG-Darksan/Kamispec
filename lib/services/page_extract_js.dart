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
    'if(window.__hnHooked) { window.__hnLogs=[]; return "ok"; }'
    'window.__hnHooked=true; window.__hnLogs=[];'
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
