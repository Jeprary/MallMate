(function (root) {
'use strict';

const errorMessages = {
  busy: 'Speech recognition is busy. Try again shortly.',
  unavailable: 'Speech recognition is unavailable. Try again shortly.',
  no_speech: 'No speech detected. Try again or type instead.',
  too_long: 'Voice recording is too long. Try a shorter request.',
  timeout: 'Voice transcription timed out. Try again or type instead.',
  invalid_audio: 'This recording could not be read. Please record again.'
};
const OPUS_MIME = 'audio/webm;codecs=opus';
const OPUS_TARGET_BITRATE = 24000;
const RECORDER_TIMESLICE_MS = 250;
const PCM_BYTES_PER_SECOND = 16000 * 2;
const SPEECH_TIMEOUT_MS = 30_000;
const pcmModules = new WeakMap();

function preparePcmCapture(audio) {
  let ready = pcmModules.get(audio);
  if (!ready) {
    ready = Promise.resolve().then(() => audio.audioWorklet.addModule('/api/public/speech/pcm-capture.js'))
      .then(() => true, () => { pcmModules.delete(audio); return false; });
    pcmModules.set(audio, ready);
  }
  return ready;
}

function create({
  onText = () => {}, onState = () => {}, onComplete = () => {},
  onLevel = () => {}, onPreview = () => {}, maxRecordingSeconds = 30, acceptsWebmOpus = false,
  lang = root.navigator?.language, Recognition = root.SpeechRecognition || root.webkitSpeechRecognition,
  media = root.navigator?.mediaDevices, Audio = root.AudioContext, audioContext,
  Worklet = root.AudioWorkletNode, Recorder = root.MediaRecorder, Socket = root.WebSocket,
  location = root.location, lifecycle = root
} = {}) {
  const nativeOpus = acceptsWebmOpus && Recorder?.isTypeSupported?.(OPUS_MIME);
  const supported = Boolean(media?.getUserMedia && Audio && Socket && (nativeOpus || Worklet));
  let active = null;
  let disposed = false;

  const state = (status, message = '', diagnostics) => {
    if (!disposed) onState({
      status, message,
      ...(diagnostics ? {diagnostics} : {})
    });
  };

  function releaseMicrophone(run) {
    const recognition = run.recognition;
    run.recognition = null;
    run.stream?.getTracks().forEach((track) => track.stop());
    run.stream = null;
    try { recognition?.abort(); } catch {}
  }

  function stopMic(run) {
    clearInterval(run.meter);
    clearTimeout(run.duration);
    try { if (run.recorder && run.recorder.state !== 'inactive') run.recorder.stop(); } catch {}
    releaseMicrophone(run);
    try { run.source?.disconnect(); } catch {}
    if (run.capture) {
      run.capture.port.onmessage = null;
      try { run.capture.disconnect?.(); } catch {}
    }
    if (run.ownsAudio && run.audio?.state !== 'closed') run.audio?.close().catch(() => {});
  }

  function release(run) {
    if (active !== run) return false;
    active = null;
    clearTimeout(run.timeout);
    clearTimeout(run.readyTimeout);
    run.audioQueue.length = 0;
    stopMic(run);
    if (run.socket && run.socket.readyState < 2) run.socket.close();
    onPreview({text: '', final: false, source: 'qianwen'});
    return true;
  }

  function fail(run, code, message = errorMessages[code] || 'Voice transcription failed. Try again or type instead.') {
    if (release(run)) state('error', message, {
      errorCode: code, provider: 'qianwen-asr-streaming',
      stopReason: run.stopReason, stopIntentSent: !!run.stopIntentSent,
      captureDone: !!run.captureDone, finishSent: !!run.finishSent,
      finishMode: run.finishMode, socketCloseCode: run.socketCloseCode,
      ...(run.sessionId ? {sessionId: run.sessionId} : {}),
      ...(run.captureError ? {captureError: true} : {})
    });
  }

  function monitor(run) {
    let analyser, samples;
    try {
      analyser = run.audio.createAnalyser();
      analyser.fftSize = 1024;
      run.source.connect(analyser);
      samples = new Float32Array(analyser.fftSize);
    } catch {}
    const started = Date.now();
    let lastVoice = started;
    let voiceFrames = 0;
    let heard = false;
    run.meter = setInterval(() => {
      if (active !== run || run.phase !== 'recording') return;
      const metering = samples && run.audio.state === 'running';
      let level = 0;
      if (metering) {
        analyser.getFloatTimeDomainData(samples);
        level = Math.sqrt(samples.reduce((sum, value) => sum + value * value, 0) / samples.length);
        onLevel({level});
      }
      const now = Date.now();
      if (level > 0.012) {
        if (++voiceFrames >= 2) { heard = true; lastVoice = now; }
      } else {
        voiceFrames = 0;
        const lastSpeech = heard ? lastVoice : run.cloudSpeechAt;
        if (lastSpeech !== undefined && now - lastSpeech >= 1500) stop('silence');
        else if (metering && lastSpeech === undefined && now - started >= 8000) {
          if (run.serverAccepted) send(run, 'abort:no_speech');
          fail(run, 'no_speech');
        }
      }
    }, 150);
  }

  function record(run) {
    const {audio, stream, recorder} = run;
    try {
      run.source = audio.createMediaStreamSource(stream);
      if (recorder) {
        recorder.ondataavailable = ({data}) => {
          if (data.size) sendAudio(run, data);
        };
        recorder.onstop = () => finishCapture(run);
        recorder.onerror = () => {
          if (active !== run) return;
          run.captureError = true;
          if (run.phase === 'finishing') return;
          if (run.supportsStopIntent) send(run, 'abort:capture_error');
          fail(run, 'invalid_audio');
        };
        recorder.start(RECORDER_TIMESLICE_MS);
      } else {
        const capture = run.capture = new Worklet(audio, 'pcm-capture', {
          channelCount: 1, channelCountMode: 'explicit',
          processorOptions: {maxSamples: maxRecordingSeconds * 16000}
        });
        capture.port.onmessage = ({data}) => {
          if (data === 'done') finishCapture(run);
          else sendAudio(run, data);
        };
        run.source.connect(capture).connect(audio.destination);
      }
      run.phase = 'recording';
    } catch {
      fail(run, 'invalid_audio');
      return;
    }
    run.duration = setTimeout(() => stop('duration'), maxRecordingSeconds * 1000);
    state('listening', 'Listening…');
    monitor(run);
    startDevicePreview(run);
  }

  async function startDevicePreview(run) {
    if (!lang || typeof Recognition?.available !== 'function') return;
    try {
      const available = await Recognition.available({langs: [lang], processLocally: true});
      if (available !== 'available' || active !== run || run.phase !== 'recording') return;
      const recognition = new Recognition();
      if (!('processLocally' in recognition)) return;
      recognition.processLocally = true;
      recognition.lang = lang;
      recognition.continuous = true;
      recognition.interimResults = true;
      recognition.onresult = event => {
        if (active !== run || run.phase !== 'recording') return;
        const text = Array.from(event.results, result => result[0]?.transcript || '').join(' ').trim();
        if (!text) return;
        run.hasDevicePreview = true;
        onPreview({text, final: false, source: 'device'});
      };
      recognition.onend = recognition.onerror = () => {
        if (active !== run || run.phase !== 'recording' || !run.hasDevicePreview) return;
        run.hasDevicePreview = false;
        if (run.cloudPreview) onPreview({text: run.cloudPreview, final: false, source: 'qianwen'});
      };
      run.recognition = recognition;
      recognition.start(run.stream.getAudioTracks()[0]);
    } catch {}
  }

  function send(run, data) {
    if (active !== run || run.socket?.readyState !== 1) return false;
    try { run.socket.send(data); return true; }
    catch { fail(run, 'upstream_failed'); return false; }
  }

  function sendAudio(run, data) {
    if (active !== run || run.captureDone || run.finishMode) return;
    if (run.serverAccepted) { send(run, data); return; }
    run.queuedBytes += data.size ?? data.byteLength;
    if (run.queuedBytes > maxRecordingSeconds * PCM_BYTES_PER_SECOND) {
      fail(run, 'too_long');
      return;
    }
    run.audioQueue.push(data);
  }

  function sendStopIntent(run) {
    if (run.serverAccepted && run.supportsStopIntent && run.stopReason && !run.stopIntentSent) {
      run.stopIntentSent = send(run, 'stop:' + run.stopReason);
    }
  }

  function sendFinish(run) {
    if (run.serverAccepted && run.captureDone && !run.finishSent && !run.finishMode) {
      run.finishSent = send(run, run.captureError && run.supportsStopIntent ? 'finish:capture_error' : 'finish');
    }
  }

  function acceptInput(run, event) {
    if (run.serverAccepted) return;
    run.serverAccepted = true;
    if (typeof event.sessionId === 'string' && /^[a-f0-9-]{36}$/.test(event.sessionId)) run.sessionId = event.sessionId;
    run.supportsStopIntent = event.supportsStopIntent === true;
    sendStopIntent(run);
    for (const chunk of run.audioQueue) send(run, chunk);
    run.audioQueue.length = 0;
    sendFinish(run);
  }

  function finishCapture(run) {
    if (active !== run || run.captureDone) return;
    const automaticallyStopped = run.phase === 'recording';
    if (automaticallyStopped && !beginFinish(run, 'capture')) return;
    if (active !== run || run.phase !== 'finishing') return;
    // The recorder fires the last dataavailable event before stop, so the
    // final audio is already in the WebSocket's ordered send queue.
    run.captureDone = true;
    stopMic(run);
    if (automaticallyStopped) state('transcribing', 'Transcribing…');
    sendFinish(run);
  }

  function receive(run, data) {
    if (active !== run) return;
    let event;
    try { event = JSON.parse(data); }
    catch { fail(run, 'upstream_failed'); return; }
    if (event?.type === 'accepted' || event?.type === 'ready') acceptInput(run, event);
    if (event?.type === 'ready') clearTimeout(run.readyTimeout);
    if (event?.type === 'finish_ack' && run.phase === 'finishing' &&
        ['client', 'capture_error', 'drain_deadline'].includes(event.mode)) {
      run.finishMode = event.mode;
      if (event.mode === 'drain_deadline' && !run.captureDone) stopMic(run);
    }
    if (event?.type === 'partial' && typeof event.text === 'string') {
      const text = event.text.trim();
      if (!text) return;
      if (run.phase === 'recording' && text !== run.cloudPreview) run.cloudSpeechAt = Date.now();
      run.cloudPreview = text;
      if (!run.hasDevicePreview || run.phase === 'finishing') onPreview({text, final: false, source: 'qianwen'});
    }
    if (event?.type === 'error') fail(run, event.code);
    if (event?.type === 'final' && run.phase === 'finishing') {
      const text = typeof event.text === 'string' ? event.text.trim() : '';
      if (!text) { fail(run, 'no_speech'); return; }
      if (!release(run)) return;
      onText(text);
      state('idle');
      if (!disposed) onComplete(text);
    }
  }

  async function start() {
    if (active || disposed) return false;
    if (!supported) {
      state('unsupported', 'Voice recording is not supported in this browser. You can type instead.');
      return false;
    }
    const run = active = {phase: 'starting', audioQueue: [], queuedBytes: 0};
    state('listening', 'Starting microphone…');
    try {
      const sharedAudio = audioContext?.state !== 'closed' && audioContext;
      const audio = run.audio = sharedAudio || new Audio();
      run.ownsAudio = !sharedAudio;
      if (run.ownsAudio) Promise.resolve(audio.resume()).catch(() => {});
      const microphone = media.getUserMedia({audio: {channelCount: 1}, video: false});
      const pcmReady = nativeOpus ? null : preparePcmCapture(audio);
      run.stream = await microphone;
      if (active !== run) { stopMic(run); return false; }
      run.readyTimeout = setTimeout(() => fail(run, 'timeout'), SPEECH_TIMEOUT_MS);
      if (nativeOpus) {
        try { run.recorder = new Recorder(run.stream, {mimeType: OPUS_MIME, audioBitsPerSecond: OPUS_TARGET_BITRATE}); }
        catch (error) { if (!Worklet) throw error; }
      }
      if (!run.recorder && !await (pcmReady || preparePcmCapture(audio))) throw Error('Audio worklet unavailable.');
      if (active !== run) return false;
      const suffix = run.recorder ? '?format=webm-opus' : '';
      const socket = run.socket = new Socket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/api/public/speech/stream' + suffix);
      socket.onmessage = ({data}) => receive(run, data);
      socket.onclose = ({code} = {}) => {
        run.socketCloseCode = code;
        fail(run, 'upstream_failed');
      };
      record(run);
      return true;
    } catch (error) {
      const denied = error.name === 'NotAllowedError';
      fail(run, denied ? 'not-allowed' : 'invalid_audio', denied
        ? 'Microphone access was denied. Allow it in your browser settings, or type instead.'
        : 'No microphone is available. Check your microphone, or type instead.');
      return false;
    }
  }

  function beginFinish(run, reason) {
    if (run?.phase !== 'recording') return false;
    run.phase = 'finishing';
    run.stopReason = reason;
    clearInterval(run.meter);
    clearTimeout(run.duration);
    run.timeout = setTimeout(() => fail(run, 'timeout'), SPEECH_TIMEOUT_MS);
    sendStopIntent(run);
    return active === run;
  }

  function stop(reason = 'manual') {
    const run = active;
    if (!beginFinish(run, reason)) return;
    try {
      if (!run.recorder) run.capture.port.postMessage('finish');
      else if (run.recorder.state !== 'inactive') run.recorder.stop();
    } catch {
      run.captureError = true;
    }
    // The capture callback can drain its queued tail after the input tracks end.
    releaseMicrophone(run);
    if (active !== run) return;
    state('transcribing', 'Transcribing…');
    if (run.captureError) finishCapture(run);
  }

  function cancel() {
    if (active && release(active)) state('idle');
  }

  function dispose() {
    cancel();
    disposed = true;
    lifecycle.removeEventListener?.('pagehide', leavePage);
  }

  function leavePage() {
    const run = active;
    if (run?.supportsStopIntent) send(run, 'abort:pagehide');
    cancel();
  }

  lifecycle.addEventListener?.('pagehide', leavePage);
  return {supported, start, stop: () => stop(), cancel, dispose};
}

const api = {create};
if (typeof module !== 'undefined' && module.exports) module.exports = api;
else root.MallMateQwenStreamingVoice = api;
})(typeof window !== 'undefined' ? window : globalThis);
