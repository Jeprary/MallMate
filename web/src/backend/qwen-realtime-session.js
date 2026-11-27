'use strict';

const {randomUUID} = require('node:crypto');
const {WEBM_OPUS, createOpusEncoder} = require('./qwen-opus-encoder');

const MODEL = 'qwen-audio-3.0-asr-flash-streaming';
const ENDPOINT = 'wss://maas.qianwenaiapi.com/api-ws/v1/inference';
const SAMPLE_RATE = 16000;
const MAX_PCM_BYTES = SAMPLE_RATE * 2 * 30;

function connect({WebSocket, apiKey, onPartial, onFinishWritten, signal, maxPcmBytes, useOpus, inputFormat}) {
  const key = apiKey?.trim();
  if (!key || /\s/.test(key) || key.startsWith('sk-sp-')) {
    throw Error('Configure a pay-as-you-go Qwen AI Platform API key.');
  }
  const socket = new WebSocket(ENDPOINT, {
    headers: {Authorization: 'Bearer ' + key},
    // TCP attempts from Tencent Singapore measured 305–505 ms. A 2 s window passed the Qwen handshake.
    autoSelectFamilyAttemptTimeout: 2000
  });
  return createSession({
    socket, onPartial, onFinishWritten, signal, maxPcmBytes, inputFormat,
    createEncoder: useOpus ? createOpusEncoder : undefined
  });
}

function createSession({
  socket, onPartial = () => {}, onFinishWritten, signal,
  maxPcmBytes = MAX_PCM_BYTES, inputFormat = 'pcm', createEncoder
}) {
  const webm = inputFormat === WEBM_OPUS;
  if (webm && !createEncoder) throw Error('WebM speech input requires the Opus remuxer.');
  const taskId = randomUUID().replaceAll('-', '');
  const sentences = new Map();
  const drafts = new Map();
  let state = 'connecting';
  let audioBytes = 0;
  let encoder;
  let readyResolve, readyReject, resultResolve, resultReject;
  const ready = new Promise((resolve, reject) => { readyResolve = resolve; readyReject = reject; });
  const result = new Promise((resolve, reject) => { resultResolve = resolve; resultReject = reject; });
  ready.catch(() => {});
  result.catch(() => {});

  function settle(error, value) {
    if (state === 'done') return;
    state = 'done';
    signal?.removeEventListener('abort', cancel);
    encoder?.cancel();
    if (error) {
      readyReject(error);
      resultReject(error);
    } else {
      resultResolve(value);
    }
    if (socket.readyState === 0 || socket.readyState === 1) socket.close();
  }

  function send(data, written) {
    if (socket.readyState !== 1) throw Object.assign(Error('Realtime speech connection is not open.'), {speechStage: 'provider_write'});
    socket.send(data, (error) => {
      if (error) settle(Object.assign(Error('Could not send realtime speech data.'), {speechStage: 'provider_write'}));
      else written?.();
    });
  }

  function command(action, payload, written) {
    send(JSON.stringify({header: {action, task_id: taskId, streaming: 'duplex'}, payload}), written);
  }

  function open() {
    if (state !== 'connecting') return;
    try {
      command('run-task', {
        task_group: 'audio', task: 'asr', function: 'recognition', model: MODEL,
        parameters: {format: createEncoder ? 'opus' : 'pcm', sample_rate: webm ? 48000 : SAMPLE_RATE}, input: {}
      });
    } catch (error) {
      settle(error);
    }
  }

  function joined() {
    const parts = [...sentences.entries(), ...drafts.entries()];
    return parts.sort(([a], [b]) => a - b).map(([, text]) => text).join(' ');
  }

  function receive(raw) {
    if (state === 'done') return;
    let event;
    try { event = JSON.parse(raw.toString()); }
    catch {
      settle(Object.assign(Error('Invalid realtime speech response.'), {speechStage: 'provider_response'}));
      return;
    }
    const header = event?.header;
    if (header?.task_id !== taskId) return;
    if (header.event === 'task-failed' || header.event === 'error') {
      const providerCode = header.error_code;
      settle(Object.assign(Error('Qwen could not complete realtime transcription.'), {
        code: 'upstream_failed', speechStage: 'provider_task',
        providerCode: typeof providerCode === 'string' && /^[A-Za-z][A-Za-z0-9_.]{0,63}$/.test(providerCode) ? providerCode : undefined
      }));
      return;
    }
    if (state === 'connecting') {
      if (header.event === 'task-started') {
        state = 'ready';
        readyResolve();
      }
      return;
    }
    if (header.event === 'result-generated') {
      const sentence = event.payload?.output?.sentence;
      const id = sentence?.sentence_id;
      const text = typeof sentence?.text === 'string' ? sentence.text.trim() : '';
      if (sentence?.heartbeat || !Number.isInteger(id) || id < 1 || !text || sentences.has(id)) return;
      if (sentence.sentence_end === true) {
        drafts.delete(id);
        sentences.set(id, text);
      } else {
        drafts.set(id, text);
      }
      onPartial(joined());
    }
    if (header.event === 'task-finished') {
      // Keep last provider text if the task ended cleanly without a final
      // event for its trailing sentence. Errors never reach this path.
      const text = joined();
      if (state !== 'finishing') {
        settle(Object.assign(Error('Qwen ended transcription before recording stopped.'), {speechStage: 'provider_early_final'}));
      } else if (!text) {
        settle(Object.assign(Error('No speech detected.'), {code: 'no_speech', speechStage: 'provider_empty_final'}));
      } else {
        settle(null, {text, provider: 'qianwen-asr-streaming', model: MODEL});
      }
    }
  }

  function append(chunk) {
    if (state !== 'ready') throw Error('Realtime speech session is not accepting audio.');
    if (!Buffer.isBuffer(chunk) || !chunk.length || (!webm && chunk.length % 2 !== 0)) {
      throw Error('Invalid audio bytes.');
    }
    if (audioBytes + chunk.length > maxPcmBytes) {
      const error = Object.assign(Error('Recording exceeds the session audio limit.'), {code: 'too_long'});
      settle(error);
      throw error;
    }
    try {
      encoder ??= createEncoder?.({send, fail: settle, inputFormat, maxRecordingSeconds: maxPcmBytes / (SAMPLE_RATE * 2)});
      if (encoder) encoder.append(chunk);
      else send(chunk);
      audioBytes += chunk.length;
    } catch (error) {
      settle(error);
      throw error;
    }
  }

  function finish() {
    if (state === 'finishing' || state === 'done') return result;
    if (state !== 'ready') throw Error('Realtime speech session is not ready.');
    if (!audioBytes) {
      settle(Object.assign(Error('No speech detected.'), {code: 'no_speech', speechStage: 'no_audio'}));
      return result;
    }
    state = 'finishing';
    function sendFinish() {
      if (state === 'done') return;
      try { command('finish-task', {input: {}}, onFinishWritten); }
      catch (error) { settle(error); }
    }
    if (encoder) encoder.finish().then(sendFinish, settle);
    else sendFinish();
    return result;
  }

  function cancel() {
    settle(Object.assign(Error('Realtime speech cancelled.'), {code: 'cancelled'}));
  }

  socket.on('message', receive);
  socket.on('unexpected-response', (_request, response) => {
    response.destroy();
    settle(Object.assign(Error('Qwen rejected the realtime speech connection.'), {
      speechStage: 'provider_upgrade', providerStatus: response.statusCode
    }));
  });
  socket.on('error', () => settle(Object.assign(Error('Realtime speech connection failed.'), {speechStage: 'provider_transport'})));
  socket.on('close', providerCloseCode => settle(Object.assign(Error('Realtime speech ended before the final result.'), {
    speechStage: 'provider_closed', providerCloseCode
  })));
  socket.once('open', open);
  if (signal?.aborted) cancel();
  else signal?.addEventListener('abort', cancel, {once: true});
  if (socket.readyState === 1) open();
  return {append, finish, cancel, ready, result};
}

module.exports = {MODEL, ENDPOINT, SAMPLE_RATE, MAX_PCM_BYTES, connect, createSession};
