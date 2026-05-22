/* Kamispe 共通スクリプト
   - ナビゲーションのアクティブ状態
   - スクロール検知でナビにボーダー
   - 出現アニメーション (.reveal)
   - 料金トグル (月額 / 年額)
   - FAQ アコーディオン
   - 言語切替UI と 初回訪問時の自動言語検出
*/
(function () {
  'use strict';

  /* ── 言語自動検出 (root に居るときだけ動作) ──
     navigator.language を見て、 ブラウザの言語に対応するサブディレクトリへ
     リダイレクトする。 ただし以下の条件で動作:
     - localStorage に "lang_chosen" が無い (= 初回訪問のみ)
     - 現在の URL が root / または /index.html (= 日本語版)
     - 検出言語が ja 以外 (en/zh/ko/es)

     ユーザーが明示的に言語を選択 (lang-menu からクリック) したら
     localStorage に "lang_chosen" = "true" をセットして、 以降の自動切替は止める。 */
  const SUPPORTED_LANGS = ['ja', 'en', 'zh', 'ko', 'es'];
  const LANG_DIR_MAP = { ja: '', en: 'en/', zh: 'zh/', ko: 'ko/', es: 'es/' };

  function detectBrowserLang() {
    const raw = (navigator.language || navigator.userLanguage || 'ja').toLowerCase();
    // ja-JP -> ja, en-US -> en, zh-CN/zh-TW -> zh, ko-KR -> ko, es-ES/es-MX -> es
    const primary = raw.split('-')[0];
    if (SUPPORTED_LANGS.includes(primary)) return primary;
    return 'ja'; // フォールバックは日本語
  }

  function getCurrentLang() {
    // body の lang 属性 (=html の lang) または URL パスから判定
    const htmlLang = document.documentElement.lang || 'ja';
    return SUPPORTED_LANGS.includes(htmlLang) ? htmlLang : 'ja';
  }

  function shouldAutoRedirect() {
    if (localStorage.getItem('lang_chosen') === 'true') return false;
    // 既に日本語以外のサブディレクトリに居るなら自動リダイレクトしない
    const path = window.location.pathname;
    if (/\/(en|zh|ko|es)\//.test(path)) return false;
    return true;
  }

  // 自動リダイレクト実行 (root の HTML にだけ仕込む。 各HTMLは現在ページに対応する
  // 翻訳版 URL を head の link[rel=alternate] で持っているので、 それを参照する)
  if (shouldAutoRedirect()) {
    const browserLang = detectBrowserLang();
    if (browserLang !== 'ja') {
      const altLink = document.querySelector(`link[rel="alternate"][hreflang="${browserLang}"]`);
      if (altLink && altLink.href && altLink.href !== window.location.href) {
        // 1度だけリダイレクト
        localStorage.setItem('lang_chosen', 'auto');
        window.location.replace(altLink.href);
        return; // 以下のスクリプトは実行しない
      }
    }
  }


  /* ── 全ページ共通の宇宙背景 (home 以外に固定レイヤーを挿入) ──
     トップの hero 装飾と同じ惑星・星雲・星座・流れ星を、 各ページの最背面に
     position:fixed で敷く。 home (data-page="home") は hero 内に専用装飾が
     あるため挿入しない。 点描の星空は body::before/::after で全ページ共通。 */
  (function injectCosmicBg() {
    if (document.body.dataset.page === 'home') return;
    if (document.querySelector('.cosmic-bg')) return;
    var layer = document.createElement('div');
    layer.className = 'cosmic-bg';
    layer.setAttribute('aria-hidden', 'true');
    layer.innerHTML = `<!-- 土星 (リアル版 - 多層・大気・縞模様・カッシーニの空隙) -->
        <svg class="planet planet-saturn" viewBox="0 0 240 240" xmlns="http://www.w3.org/2000/svg">
          <defs>
            <radialGradient id="satSphere" cx="32%" cy="28%" r="85%">
              <stop offset="0%" stop-color="#FFF0C8"/>
              <stop offset="15%" stop-color="#F5D88E"/>
              <stop offset="35%" stop-color="#D9A857"/>
              <stop offset="60%" stop-color="#9C7234"/>
              <stop offset="85%" stop-color="#4A3018"/>
              <stop offset="100%" stop-color="#0F0A05"/>
            </radialGradient>
            <radialGradient id="satShadow" cx="80%" cy="65%" r="60%">
              <stop offset="40%" stop-color="rgba(0,0,0,0)"/>
              <stop offset="100%" stop-color="rgba(0,0,0,0.65)"/>
            </radialGradient>
            <radialGradient id="satAtmos" cx="50%" cy="50%" r="50%">
              <stop offset="78%" stop-color="rgba(255,232,176,0)"/>
              <stop offset="88%" stop-color="rgba(255,232,176,0.18)"/>
              <stop offset="100%" stop-color="rgba(255,232,176,0)"/>
            </radialGradient>
            <linearGradient id="ringFront" x1="0%" y1="50%" x2="100%" y2="50%">
              <stop offset="0%" stop-color="rgba(150,100,50,0)"/>
              <stop offset="8%" stop-color="rgba(180,130,70,0.6)"/>
              <stop offset="20%" stop-color="rgba(232,199,126,0.95)"/>
              <stop offset="35%" stop-color="rgba(255,235,180,1)"/>
              <stop offset="44%" stop-color="rgba(160,110,60,0.45)"/>
              <stop offset="48%" stop-color="rgba(80,55,30,0.3)"/>
              <stop offset="52%" stop-color="rgba(80,55,30,0.3)"/>
              <stop offset="56%" stop-color="rgba(160,110,60,0.45)"/>
              <stop offset="65%" stop-color="rgba(255,235,180,1)"/>
              <stop offset="80%" stop-color="rgba(232,199,126,0.95)"/>
              <stop offset="92%" stop-color="rgba(180,130,70,0.6)"/>
              <stop offset="100%" stop-color="rgba(150,100,50,0)"/>
            </linearGradient>
            <linearGradient id="ringBack" x1="0%" y1="50%" x2="100%" y2="50%">
              <stop offset="0%" stop-color="rgba(150,100,50,0)"/>
              <stop offset="15%" stop-color="rgba(180,130,70,0.35)"/>
              <stop offset="35%" stop-color="rgba(232,199,126,0.5)"/>
              <stop offset="50%" stop-color="rgba(255,235,180,0.55)"/>
              <stop offset="65%" stop-color="rgba(232,199,126,0.5)"/>
              <stop offset="85%" stop-color="rgba(180,130,70,0.35)"/>
              <stop offset="100%" stop-color="rgba(150,100,50,0)"/>
            </linearGradient>
            <clipPath id="satClip"><circle cx="120" cy="120" r="50"/></clipPath>
            <filter id="satGlow"><feGaussianBlur stdDeviation="6"/></filter>
          </defs>
          <!-- 大気のハロー -->
          <circle cx="120" cy="120" r="60" fill="url(#satAtmos)" filter="url(#satGlow)"/>
          <!-- 後ろ側の環 (惑星の上半分) -->
          <g transform="rotate(-22 120 120)">
            <path d="M 18 120 Q 120 100 222 120" stroke="url(#ringBack)" stroke-width="4" fill="none"/>
            <path d="M 26 120 Q 120 104 214 120" stroke="rgba(232,199,126,0.4)" stroke-width="1.5" fill="none"/>
          </g>
          <!-- 惑星本体 -->
          <circle cx="120" cy="120" r="50" fill="url(#satSphere)"/>
          <!-- 縞模様 (clip-pathで球面内に) -->
          <g clip-path="url(#satClip)" opacity="0.7">
            <path d="M 70 102 Q 120 96 170 104" stroke="rgba(255,235,180,0.45)" stroke-width="2.5" fill="none"/>
            <path d="M 70 112 Q 120 108 170 114" stroke="rgba(160,110,60,0.5)" stroke-width="2" fill="none"/>
            <path d="M 70 120 Q 120 116 170 122" stroke="rgba(255,235,180,0.35)" stroke-width="3" fill="none"/>
            <path d="M 70 130 Q 120 126 170 132" stroke="rgba(120,80,40,0.55)" stroke-width="2" fill="none"/>
            <path d="M 70 138 Q 120 134 170 140" stroke="rgba(255,235,180,0.3)" stroke-width="1.8" fill="none"/>
            <ellipse cx="100" cy="125" rx="8" ry="3" fill="rgba(120,80,40,0.4)"/>
          </g>
          <!-- ハイライト -->
          <ellipse cx="100" cy="100" rx="15" ry="9" fill="rgba(255,250,230,0.35)" filter="url(#satGlow)"/>
          <!-- 影 -->
          <circle cx="120" cy="120" r="50" fill="url(#satShadow)"/>
          <!-- 前面の環 (惑星の下半分) -->
          <g transform="rotate(-22 120 120)">
            <path d="M 18 120 Q 120 140 222 120" stroke="url(#ringFront)" stroke-width="8" fill="none"/>
            <path d="M 26 120 Q 120 137 214 120" stroke="rgba(255,250,230,0.4)" stroke-width="1.5" fill="none"/>
            <path d="M 36 120 Q 120 134 204 120" stroke="rgba(80,55,30,0.4)" stroke-width="0.8" fill="none"/>
          </g>
        </svg>
<!-- 火星 (右側) -->
<svg class="planet planet-mars" viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <radialGradient id="marsSphere" cx="35%" cy="30%" r="78%">
      <stop offset="0%" stop-color="#E89B6C"/><stop offset="40%" stop-color="#C8633A"/>
      <stop offset="80%" stop-color="#7E3A1E"/><stop offset="100%" stop-color="#2A1208"/>
    </radialGradient>
    <radialGradient id="marsShadow" cx="75%" cy="68%" r="62%">
      <stop offset="45%" stop-color="rgba(0,0,0,0)"/><stop offset="100%" stop-color="rgba(0,0,0,0.5)"/>
    </radialGradient>
  </defs>
  <circle cx="50" cy="50" r="40" fill="url(#marsSphere)"/>
  <ellipse cx="40" cy="42" rx="10" ry="5" fill="rgba(120,50,25,0.4)"/>
  <ellipse cx="60" cy="60" rx="8" ry="4" fill="rgba(120,50,25,0.35)"/>
  <circle cx="37" cy="34" r="6" fill="rgba(255,220,180,0.25)"/>
  <circle cx="50" cy="50" r="40" fill="url(#marsShadow)"/>
</svg>
<!-- 星雲 (ガス雲、左下) -->
        <svg class="nebula nebula-1" viewBox="0 0 400 400" xmlns="http://www.w3.org/2000/svg">
          <defs>
            <radialGradient id="nebulaPurple" cx="40%" cy="50%" r="50%">
              <stop offset="0%" stop-color="rgba(160,100,200,0.55)"/>
              <stop offset="40%" stop-color="rgba(120,70,180,0.3)"/>
              <stop offset="100%" stop-color="rgba(40,20,80,0)"/>
            </radialGradient>
            <radialGradient id="nebulaGold" cx="60%" cy="55%" r="40%">
              <stop offset="0%" stop-color="rgba(232,199,126,0.4)"/>
              <stop offset="60%" stop-color="rgba(184,150,104,0.15)"/>
              <stop offset="100%" stop-color="rgba(120,80,40,0)"/>
            </radialGradient>
            <filter id="nebulaBlur"><feGaussianBlur stdDeviation="10"/></filter>
          </defs>
          <ellipse cx="160" cy="200" rx="180" ry="140" fill="url(#nebulaPurple)" filter="url(#nebulaBlur)"/>
          <ellipse cx="240" cy="220" rx="150" ry="100" fill="url(#nebulaGold)" filter="url(#nebulaBlur)"/>
          <ellipse cx="200" cy="180" rx="100" ry="60" fill="rgba(180,130,200,0.2)" filter="url(#nebulaBlur)" transform="rotate(25 200 180)"/>
        </svg>
<!-- 星座 (オリオン風 右上) -->
        <svg class="constellation constellation-1" viewBox="0 0 200 120" xmlns="http://www.w3.org/2000/svg">
          <line x1="20" y1="40" x2="60" y2="20" stroke="rgba(232,199,126,0.4)" stroke-width="0.7"/>
          <line x1="60" y1="20" x2="110" y2="50" stroke="rgba(232,199,126,0.4)" stroke-width="0.7"/>
          <line x1="110" y1="50" x2="150" y2="35" stroke="rgba(232,199,126,0.4)" stroke-width="0.7"/>
          <line x1="110" y1="50" x2="140" y2="95" stroke="rgba(232,199,126,0.4)" stroke-width="0.7"/>
          <line x1="150" y1="35" x2="185" y2="60" stroke="rgba(232,199,126,0.4)" stroke-width="0.7"/>
          <circle cx="20" cy="40" r="2.5" fill="#FFE8B0"/>
          <circle cx="60" cy="20" r="3" fill="#FFFFFF"/>
          <circle cx="110" cy="50" r="3.2" fill="#FFE8B0"/>
          <circle cx="150" cy="35" r="2.7" fill="#FFFFFF"/>
          <circle cx="185" cy="60" r="2.2" fill="#FFE8B0"/>
          <circle cx="140" cy="95" r="2.5" fill="#FFFFFF"/>
        </svg>
<!-- 星座 (北斗七星風 中下) -->
        <svg class="constellation constellation-2" viewBox="0 0 160 100" xmlns="http://www.w3.org/2000/svg">
          <line x1="15" y1="30" x2="55" y2="55" stroke="rgba(232,199,126,0.35)" stroke-width="0.7"/>
          <line x1="55" y1="55" x2="90" y2="40" stroke="rgba(232,199,126,0.35)" stroke-width="0.7"/>
          <line x1="90" y1="40" x2="130" y2="70" stroke="rgba(232,199,126,0.35)" stroke-width="0.7"/>
          <line x1="55" y1="55" x2="80" y2="85" stroke="rgba(232,199,126,0.35)" stroke-width="0.7"/>
          <circle cx="15" cy="30" r="2.2" fill="#FFE8B0"/>
          <circle cx="55" cy="55" r="3" fill="#FFFFFF"/>
          <circle cx="90" cy="40" r="2.5" fill="#FFE8B0"/>
          <circle cx="130" cy="70" r="2.7" fill="#FFFFFF"/>
          <circle cx="80" cy="85" r="2.2" fill="#FFE8B0"/>
        </svg>
<!-- 流れ星 -->
<div class="shooting-star shooting-star-1"></div>
<div class="shooting-star shooting-star-2"></div>
<div class="shooting-star shooting-star-3"></div>`;
    document.body.insertBefore(layer, document.body.firstChild);
  })();

  /* ── 言語切替UIの開閉 ── */
  const langSwitcher = document.querySelector('.lang-switcher');
  if (langSwitcher) {
    const toggle = langSwitcher.querySelector('.lang-toggle');
    if (toggle) {
      toggle.addEventListener('click', (e) => {
        e.stopPropagation();
        langSwitcher.classList.toggle('open');
      });
      // 外側クリックで閉じる
      document.addEventListener('click', (e) => {
        if (!langSwitcher.contains(e.target)) {
          langSwitcher.classList.remove('open');
        }
      });
      // 言語選択時に localStorage に記録
      langSwitcher.querySelectorAll('.lang-menu a').forEach(a => {
        a.addEventListener('click', () => {
          localStorage.setItem('lang_chosen', 'true');
        });
      });
    }
  }

  /* ── ナビアクティブ判定 ──
     <body data-page="X"> の値で現在ページを判別し、 該当する nav-link に .active を付与。
     機能サブページ (ai/video/calendar/platform) では「機能」ドロップダウン親もアクティブに。
  */
  const currentPage = document.body.dataset.page || 'home';
  const featurePages = ['features', 'ai', 'video', 'calendar', 'platform'];
  document.querySelectorAll('.nav-link').forEach(link => {
    const lp = link.dataset.page;
    let isActive = (lp === currentPage);
    if (lp === 'features' && featurePages.includes(currentPage)) isActive = true;
    link.classList.toggle('active', isActive);
  });

  /* ── スクロール検知 ── */
  const nav = document.getElementById('nav');
  if (nav) {
    window.addEventListener('scroll', () => {
      nav.classList.toggle('scrolled', window.scrollY > 20);
    }, { passive: true });
  }

  /* ── 出現アニメーション ── */
  if ('IntersectionObserver' in window) {
    const io = new IntersectionObserver((entries) => {
      entries.forEach(e => {
        if (e.isIntersecting) {
          e.target.classList.add('in');
          io.unobserve(e.target);
        }
      });
    }, { threshold: 0.1, rootMargin: '0px 0px -40px 0px' });
    document.querySelectorAll('.reveal').forEach(el => io.observe(el));
  } else {
    document.querySelectorAll('.reveal').forEach(el => el.classList.add('in'));
  }

  /* ── 料金プラン: 月額/年額トグル ── */
  const billingButtons = document.querySelectorAll('.billing-option');
  const priceNums = document.querySelectorAll('.price-amount .num[data-monthly]');
  const annualNotes = document.querySelectorAll('.price-annual-note[data-annual-total]');
  const pricingGrid = document.querySelector('.pricing-grid');

  billingButtons.forEach(btn => {
    btn.addEventListener('click', () => {
      const billing = btn.dataset.billing;
      billingButtons.forEach(b => b.classList.toggle('active', b === btn));
      if (pricingGrid) pricingGrid.classList.toggle('billing-annual', billing === 'annual');
      priceNums.forEach(el => {
        el.textContent = billing === 'annual' ? el.dataset.annual : el.dataset.monthly;
      });
      annualNotes.forEach(el => {
        const total = el.dataset.annualTotal;
        if (billing === 'annual') {
          const numEl = el.parentElement && el.parentElement.querySelector('.num[data-monthly]');
          const monthly = numEl ? parseFloat(numEl.dataset.monthly) : 0;
          const monthlyTotal = monthly * 12;
          const saved = (monthlyTotal - parseFloat(total)).toFixed(2);
          el.textContent = '✓ 年額 $' + total + ' 一括 / 通常より $' + saved + ' お得';
        } else {
          el.innerHTML = '&nbsp;';
        }
      });
    });
  });

  /* ── FAQ アコーディオン ── */
  document.querySelectorAll('.faq-item').forEach(item => {
    const q = item.querySelector('.faq-q');
    if (!q) return;
    q.addEventListener('click', () => {
      item.classList.toggle('open');
    });
  });

  /* ── 共通フォーム: ヘルパ ── */
  function showError(input, errorEl, message) {
    input.classList.add('is-error');
    errorEl.textContent = message;
  }
  function clearError(input, errorEl) {
    input.classList.remove('is-error');
    errorEl.textContent = '';
  }

  /* ── お問い合わせフォーム ── */
  const contactForm = document.getElementById('contact-form');
  if (contactForm) {
    const contactPanel = document.getElementById('contact-panel');
    const thanksPanel = document.getElementById('thanks-panel');
    const cnameInput = document.getElementById('cname');
    const emailInput = document.getElementById('email');
    const categoryInput = document.getElementById('category');
    const messageInput = document.getElementById('message');
    const errCname = document.getElementById('err-cname');
    const errEmail = document.getElementById('err-email');
    const errCat = document.getElementById('err-cat');
    const errMsg = document.getElementById('err-msg');

    contactForm.addEventListener('submit', async (event) => {
      event.preventDefault();
      let hasError = false;

      const nameValue = cnameInput.value.trim();
      if (nameValue === '') {
        showError(cnameInput, errCname, 'お名前を入力してください。');
        hasError = true;
      } else { clearError(cnameInput, errCname); }

      const emailValue = emailInput.value.trim();
      const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
      if (emailValue === '') {
        showError(emailInput, errEmail, 'メールアドレスを入力してください。');
        hasError = true;
      } else if (!emailPattern.test(emailValue)) {
        showError(emailInput, errEmail, '正しいメールアドレスを入力してください。');
        hasError = true;
      } else { clearError(emailInput, errEmail); }

      if (categoryInput.value === '') {
        showError(categoryInput, errCat, 'お問い合わせの種類を選択してください。');
        hasError = true;
      } else { clearError(categoryInput, errCat); }

      const messageValue = messageInput.value.trim();
      if (messageValue === '') {
        showError(messageInput, errMsg, 'メッセージを入力してください。');
        hasError = true;
      } else if (messageValue.length < 10) {
        showError(messageInput, errMsg, '10 文字以上入力してください。');
        hasError = true;
      } else { clearError(messageInput, errMsg); }

      if (hasError) return;

      // Formspree に非同期送信
      // 失敗時はフォームのまま action 属性で通常 POST 送信にフォールバック
      const submitBtn = contactForm.querySelector('button[type="submit"]');
      const originalLabel = submitBtn ? submitBtn.textContent : '';
      if (submitBtn) {
        submitBtn.disabled = true;
        submitBtn.textContent = '送信中…';
      }

      try {
        const formData = new FormData(contactForm);
        const response = await fetch(contactForm.action, {
          method: 'POST',
          body: formData,
          headers: { 'Accept': 'application/json' }
        });

        if (response.ok) {
          contactPanel.hidden = true;
          thanksPanel.hidden = false;
          thanksPanel.scrollIntoView({ behavior: 'smooth' });
        } else {
          // Formspree からエラーが返ってきた場合
          const data = await response.json().catch(() => null);
          const errMessage = (data && data.errors && data.errors.length > 0)
            ? data.errors.map(e => e.message).join(', ')
            : '送信に失敗しました。 時間を空けて再度お試しください。';
          showError(messageInput, errMsg, errMessage);
          if (submitBtn) {
            submitBtn.disabled = false;
            submitBtn.textContent = originalLabel;
          }
        }
      } catch (err) {
        // ネットワークエラーなど
        showError(messageInput, errMsg, '通信エラーが発生しました。 ネットワークをご確認ください。');
        if (submitBtn) {
          submitBtn.disabled = false;
          submitBtn.textContent = originalLabel;
        }
      }
    });
  }

  /* ── ダウンロードフォーム ── */
  const dlForm = document.getElementById('dl-form');
  if (dlForm) {
    const formPanel = document.getElementById('dl-form-panel');
    const resultPanel = document.getElementById('dl-result-panel');
    const resetBtn = document.getElementById('dl-reset');
    const greeting = document.getElementById('result-greeting');
    const deptInput = document.getElementById('dl-dept');
    const dlNameInput = document.getElementById('dl-name');
    const telInput = document.getElementById('dl-tel');
    const errDept = document.getElementById('err-dept');
    const errDlName = document.getElementById('err-dl-name');
    const errTel = document.getElementById('err-tel');

    dlForm.addEventListener('submit', (event) => {
      event.preventDefault();
      let hasError = false;
      const deptValue = deptInput.value.trim();
      if (deptValue === '') { showError(deptInput, errDept, '部署名を入力してください。'); hasError = true; }
      else { clearError(deptInput, errDept); }
      const nameValue = dlNameInput.value.trim();
      if (nameValue === '') { showError(dlNameInput, errDlName, 'お名前を入力してください。'); hasError = true; }
      else { clearError(dlNameInput, errDlName); }
      const telValue = telInput.value.trim();
      if (telValue === '') { showError(telInput, errTel, '電話番号を入力してください。'); hasError = true; }
      else { clearError(telInput, errTel); }
      if (hasError) return;
      greeting.innerHTML = deptValue + ' の ' + nameValue + ' さん、有難う御座います！<br>以下のリンクからダウンロードしてください。';
      formPanel.hidden = true;
      resultPanel.hidden = false;
      resultPanel.scrollIntoView({ behavior: 'smooth' });
    });
    if (resetBtn) {
      resetBtn.addEventListener('click', () => {
        dlForm.reset();
        clearError(deptInput, errDept);
        clearError(dlNameInput, errDlName);
        clearError(telInput, errTel);
        resultPanel.hidden = true;
        formPanel.hidden = false;
        formPanel.scrollIntoView({ behavior: 'smooth' });
      });
    }
  }
})();
