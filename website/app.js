// CoShare landing page: language switch, video, OS detection, scroll effects.
(function () {
  "use strict";

  // Arabic lives in the HTML; this is the English for every [data-i18n] element.
  var EN = {
    "nav.how": "How it works",
    "nav.security": "Security",
    "nav.features": "Features",
    "nav.download": "Download",
    "nav.faq": "FAQ",
    "nav.cta": "Get it free",
    "nav.skip": "Skip to content",
    "nav.privacy": "Privacy policy",
    "sec.policy": "Read the privacy policy: what data exists, where it’s kept and how it’s encrypted",

    "hero.eyebrow": "One clipboard for all your devices",
    "hero.title": "Copy here.<br><span class=\"mark\">Paste there.</span>",
    "hero.lead": "CoShare turns your iPhone, Android, Mac, Windows and Linux clipboards into one. Copy text or an image on any device and it’s instantly ready to paste on the others — even when they’re on different accounts.",
    "hero.cta": "Download free",
    "hero.watch": "Watch in 60 seconds",
    "hero.b1": "No cloud, no internet",
    "hero.b2": "End-to-end encrypted",
    "hero.b3": "Any account, any OS",

    "platforms.label": "Works on all your devices",

    "video.kicker": "One minute",
    "video.title": "CoShare in 60 seconds",
    "video.sub": "See how your different devices become one clipboard.",
    "video.caption": "Tap to play · 1 minute",

    "problem.kicker": "The problem",
    "problem.title": "Shared clipboards are great…<br>when they work.",
    "problem.sub": "You message the code to yourself. You screenshot text just to move it. You retype six digits by hand. We know the feeling.",
    "problem.c1.t": "One account only",
    "problem.c1.p": "Apple’s Universal Clipboard only works between devices on the same Apple ID. Work laptop on another account? You’re out.",
    "problem.c2.t": "One ecosystem only",
    "problem.c2.p": "Android phone with a Mac? iPhone with Windows? There’s no shared clipboard between them at all.",
    "problem.c3.t": "Stalls for no reason",
    "problem.c3.p": "Bluetooth, Wi-Fi and Handoff all have to agree at the same moment. Sometimes they don’t.",
    "problem.solution": "CoShare doesn’t care about your account or your OS. <span class=\"mark\">It only needs your devices nearby.</span>",

    "how.kicker": "How it works",
    "how.title": "Three steps… <span class=\"mark\">once</span>",
    "how.sub": "After that you forget CoShare is there — you just notice copy and paste works everywhere.",
    "how.s1.t": "Install CoShare",
    "how.s1.p": "On every device you own: phone, tablet, laptop or desktop. It’s tiny and runs quietly in the background.",
    "how.s2.t": "Create your group",
    "how.s2.p": "On the first device, create a group with a name and a password. Join it from your other devices with the password or by scanning a QR code. They stay in it, even after a restart.",
    "how.s3.t": "Copy… and paste",
    "how.s3.p": "That’s it. Any text or image you copy is ready on all your devices in under a second.",

    "net.kicker": "Under the hood",
    "net.title": "Runs on your network,<br><span class=\"mark\">not the internet.</span>",
    "net.sub": "No servers, no cloud, no account. Your devices talk to each other directly — in a language only they understand.",
    "net.f1.t": "Automatic discovery",
    "net.f1.p": "Your devices find each other over Bonjour (mDNS) on the same Wi-Fi. No setup, no IP addresses.",
    "net.f2.t": "Device to device, directly",
    "net.f2.p": "Every copy goes straight to your devices over a local TCP connection. Nothing in between.",
    "net.f3.t": "ChaCha20-Poly1305 encryption",
    "net.f3.p": "Every message is encrypted and authenticated with a key only your devices have. Anyone watching the network sees noise.",
    "net.f4.t": "Works offline",
    "net.f4.p": "Internet down? CoShare doesn’t even notice. Devices on the same local network is all it needs.",

    "sec.kicker": "Security",
    "sec.title": "Your neighbour on the same Wi-Fi?<br><span class=\"mark\">Sees nothing.</span>",
    "sec.sub": "Being on the same network doesn’t make a device yours. CoShare separates the two with cryptography, not trust.",
    "sec.p1.t": "Your group, your password",
    "sec.p1.p": "Create a private group with a name and a password. Everything sent inside it is encrypted with a key derived from that password — without it, nobody can read your clips or send you anything.",
    "sec.p2.t": "No password, no entry",
    "sec.p2.p": "Other devices on the network only see your group’s name. Joining takes the right password — nothing less.",
    "sec.p3.t": "The password never leaves your device",
    "sec.p3.p": "It is never sent over the network. Each device checks it locally and derives the key with PBKDF2, so it can’t be sniffed off the Wi-Fi.",
    "sec.p4.t": "Instant QR invites",
    "sec.p4.p": "Scan the invite with your phone camera to join the group instantly. It only appears when you ask for it.",
    "sec.p5.t": "Passwords never travel",
    "sec.p5.p": "Anything copied from password managers like 1Password is ignored automatically and never leaves your device.",
    "sec.p6.t": "History that erases itself",
    "sec.p6.p": "Only on your devices, for one day by default or the period you choose (up to a week), then deleted automatically, images included.",
    "sec.demo.new": "New iPhone",
    "sec.demo.group": "“Ehab’s devices”",
    "sec.demo.join": "Join",
    "sec.demo.groupTitle": "Group",
    "sec.demo.joined": "✓ New iPhone",
    "sec.demo.caption": "Pick the group, type the password, done. Just once.",
    "sec.demo.stranger": "A stranger on the same Wi-Fi only sees the group’s name — and receives nothing you copy without the password.",

    "feat.kicker": "Features",
    "feat.title": "Everything you’d expect… <span class=\"mark\">and more</span>",
    "feat.f1.t": "Verification codes, automatically",
    "feat.f1.p": "Got an OTP on your phone? It lands on your laptop’s clipboard the moment the message arrives. Just paste.",
    "feat.f2.t": "Full-quality images",
    "feat.f2.p": "Screenshots and photos arrive exactly as they left, byte for byte. No compression, no artifacts.",
    "feat.f3.t": "History that erases itself",
    "feat.f3.p": "Go back to anything you copied and copy it again with one click. It’s deleted after a day, or the period you choose up to a week.",
    "feat.f4.t": "Runs in the background",
    "feat.f4.p": "No need to open the app. It works silently and starts on its own with your device.",
    "feat.f5.t": "Automatic quiet hours",
    "feat.f5.p": "Pick your working days and hours, and CoShare disappears from the network on your work computer during them. Bring it back anytime with “Resume today”.",
    "feat.f6.t": "As many devices as you like",
    "feat.f6.p": "Five laptops and three phones? One clipboard, and they all receive at the same moment.",
    "feat.f7.t": "Any account",
    "feat.f7.p": "Different Apple ID? Different Google account? Doesn’t matter. CoShare never asks for one.",
    "feat.f8.t": "Free, no sign-up",
    "feat.f8.p": "No account, no email, no subscription, no ads.",

    "cmp.kicker": "Comparison",
    "cmp.title": "Why CoShare?",
    "cmp.h2": "Apple Universal Clipboard",
    "cmp.h3": "Cloud clipboard apps",
    "cmp.r1": "Works across different accounts",
    "cmp.r2": "iPhone + Android + Mac + Windows + Linux",
    "cmp.r3": "Your data never touches a server",
    "cmp.r4": "No account or sign-in",
    "cmp.r5": "History of what you copied today",
    "cmp.r6": "Verification codes arrive automatically",

    "dl.kicker": "Download",
    "dl.title": "Get it on <span class=\"mark\">all your devices</span>",
    "dl.sub": "Install it on at least two devices to see the magic. Completely free.",
    "dl.rec": "Your device",
    "dl.btn": "Download",
    "dl.ios.req": "iOS & iPadOS 15 or later",
    "dl.mac.req": "macOS 12 or later · Apple Silicon & Intel",
    "dl.android.req": "Android 8 or later · phones & tablets",
    "dl.win.req": "Windows 10 & 11 · Intel, AMD & ARM",
    "dl.win.arm": "ARM version (Snapdragon)",
    "dl.linux.req": "Ubuntu, Debian, Mint, Fedora & every distro",
    "dl.linux.btn": "One command or a package",
    "dl.linux.alt": ".deb · .rpm · AppImage",
    "lx.title": "Install CoShare on Linux",
    "lx.sub": "Pick whichever suits you. The one command does everything for you.",
    "lx.rec": "Easiest",
    "lx.cmd.title": "One terminal command",
    "lx.copy": "Copy",
    "lx.s1": "Detects your distribution and processor (Intel/AMD or ARM)",
    "lx.s2": "Installs the right package with all its dependencies: .deb, .rpm, or into your home folder on other distributions",
    "lx.s3": "Checks that encryption, networking and the clipboard work, then opens CoShare and starts it at login",
    "lx.s4": "Run it again any time to update",
    "lx.uninstall": "To uninstall:",
    "lx.pkg.title": "Or download a package",
    "lx.any": "Any distribution (Arch, openSUSE…)",
    "lx.arm": "ARM devices:",
    "dl.note": "Version 1.0 · Free · No account · No ads",

    "faq.kicker": "FAQ",
    "faq.title": "Got a question?",
    "faq.q1": "Someone else on my Wi-Fi installed CoShare. Can they see what I copy?",
    "faq.a1": "No. What you copy only goes to the devices in your group, encrypted with a key derived from its password. Others only see the group’s name, and no device joins unless it knows the password or scans the invite from your own screen.",
    "faq.q2": "My devices use different Apple or Google accounts. Does it work?",
    "faq.a2": "Yes — that’s exactly the point. CoShare never uses your account; it connects your devices directly over your local network.",
    "faq.qos": "Which systems does it run on? Do I need a new device?",
    "faq.aos": "No. It runs on systems from the last five years and newer: iOS and iPadOS 15 or later, macOS 12 Monterey or later (Intel and Apple Silicon), Windows 10 and 11 (Intel, AMD and ARM), Android 8 or later, and Linux: Ubuntu 20.04, Debian 11, Fedora and RHEL 9 onwards, plus any other distribution through the AppImage.",
    "faq.q3": "Does it need the internet?",
    "faq.a3": "No. Your devices just need to be on the same Wi-Fi or local network. Nothing goes over the internet, and there is no server.",
    "faq.q4": "Does it work when my laptop is on my phone’s hotspot?",
    "faq.a4": "Yes. When your laptop joins your phone’s hotspot, CoShare connects straight to the phone at its address on that network, even if automatic discovery doesn’t work there — perfect for cafés and airports.",
    "faq.q5": "What about public Wi-Fi in cafés and hotels?",
    "faq.a5": "Your clips are always encrypted, so nobody can read them. Some public networks stop devices from seeing each other (client isolation); if that happens, use your phone’s hotspot.",
    "faq.q6": "How do verification codes arrive automatically?",
    "faq.a6": "On iPhone, create a Shortcuts automation that runs when a message containing “code” arrives, and add the “Send text to devices” action with “Code only” on. CoShare extracts the number and puts it on all your clipboards.",
    "faq.q7": "Where are my clips stored, and for how long?",
    "faq.a7": "Only on your devices. By default clips and their images are deleted after one day; in Settings you choose 1 hour, 12 hours, 1 day, 3 days or a week at most. There’s no copy on any server — because there is no server.",
    "faq.q8": "Can a device be in more than one group?",
    "faq.a8": "Yes — say one group for your personal devices and one for work; what you copy reaches every group the device is in. To remove a device, leave the group on it, or create a new group with a new password and move your devices over.",
    "faq.q10": "Can I switch it off during working hours on a company computer?",
    "faq.a10": "Yes. In Settings, turn on “Quiet hours” and choose the days and times. During them CoShare doesn’t read the clipboard, send, receive or even appear on the network, and your other devices know its schedule so they don’t try to reach it. Finished early? Tap “Resume today”.",
    "faq.q9": "How many devices can I pair?",
    "faq.a9": "There’s no practical limit. Laptops, phones and tablets together, all receiving at the same moment.",

    "final.title": "Stop sending things <span class=\"mark\">to yourself.</span>",
    "final.sub": "Install CoShare on your devices and make them one clipboard today.",
    "final.cta": "Download free",

    "footer.privacy": "Privacy policy",
    "footer.security": "Security",
    "footer.source": "Source code",
    "footer.faq": "FAQ",
    "footer.download": "Download"
  };

  var META = {
    ar: { title: "CoShare — انسخ هنا، الصق هناك", toggle: "English" },
    en: { title: "CoShare — Copy here. Paste there.", toggle: "العربية" }
  };

  var nodes = Array.prototype.slice.call(document.querySelectorAll("[data-i18n]"));
  nodes.forEach(function (el) { el.setAttribute("data-ar", el.innerHTML); });

  function storedLang() {
    try { return localStorage.getItem("coshare.lang"); } catch (e) { return null; }
  }
  function storeLang(lang) {
    try { localStorage.setItem("coshare.lang", lang); } catch (e) { /* private mode */ }
  }

  var video = document.getElementById("introVideo");
  var posterImg = document.getElementById("posterImg");

  function applyLang(lang) {
    document.documentElement.lang = lang;
    document.documentElement.dir = lang === "ar" ? "rtl" : "ltr";
    nodes.forEach(function (el) {
      var key = el.getAttribute("data-i18n");
      el.innerHTML = lang === "ar" ? el.getAttribute("data-ar") : (EN[key] || el.getAttribute("data-ar"));
    });
    document.title = META[lang].title;
    document.getElementById("langToggle").textContent = META[lang].toggle;
    if (posterImg) posterImg.src = "assets/video/poster-" + lang + ".jpg";
    if (video && !video.paused) { video.pause(); }
    document.getElementById("videoFrame").classList.remove("playing");
    if (video) { video.removeAttribute("src"); video.load(); }
    highlightPlatform();
    labelCompareRows();
    var menuButton = document.getElementById("menuBtn");
    if (menuButton) menuButton.setAttribute("aria-label", lang === "ar" ? "القائمة" : "Menu");
  }

  // Phones show the comparison as cards: each answer is labelled with its column's name.
  function labelCompareRows() {
    var heads = document.querySelectorAll(".compare thead th");
    document.querySelectorAll(".compare tbody tr").forEach(function (row) {
      Array.prototype.forEach.call(row.children, function (cell, i) {
        if (i > 0 && heads[i]) cell.setAttribute("data-label", heads[i].textContent.trim());
      });
    });
  }

  var lang = storedLang() || ((navigator.language || "ar").toLowerCase().indexOf("ar") === 0 ? "ar" : "en");

  // Video: load the file for the current language only when asked to play.
  function playVideo() {
    if (!video) return;
    video.src = video.getAttribute("data-src-" + lang);
    video.poster = video.getAttribute("data-poster-" + lang);
    document.getElementById("videoFrame").classList.add("playing");
    var attempt = video.play();
    if (attempt && attempt.catch) attempt.catch(function () { /* user can press play */ });
  }
  var poster = document.getElementById("videoPoster");
  poster.addEventListener("click", playVideo);
  poster.addEventListener("keydown", function (e) { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); playVideo(); } });

  // Recommend the download that matches the visitor's device.
  function detectOS() {
    var ua = navigator.userAgent || "";
    var platform = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || "";
    if (/android/i.test(ua)) return "android";
    if (/iphone|ipad|ipod/i.test(ua) || (/Mac/i.test(platform) && navigator.maxTouchPoints > 1)) return "ios";
    if (/mac/i.test(platform) || /Mac OS X/i.test(ua)) return "mac";
    if (/win/i.test(platform) || /Windows/i.test(ua)) return "windows";
    if (/linux/i.test(platform) || /Linux/i.test(ua)) return "linux";
    return null;
  }
  var NAMES = { ios: "iPhone", mac: "Mac", android: "Android", windows: "Windows", linux: "Linux" };
  if (navigator.userAgentData && navigator.userAgentData.getHighEntropyValues && detectOS() === "windows") {
    navigator.userAgentData.getHighEntropyValues(["architecture"]).then(function (v) {
      var main = document.getElementById("winDownload");
      if (v.architecture === "arm" && main) main.href = main.href.replace("CoShare-Setup-x64.exe", "CoShare-Setup-arm64.exe");
    }).catch(function () {});
  }
  function highlightPlatform() {
    var os = detectOS();
    document.querySelectorAll(".dl-card").forEach(function (card) {
      card.classList.toggle("recommended", card.getAttribute("data-os") === os);
    });
    var hero = document.getElementById("heroDownload");
    var stickyLabel = document.getElementById("stickyLabel");
    if (os && hero) {
      var text = (lang === "ar" ? "حمّل لـ " : "Download for ") + NAMES[os];
      hero.querySelector("span").textContent = text;
      if (stickyLabel) stickyLabel.textContent = text;
      // Linux visitors go straight to the one-line install.
      if (os === "linux") { hero.href = "#linux"; stickyLabel.parentNode.href = "#linux"; }
    }
  }

  // Builds that aren't published yet get a friendly note instead of a 404 page.
  var toast = document.createElement("div");
  toast.className = "toast";
  toast.setAttribute("role", "status");
  document.body.appendChild(toast);
  var toastTimer;
  function showToast(text) {
    toast.textContent = text;
    toast.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toast.classList.remove("show"); }, 3500);
  }
  document.querySelectorAll(".dl-card a[data-platform]").forEach(function (link) {
    link.addEventListener("click", function (event) {
      var href = link.getAttribute("href");
      // Published builds live on GitHub Releases (another origin, so they can't be checked first).
      if (/^https:\/\/github\.com\//.test(href)) return;
      event.preventDefault();
      fetch(href, { method: "HEAD", cache: "no-store" }).then(function (response) {
        if (response.ok) { window.location.href = href; return; }
        throw new Error("missing");
      }).catch(function () {
        var name = link.closest(".dl-card").querySelector("h3").textContent;
        showToast(lang === "ar"
          ? "نسخة " + name + " قيد التجهيز وستتوفر قريباً هنا."
          : "The " + name + " build is on its way — it will be available here soon.");
      });
    });
  });

  // Copy buttons for terminal commands.
  document.querySelectorAll("[data-copy]").forEach(function (button) {
    button.addEventListener("click", function () {
      var code = document.getElementById(button.getAttribute("data-copy"));
      var label = button.innerHTML;
      function done() {
        button.textContent = lang === "ar" ? "✓ تم النسخ" : "✓ Copied";
        button.classList.add("copied");
        setTimeout(function () { button.innerHTML = label; button.classList.remove("copied"); }, 1800);
      }
      function fallback() {
        var range = document.createRange();
        range.selectNodeContents(code);
        var selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        try { document.execCommand("copy"); done(); } catch (e) { /* the command stays selected */ }
      }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(code.textContent).then(done, fallback);
      } else {
        fallback();
      }
    });
  });

  // Header border once the page scrolls.
  var header = document.querySelector(".site-header");
  function onScroll() { header.classList.toggle("scrolled", window.scrollY > 8); }
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  // Reveal sections as they enter the viewport. Anything already on screen shows at once, and if
  // the observer never reports (some embedded browsers), everything is shown after a moment.
  var reveals = Array.prototype.slice.call(document.querySelectorAll(".reveal"));
  function showAll() { reveals.forEach(function (el) { el.classList.add("visible"); }); }
  if ("IntersectionObserver" in window && !window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    document.documentElement.classList.add("can-reveal");
    var observed = false;
    var observer = new IntersectionObserver(function (entries) {
      observed = true;
      entries.forEach(function (entry) {
        if (entry.isIntersecting) { entry.target.classList.add("visible"); observer.unobserve(entry.target); }
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
    reveals.forEach(function (el) {
      if (el.getBoundingClientRect().top < window.innerHeight) {
        requestAnimationFrame(function () { el.classList.add("visible"); });
      } else {
        observer.observe(el);
      }
    });
    setTimeout(function () { if (!observed) showAll(); }, 1500);
  }

  document.getElementById("year").textContent = new Date().getFullYear();

  // Phone menu: opens under the header, closes on a link, Escape, or a tap outside.
  var header = document.querySelector(".site-header");
  var menuBtn = document.getElementById("menuBtn");
  var mobileMenu = document.getElementById("mobileMenu");
  function setMenu(open) {
    mobileMenu.hidden = !open;
    menuBtn.setAttribute("aria-expanded", String(open));
    header.classList.toggle("menu-open", open);
  }
  if (menuBtn && mobileMenu) {
    menuBtn.addEventListener("click", function () { setMenu(mobileMenu.hidden); });
    mobileMenu.addEventListener("click", function (e) { if (e.target.closest("a")) setMenu(false); });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && !mobileMenu.hidden) { setMenu(false); menuBtn.focus(); } });
    document.addEventListener("click", function (e) { if (!mobileMenu.hidden && !header.contains(e.target)) setMenu(false); });
    window.addEventListener("resize", function () { if (window.innerWidth > 920 && !mobileMenu.hidden) setMenu(false); });
  }

  // Phone download bar: appears once the hero buttons scroll away, hides at the download section.
  var sticky = document.getElementById("stickyCta");
  if (sticky && "IntersectionObserver" in window) {
    var heroGone = false, atDownloads = false;
    var update = function () { sticky.classList.toggle("show", heroGone && !atDownloads); };
    new IntersectionObserver(function (entries) { heroGone = !entries[0].isIntersecting; update(); })
      .observe(document.querySelector(".hero-ctas"));
    new IntersectionObserver(function (entries) { atDownloads = entries[0].isIntersecting; update(); }, { rootMargin: "0px 0px -20% 0px" })
      .observe(document.getElementById("download"));
  }

  // Start once everything above is defined.
  applyLang(lang);
  document.getElementById("langToggle").addEventListener("click", function () {
    lang = lang === "ar" ? "en" : "ar";
    storeLang(lang);
    applyLang(lang);
  });
})();
