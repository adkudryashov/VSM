/*
 * Кнопка «XKeen» на странице подписки 3x-ui.
 *
 * ЗАЧЕМ. Страница подписки знает приложения для Android и iOS, а роутера с
 * XKeen (mihomo) не знает. Ссылку для mihomo панель уже умеет выдавать
 * (subClashUrl) — в ней все подключения клиента и AmneziaWG в формате mihomo
 * с version: 3. Не хватает только готового блока proxy-providers, который
 * вставляется в конфиг роутера. Его и показывает кнопка.
 *
 * КАК ПОПАДАЕТ НА СТРАНИЦУ. nginx вставляет <script> перед </body> ответа
 * страницы подписки (sub_filter, см. tools/xui-mihomo.py). Сама страница —
 * собранное приложение React, вкладки Android/iOS зашиты в него жёстко, и
 * настройки добавить свою нет (проверено по коду 3x-ui 3.8.5,
 * frontend/src/pages/sub/SubAppsTab.tsx).
 *
 * ЧТО БУДЕТ ПРИ ОБНОВЛЕНИИ ПАНЕЛИ. Если вёрстка сменится и переключателя
 * платформ не найдётся, кнопка просто не появится. Страница при этом
 * работает как обычно: скрипт ничего в ней не меняет, только добавляет своё.
 */
(function () {
  'use strict';

  var data = window.__SUB_PAGE_DATA__ || {};
  var url = data.subClashUrl || '';
  if (!url) return; // подписка mihomo выключена — показывать нечего

  // Сервис из названия подписки. Панель отдаёт название уже с подставленным
  // клиентом: «🇸🇪 My1Cent adkrw» (правило VSM «флаг сервис клиент»). Убираем
  // флаг и слова, совпадающие с именами клиентов подписки, — остаётся сервис.
  // Работает и на старых названиях, где клиент стоял в середине.
  function serviceName() {
    var t = String(data.subTitle || '')
      .replace(/^\s*(?:(?:\uD83C[\uDDE6-\uDDFF]){2}|\uD83C\uDF10)\s*/, '');
    var clients = (data.emails || []).concat([data.sId]).filter(Boolean);
    return t.split(/\s+/).filter(function (w) {
      return w && clients.indexOf(w) < 0 && !/^\{\{.*\}\}$/.test(w);
    }).join(' ');
  }

  // Имя провайдера: латиница и цифры сервиса. mihomo принимает и юникод, но
  // имя попадает в путь файла на роутере — проще без эмодзи.
  function providerName() {
    var words = serviceName().match(/[A-Za-z0-9][A-Za-z0-9._-]*/g) || [];
    var name = words.join('-').replace(/[.]/g, '-');
    return name || 'VSM';
  }

  function providerYaml() {
    var name = providerName();
    var service = serviceName();
    var file = name.toLowerCase().replace(/[^a-z0-9_-]/g, '');
    var lines = [
      'proxy-providers:',
      '  ' + name + ':',
      '    type: http',
      '    url: "' + url + '"',
      '    path: ./proxy-providers/' + (file || 'vsm') + '.yaml',
      '    interval: 3600',
      '    health-check:',
      '      enable: true',
      '      url: http://www.msftncsi.com/ncsi.txt',
      '      interval: 60'
    ];
    // Входящие называются «флаг тип»: у двух серверов одной страны на роутере
    // было бы два «🇸🇪 awg». Приставка сервиса их различает (mihomo 1.19,
    // adapter/provider/override.go).
    if (service) {
      lines.push('    override:');
      lines.push('      additional-prefix: "' + service.replace(/["\\]/g, '') + ' "');
    }
    return lines.concat([
      '',
      '# Подключить провайдер в группе прокси:',
      '#   proxy-groups:',
      '#     - name: PROXY',
      '#       type: select',
      '#       use: [' + name + ']',
      ''
    ]).join('\n');
  }

  var CSS = [
    '.sub-apps{position:relative}',
    '.vsm-xk-btn{position:absolute;display:inline-flex;align-items:center;gap:6px;',
    ' padding:0 12px;border-radius:8px;cursor:pointer;font:inherit;font-size:14px;',
    ' border:1px solid var(--sub-tile-border,rgba(128,128,128,.3));',
    ' background:var(--sub-tile-bg,transparent);color:var(--ant-color-text,inherit)}',
    '.vsm-xk-btn:hover{background:var(--sub-row-bg-hover,rgba(128,128,128,.15))}',
    '.vsm-xk-back{position:fixed;inset:0;z-index:2000;background:rgba(0,0,0,.55);',
    ' display:flex;align-items:center;justify-content:center;padding:16px}',
    '.vsm-xk-card{width:100%;max-width:560px;max-height:90vh;overflow:auto;',
    ' border-radius:14px;padding:18px;box-sizing:border-box;',
    ' background:var(--sub-card-bg,var(--sub-tile-bg,#1f1f2b));',
    ' border:1px solid var(--sub-tile-border,rgba(128,128,128,.3));',
    ' color:var(--ant-color-text,#eee);box-shadow:0 12px 40px rgba(0,0,0,.4)}',
    '.vsm-xk-card h3{margin:0 0 8px;font-size:16px;color:inherit}',
    '.vsm-xk-card p{margin:0 0 10px;font-size:13px;opacity:.85;line-height:1.45}',
    '.vsm-xk-card pre{margin:0 0 12px;padding:12px;border-radius:8px;font-size:12px;',
    ' line-height:1.45;white-space:pre;overflow:auto;',
    ' background:rgba(0,0,0,.25);border:1px solid var(--sub-tile-border,rgba(128,128,128,.3))}',
    '.vsm-xk-row{display:flex;gap:8px;justify-content:flex-end;flex-wrap:wrap}',
    '.vsm-xk-row button{padding:5px 14px;border-radius:6px;cursor:pointer;font:inherit;',
    ' font-size:14px;border:1px solid var(--sub-tile-border,rgba(128,128,128,.3));',
    ' background:transparent;color:inherit}',
    '.vsm-xk-row .vsm-xk-main{background:var(--ant-color-primary,#8b5cf6);',
    ' border-color:transparent;color:#fff}'
  ].join('');

  // Значок роутера, рисуется цветом текста.
  var ICON = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" ' +
    'stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true">' +
    '<rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 16.5h.01M11 16.5h.01"/>' +
    '<path d="M17 13V9M14 6.5a4 4 0 0 1 6 0M12 4a7.5 7.5 0 0 1 10 0"/></svg>';

  function copy(text, done) {
    function fallback() {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand('copy'); done(true); } catch (e) { done(false); }
      document.body.removeChild(ta);
    }
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(function () { done(true); }, fallback);
    } else {
      fallback();
    }
  }

  function openDialog(host) {
    var yaml = providerYaml();
    var back = document.createElement('div');
    back.className = 'vsm-xk-back';
    back.innerHTML =
      '<div class="vsm-xk-card" role="dialog" aria-modal="true">' +
      '<h3>XKeen (mihomo) на роутере</h3>' +
      '<p>Вставьте блок в config.yaml mihomo на роутере. В подписке все ' +
      'подключения этого профиля, включая AmneziaWG; роутер обновляет её ' +
      'сам раз в час — после смены ключей на сервере ничего переносить не нужно.</p>' +
      '<pre></pre>' +
      '<div class="vsm-xk-row">' +
      '<button type="button" class="vsm-xk-close">Закрыть</button>' +
      '<button type="button" class="vsm-xk-main">Копировать</button>' +
      '</div></div>';
    back.querySelector('pre').textContent = yaml;

    function close() {
      document.removeEventListener('keydown', onKey);
      if (back.parentNode) back.parentNode.removeChild(back);
    }
    function onKey(e) { if (e.key === 'Escape') close(); }

    back.addEventListener('click', function (e) { if (e.target === back) close(); });
    back.querySelector('.vsm-xk-close').addEventListener('click', close);
    var main = back.querySelector('.vsm-xk-main');
    main.addEventListener('click', function () {
      copy(yaml, function (ok) {
        main.textContent = ok ? 'Скопировано' : 'Выделите и скопируйте вручную';
        setTimeout(function () { main.textContent = 'Копировать'; }, 2000);
      });
    });
    document.addEventListener('keydown', onKey);
    // Внутрь страницы, а не в body: так диалог берёт её цвета и тему.
    host.appendChild(back);
  }

  function place(apps, seg, btn) {
    btn.style.left = (seg.offsetLeft + seg.offsetWidth + 8) + 'px';
    btn.style.top = seg.offsetTop + 'px';
    btn.style.height = seg.offsetHeight + 'px';
  }

  function attach() {
    var apps = document.querySelector('.sub-apps');
    if (!apps || apps.querySelector('.vsm-xk-btn')) return;
    var seg = apps.querySelector('.ant-segmented');
    if (!seg) return;
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'vsm-xk-btn';
    btn.innerHTML = ICON + '<span>XKeen</span>';
    btn.addEventListener('click', function () {
      openDialog(document.querySelector('.subscription-page') || document.body);
    });
    // Не в поток разметки, а поверх: вставка между узлами React ломает ему
    // сверку при переключении платформы.
    apps.appendChild(btn);
    place(apps, seg, btn);
    window.addEventListener('resize', function () { place(apps, seg, btn); });
  }

  function start() {
    var style = document.createElement('style');
    style.textContent = CSS;
    document.head.appendChild(style);
    attach();
    // Вкладка «Приложения» рисуется при первом открытии — ждём её.
    new MutationObserver(attach).observe(document.body, { childList: true, subtree: true });
  }

  try {
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', start);
    } else {
      start();
    }
  } catch (e) { /* страница важнее кнопки */ }
})();
