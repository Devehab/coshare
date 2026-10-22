// Document pages (privacy policy, iPhone guide): share the language choice with the landing page
// (both language blocks are in the HTML; each page names its titles on <html data-title-ar/-en>).
(function () {
  "use strict";
  var root = document.documentElement;
  var META = {
    ar: { title: root.getAttribute("data-title-ar") || document.title, toggle: "English", copied: "تم النسخ ✓", copy: "نسخ" },
    en: { title: root.getAttribute("data-title-en") || document.title, toggle: "العربية", copied: "Copied ✓", copy: "Copy" }
  };
  function storedLang() {
    try { return localStorage.getItem("coshare.lang"); } catch (e) { return null; }
  }
  function storeLang(value) {
    try { localStorage.setItem("coshare.lang", value); } catch (e) { /* private mode */ }
  }
  var lang = storedLang() || ((navigator.language || "ar").toLowerCase().indexOf("ar") === 0 ? "ar" : "en");
  var labelled = document.querySelectorAll("[data-ar][data-en]");

  function applyLang() {
    document.documentElement.lang = lang;
    document.documentElement.dir = lang === "ar" ? "rtl" : "ltr";
    labelled.forEach(function (el) { el.textContent = el.getAttribute("data-" + lang); });
    document.title = META[lang].title;
    document.getElementById("langToggle").textContent = META[lang].toggle;
  }

  document.getElementById("langToggle").addEventListener("click", function () {
    lang = lang === "ar" ? "en" : "ar";
    storeLang(lang);
    applyLang();
    window.scrollTo(0, 0);
  });

  var header = document.querySelector(".site-header");
  function onScroll() { header.classList.toggle("scrolled", window.scrollY > 8); }
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  // Phones show each table row as a card; label every value with its column's heading.
  document.querySelectorAll(".data-table").forEach(function (table) {
    var heads = table.querySelectorAll("thead th");
    table.querySelectorAll("tbody tr").forEach(function (row) {
      Array.prototype.forEach.call(row.children, function (cell, i) {
        if (heads[i]) cell.setAttribute("data-label", heads[i].textContent.trim());
      });
    });
  });

  // Copy buttons next to commands.
  document.querySelectorAll("[data-copy]").forEach(function (button) {
    button.addEventListener("click", function () {
      var code = document.getElementById(button.getAttribute("data-copy"));
      var done = function () {
        button.textContent = META[lang].copied;
        setTimeout(function () { button.textContent = META[lang].copy; }, 1800);
      };
      var fallback = function () {
        var range = document.createRange();
        range.selectNodeContents(code);
        var selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        try { document.execCommand("copy"); done(); } catch (e) { /* the command stays selected */ }
      };
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(code.textContent).then(done, fallback);
      else fallback();
    });
  });

  document.getElementById("year").textContent = new Date().getFullYear();
  applyLang();
})();
