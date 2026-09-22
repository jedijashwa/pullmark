/* Language switcher memory + detected-language suggestion banner
   (spec: site-localization). Included solely on pages that have
   translated variants, so its presence is also the "variants exist"
   gate — the pre-paint redirect in each page's <head> relies on that.

   Two mechanisms, deliberately kept apart:

   - The PREFERENCE (`pm-lang`) is written here, only by an explicit
     pick — a click in the footer switcher or on the banner's link. It
     is read only by the inline redirect in <head>, which sends the
     reader to that variant before first paint. Selecting a language is
     the only thing that sets it; selecting another is the only thing
     that changes it.

   - The BANNER follows navigator.languages and nothing else. On a page
     the reader was redirected to, that means it offers their browser's
     language as the way back — one click, which is also the way to
     change the preference. It never reads `pm-lang`: a preference that
     could also drive the banner would let one switcher click paper the
     whole site in a language the browser never asked for. */
(function () {
  "use strict";

  // Locale code → path prefix. English lives at the root.
  var LOCALES = {
    "zh-Hans": "zh", "ja": "ja", "fr": "fr", "de": "de",
    "nl": "nl", "es": "es", "pt-BR": "pt"
  };

  // Banner copy is written in the TARGET language — it addresses the
  // reader who'd rather be there.
  var STRINGS = {
    "en":      { msg: "This page is also available in English.", link: "View in English", close: "Dismiss" },
    "zh-Hans": { msg: "此页面提供中文版。", link: "查看中文版", close: "关闭" },
    "ja":      { msg: "このページは日本語でもご覧いただけます。", link: "日本語で表示", close: "閉じる" },
    "fr":      { msg: "Cette page est aussi disponible en français.", link: "Voir en français", close: "Fermer" },
    "de":      { msg: "Diese Seite ist auch auf Deutsch verfügbar.", link: "Auf Deutsch ansehen", close: "Schließen" },
    "nl":      { msg: "Deze pagina is ook beschikbaar in het Nederlands.", link: "In het Nederlands bekijken", close: "Sluiten" },
    "es":      { msg: "Esta página también está disponible en español.", link: "Ver en español", close: "Cerrar" },
    "pt-BR":   { msg: "Esta página também está disponível em português.", link: "Ver em português", close: "Fechar" }
  };

  var DISMISS_KEY = "pm-lang-suggest";
  var CHOICE_KEY = "pm-lang";

  function store(key, value) {
    try { localStorage.setItem(key, value); } catch (e) { /* private mode */ }
  }
  function read(key) {
    try { return localStorage.getItem(key); } catch (e) { return null; }
  }

  var pageLocale = document.documentElement.getAttribute("lang") || "en";

  // The page's path with any locale prefix stripped — the English
  // address of this content. Mirrors the <head> redirect's own copy;
  // check-site-i18n.py holds the two to the same behaviour.
  function basePath() {
    var path = location.pathname;
    for (var code in LOCALES) {
      var prefix = "/" + LOCALES[code] + "/";
      if (path === prefix.slice(0, -1)) { return "/"; }
      if (path.indexOf(prefix) === 0) { return path.slice(prefix.length - 1); }
    }
    return path;
  }

  function urlFor(code) {
    var base = basePath();
    return code === "en" ? base : "/" + LOCALES[code] + base;
  }

  // Best supported locale for this visitor's browser languages. The list
  // is in the reader's own order of preference, so the first supported
  // tag wins — and a reader whose top language is this page's gets the
  // page's own locale back, which suppresses the banner.
  function detect() {
    var langs = navigator.languages || [navigator.language || ""];
    for (var i = 0; i < langs.length; i++) {
      var tag = String(langs[i]).toLowerCase();
      if (tag.indexOf("en") === 0) { return "en"; }
      if (tag.indexOf("ja") === 0) { return "ja"; }
      if (tag.indexOf("fr") === 0) { return "fr"; }
      if (tag.indexOf("de") === 0) { return "de"; }
      if (tag.indexOf("nl") === 0) { return "nl"; }
      if (tag.indexOf("es") === 0) { return "es"; }
      if (tag.indexOf("pt") === 0) { return "pt-BR"; }
      // Simplified only: never offer zh-Hans to zh-TW/zh-Hant readers.
      if (tag === "zh" || tag.indexOf("zh-cn") === 0 || tag.indexOf("zh-sg") === 0
          || tag.indexOf("zh-hans") === 0) { return "zh-Hans"; }
    }
    return null;
  }

  // Picking a language in the switcher is the deliberate act the
  // preference is built on. The write is synchronous, so it lands
  // before the click's own navigation.
  function rememberPicks() {
    document.querySelectorAll(".lang-switch a[hreflang]").forEach(function (a) {
      a.addEventListener("click", function () {
        store(CHOICE_KEY, a.getAttribute("hreflang"));
      });
    });
  }

  function showBanner(target) {
    var strings = STRINGS[target];
    if (!strings) { return; }
    var banner = document.createElement("div");
    banner.className = "lang-banner";
    banner.setAttribute("lang", target === "en" ? "en" : target);
    var msg = document.createElement("span");
    msg.textContent = strings.msg + " ";
    var link = document.createElement("a");
    link.href = urlFor(target);
    link.textContent = strings.link;
    // Taking the offer is a pick, same as the switcher — and it is how a
    // reader who was redirected here gets back out for good.
    link.addEventListener("click", function () { store(CHOICE_KEY, target); });
    msg.append(link);
    var close = document.createElement("button");
    close.className = "lang-banner-close";
    close.setAttribute("aria-label", strings.close);
    close.textContent = "×";
    // Dismissal answers the banner, not the preference: a reader sitting
    // on their chosen variant is saying "yes, I know" — silencing the
    // offer must not quietly send them back.
    close.addEventListener("click", function () {
      store(DISMISS_KEY, "1");
      banner.remove();
    });
    banner.append(msg, close);
    document.body.prepend(banner);
  }

  function init() {
    rememberPicks();
    if (read(DISMISS_KEY)) { return; }
    var target = detect();
    if (!target || target === pageLocale) { return; }
    showBanner(target);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
