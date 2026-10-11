// The camera and pose tracking for PhysioAI's web app.
//
// Everything here runs in the browser: the video is shown to the patient and
// handed to MediaPipe Pose Landmarker on this device. Only the 33 landmarks
// and the picture's average brightness are passed on to the app. No picture
// is stored or sent anywhere.
//
// The Dart side is lib/features/session/pose/pose_source_web.dart.

const TASKS_VISION =
  'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.14';
const POSE_MODEL =
  'https://storage.googleapis.com/mediapipe-models/pose_landmarker/' +
  'pose_landmarker_lite/float16/1/pose_landmarker_lite.task';

const LANDMARKS = 33;
// Brightness is cheap to estimate but not free: once every few frames is enough.
const BRIGHTNESS_EVERY = 6;

let video = null;
let stream = null;
let landmarker = null;
let frameCallback = null;
let running = false;
let frameCount = 0;
let brightness = 0;
let lastVideoTime = -1;

// Goes up with every start and stop, so a start that was overtaken by a stop
// (the screen was left while the camera was still opening) knows to give up.
let generation = 0;

// What MediaPipe is running on, and what is needed to move it to the CPU.
let vision = null;
let files = null;
let delegate = null;
let switching = false;
let failuresInARow = 0;

// For troubleshooting: `physioPose.status()` in the browser's console.
const stats = { frames: 0, withPerson: 0, errors: 0, lastError: null };

const probe = document.createElement('canvas');
probe.width = 32;
probe.height = 24;
const probeContext = probe.getContext('2d', { willReadFrequently: true });

function ensureVideo() {
  if (video) return video;
  video = document.createElement('video');
  video.autoplay = true;
  video.muted = true;
  video.playsInline = true;
  // Pinned to the space Flutter gives it. Left as an ordinary inline element
  // it is laid out like a word in a line of text and ends up outside that
  // space, so the patient sees the tracked skeleton but no picture.
  video.style.display = 'block';
  video.style.position = 'absolute';
  video.style.top = '0';
  video.style.left = '0';
  video.style.width = '100%';
  video.style.height = '100%';
  video.style.objectFit = 'fill';
  // Like a mirror: moving right moves the picture right.
  video.style.transform = 'scaleX(-1)';
  video.style.background = '#172B4D';
  return video;
}

const landmarkerOptions = (on) => ({
  baseOptions: { modelAssetPath: POSE_MODEL, delegate: on },
  runningMode: 'VIDEO',
  numPoses: 1,
});

async function loadLandmarker() {
  if (landmarker) return landmarker;
  vision = await import(`${TASKS_VISION}/vision_bundle.mjs`);
  files = await vision.FilesetResolver.forVisionTasks(`${TASKS_VISION}/wasm`);
  try {
    landmarker = await vision.PoseLandmarker.createFromOptions(
      files,
      landmarkerOptions('GPU')
    );
    delegate = 'GPU';
  } catch (_) {
    // No usable graphics acceleration: slower, but it still works.
    landmarker = await vision.PoseLandmarker.createFromOptions(
      files,
      landmarkerOptions('CPU')
    );
    delegate = 'CPU';
  }
  return landmarker;
}

// Some graphics drivers accept the model and then fail on every picture.
// Rather than show a live camera that never sees anyone, carry on without
// graphics acceleration.
async function switchToCpu() {
  if (switching || delegate !== 'GPU') return;
  switching = true;
  console.warn('PhysioAI: pose tracking is switching to the CPU.');
  try {
    const slower = await vision.PoseLandmarker.createFromOptions(
      files,
      landmarkerOptions('CPU')
    );
    try {
      landmarker.close();
    } catch (_) {}
    landmarker = slower;
    delegate = 'CPU';
    failuresInARow = 0;
  } catch (error) {
    stats.lastError = String((error && error.message) || error);
    console.error('PhysioAI: pose tracking could not start on the CPU.', error);
  } finally {
    switching = false;
  }
}

function measureBrightness() {
  probeContext.drawImage(video, 0, 0, probe.width, probe.height);
  const pixels = probeContext.getImageData(0, 0, probe.width, probe.height).data;
  let total = 0;
  for (let i = 0; i < pixels.length; i += 4) {
    total += 0.2126 * pixels[i] + 0.7152 * pixels[i + 1] + 0.0722 * pixels[i + 2];
  }
  return total / (pixels.length / 4) / 255;
}

function tick() {
  if (!running) return;
  if (video.readyState >= 2 && video.currentTime !== lastVideoTime) {
    lastVideoTime = video.currentTime;
    const now = performance.now();
    if (frameCount++ % BRIGHTNESS_EVERY === 0) brightness = measureBrightness();
    let found = null;
    if (!switching) {
      try {
        found = landmarker.detectForVideo(video, now).landmarks[0] || null;
        failuresInARow = 0;
      } catch (error) {
        // Never silent: a camera that sees nobody and a tracker that is
        // failing look the same on screen.
        stats.errors++;
        stats.lastError = String((error && error.message) || error);
        if (stats.errors <= 3) {
          console.error('PhysioAI: pose tracking failed on a frame.', error);
        }
        if (++failuresInARow >= 5) switchToCpu();
      }
    }
    stats.frames++;
    if (found) stats.withPerson++;
    const packed = new Float32Array(found ? 2 + LANDMARKS * 3 : 2);
    packed[0] = brightness;
    packed[1] = now;
    if (found) {
      for (let i = 0; i < LANDMARKS; i++) {
        const point = found[i];
        // The picture is shown mirrored, so its left edge is the camera's right.
        packed[2 + i * 3] = 1 - point.x;
        packed[3 + i * 3] = point.y;
        packed[4 + i * 3] = point.visibility ?? 0;
      }
    }
    if (frameCallback) frameCallback(packed);
  }
  requestAnimationFrame(tick);
}

async function start() {
  if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
    return 'unsupported';
  }
  stop();
  const mine = ++generation;
  let opened = null;
  try {
    opened = await navigator.mediaDevices.getUserMedia({
      audio: false,
      video: { facingMode: 'user', width: { ideal: 640 }, height: { ideal: 480 } },
    });
  } catch (error) {
    const name = error && error.name;
    if (name === 'NotAllowedError' || name === 'SecurityError') {
      return 'permission_denied';
    }
    if (name === 'NotFoundError' || name === 'OverconstrainedError') {
      return 'no_camera';
    }
    return 'failed';
  }
  const release = () => {
    for (const track of opened.getTracks()) track.stop();
  };
  if (mine !== generation) {
    release();
    return 'cancelled';
  }
  stream = opened;
  try {
    const element = ensureVideo();
    element.srcObject = stream;
    await element.play();
    await loadLandmarker();
  } catch (error) {
    stats.lastError = String((error && error.message) || error);
    console.error('PhysioAI: the camera or pose tracking could not start.', error);
    if (mine === generation) stop();
    else release();
    return 'failed';
  }
  if (mine !== generation) {
    // Stopped while the model was still loading.
    release();
    return 'cancelled';
  }
  running = true;
  frameCount = 0;
  lastVideoTime = -1;
  stats.frames = 0;
  stats.withPerson = 0;
  requestAnimationFrame(tick);
  return 'ok';
}

function stop() {
  generation++;
  running = false;
  if (stream) {
    for (const track of stream.getTracks()) track.stop();
    stream = null;
  }
  if (video) video.srcObject = null;
}

window.physioPose = {
  start,
  stop,
  aspect: () =>
    video && video.videoHeight ? video.videoWidth / video.videoHeight : 4 / 3,
  element: () => ensureVideo(),
  onFrame: (callback) => {
    frameCallback = callback;
  },
  // What the tracker is doing right now, for troubleshooting.
  status: () => ({
    running,
    delegate,
    listening: frameCallback !== null,
    video: video ? `${video.videoWidth}x${video.videoHeight}` : null,
    ...stats,
  }),
};
