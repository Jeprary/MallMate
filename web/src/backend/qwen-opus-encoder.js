'use strict';

const {spawn} = require('node:child_process');

const COMMAND = '/usr/bin/ffmpeg';
const WEBM_OPUS = 'webm-opus';

function createOpusEncoder({send, fail, inputFormat, maxRecordingSeconds, command = COMMAND}) {
  const audio = inputFormat === WEBM_OPUS
    ? [
      '-f', 'matroska', '-probesize', '4096', '-analyzeduration', '100000',
      '-codec_whitelist', 'opus', '-i', 'pipe:0',
      '-map', '0:a:0', '-t', String(maxRecordingSeconds), '-c:a', 'copy'
    ]
    : [
      '-probesize', '32', '-analyzeduration', '0',
      '-f', 's16le', '-ar', '16000', '-ac', '1', '-blocksize', '3200', '-i', 'pipe:0',
      '-c:a', 'libopus', '-application', 'voip', '-b:a', '24k'
    ];
  const args = [
    '-nostdin', '-v', 'error', '-protocol_whitelist', 'pipe', ...audio,
    '-page_duration', '100000', '-flush_packets', '1', '-f', 'ogg', 'pipe:1'
  ];
  const child = spawn(command, args, {stdio: ['pipe', 'pipe', 'pipe']});
  let encoderDiagnostic;
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', message => {
    if (encoderDiagnostic) return;
    if (/ebml header parsing failed|invalid data found/i.test(message)) encoderDiagnostic = 'invalid_container';
    else if (/matches no streams|does not contain any stream/i.test(message)) encoderDiagnostic = 'no_audio_stream';
  });
  const finished = new Promise((resolve, reject) => {
    child.once('error', error => reject(Object.assign(error, {speechStage: 'encoder_spawn'})));
    child.stdin.on('error', error => reject(Object.assign(error, {speechStage: 'encoder_input'})));
    child.stdout.on('error', error => reject(Object.assign(error, {speechStage: 'encoder_output'})));
    child.stdout.on('data', chunk => {
      try { send(chunk); } catch (error) { reject(error); }
    });
    child.once('close', code => {
      if (code === 0) resolve();
      else reject(Object.assign(Error('The Opus encoder could not finish the speech stream.'), {
        speechStage: 'encoder_exit', encoderExitCode: code, encoderDiagnostic
      }));
    });
  });
  finished.catch(fail);
  return {
    append(chunk) { child.stdin.write(chunk); },
    finish() { child.stdin.end(); return finished; },
    cancel() {
      child.stdin.destroy();
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
    }
  };
}

module.exports = {COMMAND, WEBM_OPUS, createOpusEncoder};
