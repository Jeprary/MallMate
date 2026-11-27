'use strict';

const {randomUUID} = require('node:crypto');
const {WEBM_OPUS} = require('./qwen-opus-encoder');
const {connect, MODEL, SAMPLE_RATE} = require('./qwen-realtime-session');
const {capacity} = require('./public-runtime');
const CAPTURE_DRAIN_MS = 1000;

function attach(server, {
  apiKey, origin, publicPreview = false, endpoint = '/api/public/speech/stream',
  openSession = connect, transport = require('ws'), now = Date.now, recordTiming, useOpus = false
}) {
  const {WebSocket, WebSocketServer} = transport;
  const host = new URL(origin).host;
  const maxRecordingSeconds = publicPreview ? 60 : 30;
  const maxPcmBytes = maxRecordingSeconds * SAMPLE_RATE * 2;
  const upstreamAudioFormat = useOpus ? 'opus' : 'pcm';
  const sockets = new WebSocketServer({noServer: true, maxPayload: maxPcmBytes, perMessageDeflate: false});
  const concurrency = publicPreview ? capacity.speechConcurrent : 1;
  let active = 0;
  let minute = -1, day = -1, recentStarts = 0, dailyStarts = 0;
  const lastAdmissionLog = new Map();

  function claim() {
    if (active >= concurrency) return 'concurrency_limit';
    if (publicPreview) {
      const time = now();
      const currentMinute = Math.floor(time / 60000);
      const chinaDay = Math.floor((time + 8 * 3600000) / 86400000);
      if (minute !== currentMinute) { minute = currentMinute; recentStarts = 0; }
      if (day !== chinaDay) { day = chinaDay; dailyStarts = 0; }
      if (recentStarts >= capacity.speechStartsPerMinute) return 'minute_limit';
      if (dailyStarts >= capacity.speechStartsPerDay) return 'daily_limit';
      recentStarts++;
      dailyStarts++;
    }
    active++;
    return null;
  }

  server.on('upgrade', (request, socket, head) => {
    socket.once('error', () => socket.destroy());
    const inputFormat = request.url === endpoint ? 'pcm'
      : useOpus && request.url === endpoint + '?format=' + WEBM_OPUS ? WEBM_OPUS : null;
    // The public service is loopback-only behind a gateway that may rewrite Host.
    if (request.method !== 'GET' || !inputFormat || request.headers.origin !== origin
        || (!publicPreview && request.headers.host !== host)) {
      socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
      return;
    }
    sockets.handleUpgrade(request, socket, head, peer => serve(peer, inputFormat));
  });

  function serve(peer, inputFormat) {
    peer.on('error', () => peer.terminate());
    const send = (type, fields = {}, callback) => {
      if (peer.readyState === WebSocket.OPEN) peer.send(JSON.stringify({type, ...fields}), callback);
    };
    const limit = claim();
    if (limit) {
      const logMinute = Math.floor(now() / 60000);
      if (lastAdmissionLog.get(limit) !== logMinute) {
        lastAdmissionLog.set(limit, logMinute);
        recordTiming?.({outcome: 'busy', speechStage: limit, active});
      }
      send('error', {code: 'busy'});
      peer.close();
      return;
    }

    const sessionId = randomUUID();
    const startedAt = performance.now();
    const timing = {};
    const pendingAudio = [];
    let inputAudioBytes = 0;
    const mark = (stage) => { timing[stage] = Math.round(performance.now() - startedAt); };
    const upstreamAbort = new AbortController();
    let inputOpen = true;
    let upstreamReady = false;
    let done = false;
    let outcome = 'client_disconnected';
    let stopReason, drainTimer, finishMode;
    const failureDetails = {};
    const timeout = setTimeout(() => close('timeout'), (maxRecordingSeconds + 30) * 1000);

    function release() {
      if (done) return;
      done = true;
      clearTimeout(timeout);
      clearTimeout(drainTimer);
      pendingAudio.length = 0;
      upstreamAbort.abort();
      active--;
    }

    function close(code, notify = true) {
      if (done) return;
      outcome = code || 'final';
      mark('outcomeMs');
      if (code && notify) send('error', {code});
      release();
      peer.close();
    }

    peer.once('close', clientCloseCode => {
      if (!done) mark('outcomeMs');
      release();
      mark('closedMs');
      recordTiming?.({sessionId, outcome, inputFormat, inputAudioBytes, upstreamAudioFormat, clientCloseCode,
        stopReason, finishMode, ...timing, ...failureDetails});
    });
    let session;
    try {
      session = openSession({
        WebSocket, apiKey, maxPcmBytes, signal: upstreamAbort.signal, useOpus, inputFormat,
        onFinishWritten: () => mark('upstreamFinishWrittenMs'),
        onPartial(text) {
          if (timing.firstPartialMs === undefined) mark('firstPartialMs');
          send('partial', {text});
        }
      });
    } catch {
      failureDetails.speechStage = 'session_start';
      close('unavailable');
      return;
    }

    function failed(error) {
      if (done) return;
      // Preserve classified metadata only. Error messages and provider payloads
      // can include audio details and stay out of these diagnostics.
      failureDetails.speechStage = error.speechStage || 'upstream_unknown';
      if (error.providerStatus) failureDetails.providerStatus = error.providerStatus;
      if (error.providerCode) failureDetails.providerCode = error.providerCode;
      if (Number.isInteger(error.providerCloseCode)) failureDetails.providerCloseCode = error.providerCloseCode;
      if (Number.isInteger(error.encoderExitCode)) failureDetails.encoderExitCode = error.encoderExitCode;
      if (error.encoderDiagnostic) failureDetails.encoderDiagnostic = error.encoderDiagnostic;
      const code = error.providerStatus === 401 || error.providerStatus === 403 ? 'unavailable'
        : ['no_speech', 'too_long'].includes(error.code) ? error.code : 'upstream_failed';
      close(code);
    }

    function inputError(error) {
      if (error.speechStage) { failed(error); return; }
      close(error.code === 'too_long' ? 'too_long' : 'invalid_audio');
    }

    function beginTranscriptionFinish(mode) {
      if (!inputOpen || done) return;
      inputOpen = false;
      clearTimeout(drainTimer);
      finishMode = mode;
      mark('finishStartedMs');
      if (stopReason) send('finish_ack', {mode});
      if (upstreamReady) {
        try { session.finish(); }
        catch (error) { inputError(error); }
      }
    }

    session.ready.then(() => {
      if (done) return;
      upstreamReady = true;
      mark('readyMs');
      send('ready', {sessionId, supportsStopIntent: true});
      try {
        for (const chunk of pendingAudio) session.append(chunk);
        pendingAudio.length = 0;
        if (!inputOpen) session.finish();
      } catch (error) { inputError(error); }
    }, failed);
    session.result.then(({text}) => {
      if (done) return;
      mark('upstreamFinalMs');
      send('final', {text}, error => {
        if (!error) mark('finalWrittenMs');
      });
      close();
    }, failed);

    peer.on('message', (data, binary) => {
      if (done) return;
      const control = !binary && data.length <= 20 ? data.toString() : '';
      if (control === 'abort:pagehide') {
        failureDetails.speechStage = 'client_pagehide';
        close('client_disconnected', false);
        return;
      }
      if (!inputOpen) {
        // A browser may deliver its last recorder events after the server deadline.
        if (finishMode === 'drain_deadline' && (binary || control === 'finish' || control === 'finish:capture_error')) {
          if (!binary && timing.lateFinishReceivedMs === undefined) mark('lateFinishReceivedMs');
          return;
        }
        close('invalid_audio');
        return;
      }
      if (control === 'abort:no_speech' || control === 'abort:capture_error') {
        const silence = control === 'abort:no_speech';
        failureDetails.speechStage = silence ? 'client_initial_silence' : 'client_capture_error';
        close(silence ? 'client_no_speech' : 'invalid_audio', false);
        return;
      }
      const stop = /^stop:(manual|silence|duration|capture)$/.exec(control);
      if (stop) {
        if (!stopReason) {
          stopReason = stop[1];
          mark('stopRequestedMs');
          drainTimer = setTimeout(() => beginTranscriptionFinish('drain_deadline'), CAPTURE_DRAIN_MS);
        }
        return;
      }
      try {
        if (binary) {
          if (!data.length || (inputFormat === 'pcm' && data.length % 2 !== 0)) {
            close('invalid_audio');
            return;
          }
          inputAudioBytes += data.length;
          if (inputAudioBytes > maxPcmBytes) { close('too_long'); return; }
          if (upstreamReady) session.append(data);
          else pendingAudio.push(data);
        }
        else if (control === 'finish' || control === 'finish:capture_error') {
          mark('finishReceivedMs');
          beginTranscriptionFinish(control === 'finish' ? 'client' : 'capture_error');
        } else close('invalid_audio');
      } catch (error) { inputError(error); }
    });
    send('accepted', {sessionId, supportsStopIntent: true});
  }

  return {
    configured: true, provider: 'qianwen-asr-streaming', model: MODEL,
    transport: 'websocket', maxRecordingSeconds, upstreamAudioFormat,
    inputAudioFormats: useOpus ? ['pcm', WEBM_OPUS] : ['pcm']
  };
}

module.exports = {attach};
