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
// A frame is handled when the video reports a new picture, and at least this
// often regardless, so a video clock that stops moving cannot stop tracking.
const MAX_FRAME_GAP_MS = 100;

let video = null;
let stream = null;
let landmarker = null;
let frameCallback = null;
let running = false;
let frameCount = 0;
let brightness = 0;
let lastVideoTime = -1;

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
  video.style.width = '100%';
  video.style.height = '100%';
  video.style.objectFit = 'fill';
  // Like a mirror: moving right moves the picture right.
  video.style.transform = 'scaleX(-1)';
  video.style.background = '#172B4D';
  // The browser pauses a video when the page moves it (Flutter does when it
  // places the camera on screen). While tracking, it is started again at
  // once; otherwise the picture freezes and no new frames ever arrive.
  video.addEventListener('pause', resumeVideo);
  return video;
}

function resumeVideo() {
  if (!running || !video || !video.paused || !video.srcObject) return;
  lastProblem = 'the camera picture was paused and has been started again';
  if (resumes === 0) console.info(`[PhysioAI pose] ${lastProblem}`);
  resumes += 1;
  video.play().catch((error) => report('the camera picture could not restart', error));
}

let delegate = null;
// Problems are reported in the browser console (F12), each kind once, so a
// tracker that cannot see anyone is never silent about why.
const reported = new Set();
let detectFailures = 0;
let resumes = 0;
let lastFrameAt = 0;
let framesSent = 0;
let posesSeen = 0;
let lastProblem = null;
// After this many detection failures in a row on the graphics card, the
// tracker is rebuilt to run on the processor instead.
const GPU_FAILURES_BEFORE_CPU = 15;

function report(kind, error) {
  lastProblem = `${kind}: ${(error && error.message) || error}`;
  if (reported.has(kind)) return;
  reported.add(kind);
  console.error(`[PhysioAI pose] ${kind}`, error);
}

let vision = null;
let files = null;

async function createLandmarker(useDelegate) {
  if (!vision) {
    vision = await import(`${TASKS_VISION}/vision_bundle.mjs`);
    files = await vision.FilesetResolver.forVisionTasks(`${TASKS_VISION}/wasm`);
  }
  const created = await vision.PoseLandmarker.createFromOptions(files, {
    baseOptions: { modelAssetPath: POSE_MODEL, delegate: useDelegate },
    runningMode: 'VIDEO',
    numPoses: 1,
  });
  delegate = useDelegate;
  console.info(`[PhysioAI pose] tracker ready on the ${useDelegate}`);
  return created;
}

async function loadLandmarker() {
  if (landmarker) return landmarker;
  try {
    landmarker = await createLandmarker('GPU');
  } catch (error) {
    // No usable graphics acceleration: slower, but it still works.
    report('GPU tracker could not start, using the CPU', error);
    landmarker = await createLandmarker('CPU');
  }
  return landmarker;
}

let switching = false;

async function switchToCpu() {
  if (switching || delegate === 'CPU') return;
  switching = true;
  try {
    const old = landmarker;
    landmarker = await createLandmarker('CPU');
    detectFailures = 0;
    if (old) old.close();
  } catch (error) {
    report('CPU tracker could not start', error);
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

function detect(now) {
  if (switching || !landmarker) return null;
  try {
    const found = landmarker.detectForVideo(video, now).landmarks[0] || null;
    detectFailures = 0;
    return found;
  } catch (error) {
    detectFailures += 1;
    report(`pose detection failed on the ${delegate}`, error);
    if (delegate === 'GPU' && detectFailures >= GPU_FAILURES_BEFORE_CPU) {
      switchToCpu();
    }
    return null;
  }
}

function sendFrame() {
  const now = performance.now();
  if (frameCount++ % BRIGHTNESS_EVERY === 0) {
    try {
      brightness = measureBrightness();
    } catch (error) {
      report('brightness could not be measured', error);
    }
  }
  const found = detect(now);
  const packed = new Float32Array(found ? 2 + LANDMARKS * 3 : 2);
  packed[0] = brightness;
  packed[1] = now;
  if (found) {
    posesSeen += 1;
    for (let i = 0; i < LANDMARKS; i++) {
      const point = found[i];
      // The picture is shown mirrored, so its left edge is the camera's right.
      packed[2 + i * 3] = 1 - point.x;
      packed[3 + i * 3] = point.y;
      packed[4 + i * 3] = point.visibility ?? 0;
    }
  }
  if (frameCallback) {
    frameCallback(packed);
    framesSent += 1;
  }
}

function tick() {
  if (!running) return;
  try {
    if (video.paused) resumeVideo();
    const now = performance.now();
    const newPicture = video.currentTime !== lastVideoTime;
    if (
      video.readyState >= 2 &&
      (newPicture || now - lastFrameAt >= MAX_FRAME_GAP_MS)
    ) {
      lastVideoTime = video.currentTime;
      lastFrameAt = now;
      sendFrame();
    }
  } catch (error) {
    // One bad frame must never stop the tracking for the rest of the session.
    report('a camera frame could not be handled', error);
  } finally {
    if (running) requestAnimationFrame(tick);
  }
}

async function start() {
  if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
    return 'unsupported';
  }
  try {
    stop();
    stream = await navigator.mediaDevices.getUserMedia({
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
  try {
    const element = ensureVideo();
    element.srcObject = stream;
    await element.play();
    await loadLandmarker();
  } catch (error) {
    report('the camera or the pose model could not be started', error);
    stop();
    return 'failed';
  }
  running = true;
  frameCount = 0;
  framesSent = 0;
  posesSeen = 0;
  detectFailures = 0;
  resumes = 0;
  lastFrameAt = 0;
  lastVideoTime = -1;
  requestAnimationFrame(tick);
  return 'ok';
}

function stop() {
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
  // For troubleshooting in the browser console: physioPose.status()
  status: () => ({
    running,
    delegate,
    videoReady: !!video && video.readyState >= 2,
    videoPaused: !!video && video.paused,
    resumes,
    framesSent,
    posesSeen,
    detectFailures,
    lastProblem,
  }),
};
