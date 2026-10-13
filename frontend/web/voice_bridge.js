// The spoken coach for PhysioAI's web app: guidance read aloud during a
// session, and an alert tone when a repetition needs correcting, so a patient
// standing back from the screen does not have to read it.
//
// The browser's own speech (Web Speech API) and tones made on the spot (Web
// Audio API): nothing is downloaded and nothing is recorded.
//
// The Dart side is lib/core/voice/voice_coach_web.dart.

const canSpeak = 'speechSynthesis' in window && 'SpeechSynthesisUtterance' in window;

let voice = null;
// What is being said now and what waits behind it. Only one line ever waits:
// a coach that falls behind the movement is worse than one that skips a line.
let current = null; // { id, priority }
let waiting = null; // { text, priority }
let nextId = 0;
let toneTimer = null;
let audio = null;

function chooseVoice() {
  if (!canSpeak) return;
  const voices = speechSynthesis.getVoices();
  voice =
    voices.find((v) => v.lang === 'en-GB' && v.localService) ||
    voices.find((v) => v.lang.startsWith('en') && v.localService) ||
    voices.find((v) => v.lang.startsWith('en')) ||
    null;
}
if (canSpeak) {
  chooseVoice();
  // Chrome fills in its voices a moment after the page loads.
  speechSynthesis.addEventListener('voiceschanged', chooseVoice);
}

function speakNow(text, priority) {
  const id = ++nextId;
  current = { id, priority };
  const line = new SpeechSynthesisUtterance(text);
  if (voice) {
    line.voice = voice;
    line.lang = voice.lang;
  } else {
    line.lang = 'en';
  }
  line.rate = 1;
  line.pitch = 1;
  line.volume = 1;
  const done = () => {
    // A line that was cut off reports its end late; by then another may
    // already be speaking, and that one is left alone.
    if (!current || current.id !== id) return;
    current = null;
    if (waiting) {
      const next = waiting;
      waiting = null;
      speakNow(next.text, next.priority);
    }
  };
  line.onend = done;
  line.onerror = done;
  speechSynthesis.speak(line);
}

// One short sound: frequency in Hz, when it starts and how long it lasts in
// seconds, how loud (0 to 1) and its waveform.
function beep(context, frequency, start, length, loudness, shape) {
  const oscillator = context.createOscillator();
  const gain = context.createGain();
  oscillator.type = shape;
  oscillator.frequency.value = frequency;
  // Faded in and out, so it does not click.
  gain.gain.setValueAtTime(0, start);
  gain.gain.linearRampToValueAtTime(loudness, start + 0.015);
  gain.gain.setValueAtTime(loudness, start + length - 0.03);
  gain.gain.linearRampToValueAtTime(0, start + length);
  oscillator.connect(gain).connect(context.destination);
  oscillator.start(start);
  oscillator.stop(start + length + 0.02);
}

// Each tone as [frequency, start, length] notes, with its loudness and shape.
const TONES = {
  // Two short beeps: something to correct, carry on.
  amber: { notes: [[740, 0, 0.14], [740, 0.23, 0.14]], loudness: 0.35, shape: 'sine' },
  // An alarm: stop.
  red: {
    notes: [[880, 0, 0.2], [620, 0.22, 0.2], [880, 0.44, 0.2], [620, 0.66, 0.2]],
    loudness: 0.5,
    shape: 'square',
  },
  // A rising chime: a set or the session is complete.
  done: { notes: [[523, 0, 0.16], [784, 0.17, 0.26]], loudness: 0.3, shape: 'sine' },
};

// Plays a tone and returns how long it lasts, in milliseconds; 0 when the
// browser cannot play one.
function playTone(kind) {
  const tone = TONES[kind];
  const Context = window.AudioContext || window.webkitAudioContext;
  if (!tone || !Context) return 0;
  try {
    audio = audio || new Context();
    if (audio.state === 'suspended') audio.resume();
    const now = audio.currentTime + 0.02;
    let end = 0;
    for (const [frequency, start, length] of tone.notes) {
      beep(audio, frequency, now + start, length, tone.loudness, tone.shape);
      end = Math.max(end, start + length);
    }
    return Math.round(end * 1000) + 80;
  } catch (_) {
    return 0;
  }
}

function clearTone() {
  if (toneTimer !== null) clearTimeout(toneTimer);
  toneTimer = null;
}

window.physioVoice = {
  supported() {
    return canSpeak;
  },

  // Says a line. priority: 0 background (instructions, where to stand),
  // 1 a repetition's count and correction, 2 urgent (the safety stop).
  // A line more important than the one being said cuts it off; otherwise it
  // waits its turn, replacing a less important line that was waiting.
  // tone, when given ('amber', 'red' or 'done'), sounds first.
  say(text, priority, tone) {
    const start = () => {
      toneTimer = null;
      if (!canSpeak) return;
      if (!current) {
        speakNow(text, priority);
      } else if (priority > current.priority) {
        waiting = null;
        speechSynthesis.cancel();
        speakNow(text, priority);
      } else if (!waiting || priority >= waiting.priority) {
        waiting = { text, priority };
      }
    };
    const wait = tone ? playTone(tone) : 0;
    if (wait > 0) {
      if (canSpeak && current && priority > current.priority) {
        // The tone is not spoken over by the line it interrupts.
        waiting = null;
        current = null;
        speechSynthesis.cancel();
      }
      clearTone();
      toneTimer = setTimeout(start, wait);
    } else {
      start();
    }
  },

  // Stops talking at once and forgets anything waiting.
  stop() {
    clearTone();
    waiting = null;
    current = null;
    if (canSpeak) speechSynthesis.cancel();
  },
};
