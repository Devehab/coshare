'use strict';
// System clipboard for Windows and Linux (and macOS during development).
// Change detection is cheap and event-like where the OS allows it:
//   Windows → GetClipboardSequenceNumber() (increments on every copy)
//   Linux   → XFixes selection-owner events on CLIPBOARD (works under X11 and XWayland)
//   other   → a content signature, polled
const { clipboard, nativeImage } = require('electron');

const IMAGE_FORMATS = ['image/png', 'image/jpeg', 'image/bmp', 'image/tiff', 'image/gif'];
const looksLikeURL = (s) => s.length < 2048 && !/\s/.test(s.trim()) && /^(https?|file):/i.test(s.trim());

function windowsCounter() {
  const koffi = require('koffi');
  const user32 = koffi.load('user32.dll');
  const GetClipboardSequenceNumber = user32.func('__stdcall', 'GetClipboardSequenceNumber', 'uint32', []);
  return { name: 'windows-sequence', token: () => GetClipboardSequenceNumber() };
}

function x11Counter() {
  const koffi = require('koffi');
  const x11 = koffi.load('libX11.so.6');
  const xfixes = koffi.load('libXfixes.so.3');
  const XOpenDisplay = x11.func('void *XOpenDisplay(const char *name)');
  const XDefaultRootWindow = x11.func('unsigned long XDefaultRootWindow(void *display)');
  const XInternAtom = x11.func('unsigned long XInternAtom(void *display, const char *name, int onlyIfExists)');
  const XPending = x11.func('int XPending(void *display)');
  const XNextEvent = x11.func('int XNextEvent(void *display, void *event)');
  const XFlush = x11.func('int XFlush(void *display)');
  const XFixesQueryExtension = xfixes.func('int XFixesQueryExtension(void *display, _Out_ int *eventBase, _Out_ int *errorBase)');
  const XFixesSelectSelectionInput = xfixes.func('void XFixesSelectSelectionInput(void *display, unsigned long window, unsigned long selection, unsigned long mask)');

  const display = XOpenDisplay(null);
  if (!display) throw new Error('no X display');
  const eventBase = [0], errorBase = [0];
  if (!XFixesQueryExtension(display, eventBase, errorBase)) throw new Error('XFixes missing');
  const SET_SELECTION_OWNER_NOTIFY = 1;
  XFixesSelectSelectionInput(display, XDefaultRootWindow(display), XInternAtom(display, 'CLIPBOARD', 0), SET_SELECTION_OWNER_NOTIFY);
  XFlush(display);
  const event = Buffer.alloc(192); // sizeof(XEvent)
  let count = 0;
  return {
    name: 'x11-xfixes',
    token: () => {
      while (XPending(display) > 0) { XNextEvent(display, event); count++; }
      return count;
    },
  };
}

/** Fallback: signature of what is on the clipboard (images sampled less often, they are costly). */
function signatureCounter() {
  let calls = 0, imageSig = '';
  return {
    name: 'signature',
    token: () => {
      const formats = clipboard.availableFormats().join(',');
      const text = clipboard.readText();
      if (!text && IMAGE_FORMATS.some((f) => formats.includes(f)) && (calls++ % 4 === 0)) {
        const image = clipboard.readImage();
        const size = image.getSize();
        const bitmap = image.isEmpty() ? Buffer.alloc(0) : image.resize({ width: 16, height: 16 }).toBitmap();
        imageSig = `${size.width}x${size.height}:${bitmap.toString('base64')}`;
      }
      return `${formats}|${text.length}|${text.slice(0, 200)}|${text.length ? '' : imageSig}`;
    },
  };
}

function createCounter(log) {
  const attempts = process.platform === 'win32' ? [windowsCounter] : process.platform === 'linux' ? [x11Counter] : [];
  for (const attempt of attempts) {
    try { return attempt(); } catch (error) { log(`مراقبة الحافظة: ${error.message} — استخدام الطريقة البديلة`, true); }
  }
  return signatureCounter();
}

const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

function exactPNG(formats) {
  for (const format of ['image/png', 'PNG']) {
    if (!formats.includes(format)) continue;
    try {
      const data = clipboard.readBuffer(format);
      if (data.length > 8 && data.subarray(0, 8).equals(PNG_SIGNATURE)) return data;
    } catch {}
  }
  return null;
}

class SystemClipboard {
  constructor(log = () => {}) {
    this.counter = createCounter(log);
  }

  changeToken() { return this.counter.token(); }

  read({ includeImages, maxImageBytes }) {
    const formats = clipboard.availableFormats();
    const text = clipboard.readText();
    const hasImage = IMAGE_FORMATS.some((f) => formats.includes(f));
    if (includeImages && hasImage && (!text || looksLikeURL(text))) {
      // The original PNG bytes when the copying app offered them (Linux "image/png", Windows "PNG").
      const original = exactPNG(formats);
      if (original) return original.length > maxImageBytes ? null : { kind: 'image', data: original, uti: 'public.png' };
      const image = clipboard.readImage();
      if (!image.isEmpty()) {
        const png = image.toPNG();
        if (png.length > maxImageBytes) return null;
        return { kind: 'image', data: png, uti: 'public.png' };
      }
    }
    if (text) return { kind: 'text', text };
    return null;
  }

  write(content) {
    if (content.kind === 'text') {
      clipboard.writeText(content.text);
    } else {
      const image = nativeImage.createFromBuffer(content.data);
      if (image.isEmpty()) throw new Error(`صيغة صورة غير مدعومة هون (${content.uti})`);
      clipboard.writeImage(image);
    }
  }
}

module.exports = { SystemClipboard };
