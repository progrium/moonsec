// KeyboardEvent.code (physical key, layout independent) to USB HID keyboard usage
// (page 7), which is what core.input sends and every host injects.
// https://www.w3.org/TR/uievents-code/ and the HID Usage Tables, section 10.

const table: Record<string, number> = {};

const letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
for (let i = 0; i < letters.length; i++) table[`Key${letters[i]}`] = 0x04 + i;
const digits = "1234567890";
for (let i = 0; i < digits.length; i++) table[`Digit${digits[i]}`] = 0x1e + i;
for (let i = 1; i <= 12; i++) table[`F${i}`] = 0x3a + i - 1;
for (let i = 13; i <= 24; i++) table[`F${i}`] = 0x68 + i - 13;
const numpadDigits = "1234567890";
for (let i = 0; i < numpadDigits.length; i++) table[`Numpad${numpadDigits[i]}`] = 0x59 + i;

Object.assign(table, {
  Enter: 0x28,
  Escape: 0x29,
  Backspace: 0x2a,
  Tab: 0x2b,
  Space: 0x2c,
  Minus: 0x2d,
  Equal: 0x2e,
  BracketLeft: 0x2f,
  BracketRight: 0x30,
  Backslash: 0x31,
  Semicolon: 0x33,
  Quote: 0x34,
  Backquote: 0x35,
  Comma: 0x36,
  Period: 0x37,
  Slash: 0x38,
  CapsLock: 0x39,
  PrintScreen: 0x46,
  ScrollLock: 0x47,
  Pause: 0x48,
  Insert: 0x49,
  Home: 0x4a,
  PageUp: 0x4b,
  Delete: 0x4c,
  End: 0x4d,
  PageDown: 0x4e,
  ArrowRight: 0x4f,
  ArrowLeft: 0x50,
  ArrowDown: 0x51,
  ArrowUp: 0x52,
  NumLock: 0x53,
  NumpadDivide: 0x54,
  NumpadMultiply: 0x55,
  NumpadSubtract: 0x56,
  NumpadAdd: 0x57,
  NumpadEnter: 0x58,
  NumpadDecimal: 0x63,
  IntlBackslash: 0x64,
  ContextMenu: 0x65,
  Power: 0x66,
  NumpadEqual: 0x67,
  Help: 0x75,
  AudioVolumeMute: 0x7f,
  VolumeMute: 0x7f,
  AudioVolumeUp: 0x80,
  VolumeUp: 0x80,
  AudioVolumeDown: 0x81,
  VolumeDown: 0x81,
  NumpadComma: 0x85,
  IntlRo: 0x87,
  KanaMode: 0x88,
  IntlYen: 0x89,
  Convert: 0x8a,
  NonConvert: 0x8b,
  Lang1: 0x90,
  Lang2: 0x91,
  ControlLeft: 0xe0,
  ShiftLeft: 0xe1,
  AltLeft: 0xe2,
  MetaLeft: 0xe3,
  OSLeft: 0xe3, // Firefox before 118
  ControlRight: 0xe4,
  ShiftRight: 0xe5,
  AltRight: 0xe6,
  MetaRight: 0xe7,
  OSRight: 0xe7,
});

/** The HID usage for a KeyboardEvent.code, or 0 when it has none. */
export function hidUsage(code: string): number {
  return table[code] ?? 0;
}

/**
 * Fallback for browsers that leave `code` empty (some virtual keyboards, old WebKit):
 * map the legacy keyCode for the keys that have a stable one.
 */
export function hidUsageFromKeyCode(keyCode: number): number {
  if (keyCode >= 65 && keyCode <= 90) return 0x04 + keyCode - 65; // A..Z
  if (keyCode >= 49 && keyCode <= 57) return 0x1e + keyCode - 49; // 1..9
  if (keyCode === 48) return 0x27; // 0
  if (keyCode >= 112 && keyCode <= 123) return 0x3a + keyCode - 112; // F1..F12
  const legacy: Record<number, number> = {
    8: 0x2a, 9: 0x2b, 13: 0x28, 16: 0xe1, 17: 0xe0, 18: 0xe2, 27: 0x29, 32: 0x2c,
    33: 0x4b, 34: 0x4e, 35: 0x4d, 36: 0x4a, 37: 0x50, 38: 0x52, 39: 0x4f, 40: 0x51,
    45: 0x49, 46: 0x4c, 91: 0xe3, 93: 0x65,
  };
  return legacy[keyCode] ?? 0;
}

let reverse: Map<number, string> | null = null;

/** The KeyboardEvent.code for a HID usage (the first name in the table), or "" (browser host injection). */
export function codeForUsage(usage: number): string {
  if (!reverse) {
    reverse = new Map();
    for (const [code, u] of Object.entries(table)) if (!reverse.has(u)) reverse.set(u, code);
  }
  return reverse.get(usage) ?? "";
}
