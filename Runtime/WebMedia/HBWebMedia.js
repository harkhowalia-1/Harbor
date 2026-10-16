// Media capture for web pages in converted apps. Mac Catalyst's WebKit has no navigator.mediaDevices,
// MediaStream, MediaRecorder or canvas.captureStream, so this script, injected at document start into
// the app's own web views, provides them on top of a native message handler (HBWebMedia.m):
//  - getUserMedia / enumerateDevices for the Mac's cameras and microphones, with the system prompts;
//  - MediaStream and MediaStreamTrack; a <video> or <audio> given a stream as srcObject shows the
//    camera (painted as a -webkit-canvas() background, so CSS sizing, object-fit and transforms apply)
//    and plays microphone audio, and drawImage, createImageBitmap, createPattern and WebGL uploads of
//    that <video> read the newest frame;
//  - Web Audio: createMediaStreamSource (analysers, effects) and createMediaStreamDestination;
//  - canvas.captureStream, ImageCapture, MediaRecorder (MP4: H.264 and AAC, encoded natively),
//    permissions.query for camera and microphone, and devicechange events.
// It does nothing on pages that already have getUserMedia.
(function () {
  'use strict';
  const existing = navigator.mediaDevices;
  if (existing && existing.getUserMedia) return;
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.harborMedia;
  if (!handler) return;
  const call = message => handler.postMessage(message);
  const canPaint = typeof document.getCSSCanvasContext === 'function';
  const AudioContextClass = window.AudioContext || window.webkitAudioContext;

  // ---------- helpers ----------
  const fail = (name, message) => {
    try { return new DOMException(message, name); } catch (e) { const error = new Error(message); error.name = name; return error; }
  };
  const nativeError = error => {
    const text = String((error && error.message) || error);
    const at = text.indexOf(': ');
    return at > 0 ? fail(text.slice(0, at), text.slice(at + 2)) : fail('NotReadableError', text);
  };
  const number = value => {
    if (typeof value === 'number') return value;
    if (value && typeof value === 'object') return value.exact || value.ideal || value.max || value.min || 0;
    return 0;
  };
  const text = value => {
    if (typeof value === 'string') return value;
    if (Array.isArray(value)) return value[0] || '';
    if (value && typeof value === 'object') return text(value.exact || value.ideal);
    return '';
  };
  const uuid = () => (crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-8xxx-xxxxxxxxxxxx'.replace(/x/g, () => (Math.random() * 16 | 0).toString(16)));
  const later = fn => Promise.resolve().then(fn);
  const decode64 = base64 => {
    const bytes = atob(base64), data = new Uint8Array(bytes.length);
    for (let i = 0; i < bytes.length; i++) data[i] = bytes.charCodeAt(i);
    return data;
  };
  const encode64 = data => {
    const bytes = data instanceof Uint8Array ? data : new Uint8Array(data.buffer || data, data.byteOffset || 0, data.byteLength);
    let out = '';
    for (let i = 0; i < bytes.length; i += 0x8000) out += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(out);
  };
  const blob64 = blob => new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(',')[1] || '');
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
  // Fires an event and its on<type> handler.
  const emit = (target, type, fields) => {
    const event = new Event(type);
    for (const key in fields || {}) Object.defineProperty(event, key, { value: fields[key], enumerable: true });
    target.dispatchEvent(event);
    const handler = target['on' + type];
    if (typeof handler === 'function') { try { handler.call(target, event); } catch (e) { setTimeout(() => { throw e; }); } }
    return event;
  };

  // Plays chunks of mono PCM into a Web Audio node, slightly ahead of the context's clock.
  class Player {
    constructor(context, output) { this.context = context; this.output = output; this.next = 0; }
    push(samples, rate) {
      const context = this.context;
      if (context.state === 'closed' || !samples.length) return;
      const buffer = context.createBuffer(1, samples.length, rate);
      if (buffer.copyToChannel) buffer.copyToChannel(samples, 0); else buffer.getChannelData(0).set(samples);
      const node = context.createBufferSource();
      node.buffer = buffer;
      node.connect(this.output);
      const now = context.currentTime;
      let at = this.next;
      if (at < now + 0.01 || at > now + 0.4) at = now + 0.06; // start, underrun or drift: resync
      node.start(at);
      this.next = at + samples.length / rate;
    }
  }

  // ---------- sources: where a track's media comes from ----------
  let sourceCount = 0;
  class Source {
    constructor(kind, label) {
      this.kind = kind; this.label = label; this.live = true;
      this.tracks = new Set(); this.listeners = new Set(); this.videos = new Set(); this.recorders = new Set();
      this.frames = 0; this.frame = null;
    }
    get enabled() { for (const track of this.tracks) if (track.enabled) return true; return false; }
    end() {
      if (!this.live) return;
      this.live = false;
      this.stop();
      for (const track of [...this.tracks]) track._ended();
    }
    stop() {}
    // Called with each new video frame.
    painted(resized) {
      this.frames++;
      for (const video of this.videos) frameArrived(video, this, resized);
      for (const recorder of this.recorders) recorder._videoFrame(this);
    }
    // Called with each chunk of audio (mono Float32Array).
    heard(samples, rate) {
      if (!this.enabled) samples = new Float32Array(samples.length);
      for (const listener of this.listeners) listener(samples, rate);
      for (const recorder of this.recorders) recorder._audioChunk(this, samples, rate);
    }
    makeCanvas(width, height) {
      this.width = width; this.height = height;
      this.name = 'harbor-media-' + (++sourceCount);
      this.context = canPaint ? document.getCSSCanvasContext('2d', this.name, width, height) : null;
      if (this.context) { this.context.fillStyle = '#000'; this.context.fillRect(0, 0, width, height); }
    }
    resizeCanvas(width, height) {
      this.width = width; this.height = height;
      if (canPaint) this.context = document.getCSSCanvasContext('2d', this.name, width, height);
    }
  }

  // The Mac camera: frames arrive as JPEGs from native (long-polled) and are painted into a CSS canvas.
  class CameraSource extends Source {
    constructor(info, constraints) {
      super('video', info.label);
      this.info = info; this.constraints = constraints;
      this.facingMode = text(constraints.facingMode) || 'user';
      this.makeCanvas(info.width, info.height);
      window.addEventListener('pagehide', () => this.end());
      this.pump();
    }
    async pump() {
      let sequence = 0;
      while (this.live) {
        let frame;
        try { frame = await call({ op: 'poll', id: this.info.id, after: sequence }); } catch (e) { break; }
        if (!frame || !this.live) continue;
        sequence = frame.sequence;
        let image;
        try { image = await createImageBitmap(new Blob([decode64(frame.jpeg)], { type: 'image/jpeg' })); } catch (e) { continue; }
        if (!this.live) { if (image.close) image.close(); break; }
        const resized = frame.width !== this.width || frame.height !== this.height;
        if (resized) this.resizeCanvas(frame.width, frame.height);
        if (this.context) {
          if (this.enabled) this.context.drawImage(image, 0, 0);
          else { this.context.fillStyle = '#000'; this.context.fillRect(0, 0, this.width, this.height); }
        }
        if (this.frame && this.frame.close) this.frame.close();
        this.frame = image;
        this.painted(resized);
      }
      this.end();
    }
    stop() { call({ op: 'stop', id: this.info.id }).catch(() => {}); }
    recordInput() { return { camera: true }; }
    settings() {
      return { deviceId: this.info.deviceId, groupId: this.info.groupId || '', width: this.width, height: this.height,
               aspectRatio: this.width / this.height, frameRate: 30, facingMode: this.facingMode, resizeMode: 'none' };
    }
    capabilities() {
      return { deviceId: this.info.deviceId, groupId: this.info.groupId || '', width: { min: 1, max: this.width },
               height: { min: 1, max: this.height }, aspectRatio: { min: 0.001, max: 1000 }, frameRate: { min: 1, max: 30 },
               facingMode: [this.facingMode], resizeMode: ['none'] };
    }
  }

  // The Mac microphone: mono 16-bit PCM chunks arrive from native (long-polled).
  class MicSource extends Source {
    constructor(info, constraints) {
      super('audio', info.label);
      this.info = info; this.constraints = constraints; this.sampleRate = info.sampleRate;
      window.addEventListener('pagehide', () => this.end());
      this.pump();
    }
    async pump() {
      let sequence = 0;
      while (this.live) {
        let chunk;
        try { chunk = await call({ op: 'poll', id: this.info.id, after: sequence }); } catch (e) { break; }
        if (!chunk || !this.live) continue;
        sequence = chunk.sequence;
        if (!chunk.pcm) continue;
        const bytes = decode64(chunk.pcm), pcm = new Int16Array(bytes.buffer, 0, bytes.length >> 1);
        const samples = new Float32Array(pcm.length);
        for (let i = 0; i < pcm.length; i++) samples[i] = pcm[i] / 32768;
        this.sampleRate = chunk.sampleRate;
        this.heard(samples, chunk.sampleRate);
      }
      this.end();
    }
    stop() { call({ op: 'stop', id: this.info.id }).catch(() => {}); }
    recordInput() { return { mic: true }; }
    settings() {
      return { deviceId: this.info.deviceId, groupId: this.info.groupId || '', sampleRate: this.sampleRate, sampleSize: 16,
               channelCount: 1, echoCancellation: false, noiseSuppression: false, autoGainControl: false, latency: 0.02 };
    }
    capabilities() {
      return { deviceId: this.info.deviceId, groupId: this.info.groupId || '', sampleRate: { min: this.sampleRate, max: this.sampleRate },
               sampleSize: { min: 16, max: 16 }, channelCount: { min: 1, max: 1 }, echoCancellation: [false],
               noiseSuppression: [false], autoGainControl: [false] };
    }
  }

  // canvas.captureStream(): copies the canvas at the requested rate (or on requestFrame()).
  class CanvasSource extends Source {
    constructor(canvas, fps) {
      super('video', 'canvas');
      this.canvas = canvas; this.fps = fps;
      this.makeCanvas(canvas.width || 300, canvas.height || 150);
      this.frame = canvas;
      if (fps !== 0) this.timer = setInterval(() => this.tick(), 1000 / Math.min(Math.max(fps || 30, 1), 60));
    }
    tick() {
      if (!this.live) return;
      const width = this.canvas.width, height = this.canvas.height;
      if (!width || !height) return;
      const resized = width !== this.width || height !== this.height;
      if (resized) this.resizeCanvas(width, height);
      if (this.context) {
        this.context.clearRect(0, 0, width, height);
        if (this.enabled) this.context.drawImage(this.canvas, 0, 0);
      }
      this.painted(resized);
    }
    stop() { clearInterval(this.timer); }
    recordInput() { return { page: true, width: this.width, height: this.height }; }
    settings() { return { deviceId: '', groupId: '', width: this.width, height: this.height, frameRate: this.fps || 0, resizeMode: 'none' }; }
    capabilities() { return {}; }
  }

  // createMediaStreamDestination(): taps a Web Audio graph with a ScriptProcessor.
  class GraphSource extends Source {
    constructor(context) {
      super('audio', 'MediaStreamAudioDestinationNode');
      this.audioContext = context; this.sampleRate = context.sampleRate;
      this.input = context.createGain();
      this.processor = context.createScriptProcessor(4096, 1, 1);
      this.processor.onaudioprocess = event => {
        if (this.live) this.heard(event.inputBuffer.getChannelData(0).slice(), context.sampleRate);
      };
      this.input.connect(this.processor);
      this.processor.connect(context.destination); // a ScriptProcessor only runs while connected; it outputs silence
    }
    stop() { try { this.processor.disconnect(); } catch (e) {} }
    recordInput() { return { page: true, sampleRate: this.sampleRate }; }
    settings() { return { deviceId: '', groupId: '', sampleRate: this.sampleRate, channelCount: 1 }; }
    capabilities() { return {}; }
  }

  // ---------- MediaStreamTrack and MediaStream ----------
  class Track extends EventTarget {
    constructor(source) {
      super();
      this._source = source; this._constraints = {};
      this.id = uuid(); this.kind = source.kind; this.label = source.label;
      this.enabled = true; this.muted = false; this.readyState = 'live'; this.contentHint = '';
      this.onended = this.onmute = this.onunmute = null;
      source.tracks.add(this);
      if (source instanceof CanvasSource) {
        Object.defineProperty(this, 'canvas', { value: source.canvas, enumerable: true });
        this.requestFrame = () => source.tick();
      }
    }
    stop() {
      if (this.readyState === 'ended') return;
      this.readyState = 'ended';
      this._source.tracks.delete(this);
      if (!this._source.tracks.size) this._source.end();
    }
    _ended() {
      if (this.readyState === 'ended') return;
      this.readyState = 'ended';
      this._source.tracks.delete(this);
      emit(this, 'ended');
    }
    clone() {
      const track = this.readyState === 'live' ? new Track(this._source) : this;
      track.enabled = this.enabled;
      return track;
    }
    getSettings() { return this._source.settings(); }
    getConstraints() { return Object.assign({}, this._constraints); }
    getCapabilities() { return this._source.capabilities(); }
    applyConstraints(constraints) { this._constraints = Object.assign({}, constraints || {}); return Promise.resolve(); }
  }

  class Stream extends EventTarget {
    constructor(tracks) {
      super();
      if (tracks && typeof tracks.getTracks === 'function') tracks = tracks.getTracks();
      this.id = uuid(); this._tracks = [...(tracks || [])];
      this.onaddtrack = this.onremovetrack = this.onactive = this.oninactive = null;
    }
    get active() { return this._tracks.some(track => track.readyState === 'live'); }
    getTracks() { return [...this._tracks]; }
    getVideoTracks() { return this._tracks.filter(track => track.kind === 'video'); }
    getAudioTracks() { return this._tracks.filter(track => track.kind === 'audio'); }
    getTrackById(id) { return this._tracks.find(track => track.id === id) || null; }
    addTrack(track) { if (!this._tracks.includes(track)) { this._tracks.push(track); this._changed(); } }
    removeTrack(track) { if (this._tracks.includes(track)) { this._tracks = this._tracks.filter(t => t !== track); this._changed(); } }
    clone() { return new Stream(this._tracks.map(track => track.clone())); }
    _changed() { for (const element of attachedElements) if (element.__harborMedia && element.__harborMedia.stream === this) connect(element); }
  }

  if (!window.MediaStream) window.MediaStream = Stream;
  if (!window.MediaStreamTrack) window.MediaStreamTrack = Track;
  if (!window.CanvasCaptureMediaStreamTrack) window.CanvasCaptureMediaStreamTrack = Track;
  const isStream = value => value instanceof Stream;

  // ---------- <video> and <audio> playing a stream ----------
  const attachedElements = new Set();
  let outputContext = null;
  const output = () => {
    if (!outputContext || outputContext.state === 'closed') outputContext = new AudioContextClass();
    if (outputContext.state === 'suspended') outputContext.resume().catch(() => {});
    return outputContext;
  };
  const state = element => element.__harborMedia;
  const liveTrack = (element, kind) => {
    const tracks = kind === 'video' ? state(element).stream.getVideoTracks() : state(element).stream.getAudioTracks();
    return tracks.find(track => track.readyState === 'live' && track._source);
  };
  const fits = { cover: 'cover', contain: 'contain', fill: '100% 100%', none: 'auto', 'scale-down': 'contain' };
  const paint = (element, source) => {
    if (!source.name || !canPaint) return;
    const style = getComputedStyle(element);
    element.style.setProperty('background-image', '-webkit-canvas(' + source.name + ')', 'important');
    element.style.setProperty('background-size', fits[style.objectFit] || 'contain', 'important');
    element.style.setProperty('background-position', style.objectPosition || 'center', 'important');
    element.style.setProperty('background-repeat', 'no-repeat', 'important');
  };
  const fire = (element, names) => names.forEach(name => element.dispatchEvent(new Event(name)));

  function frameArrived(element, source, resized) {
    const media = state(element);
    if (!media) return;
    if (resized || media.frames === 0) paint(element, source);
    if (media.frames++ === 0) fire(element, ['loadedmetadata', 'loadeddata', 'canplay', 'canplaythrough']);
    else if (resized) fire(element, ['resize']);
    if (!media.paused && media.frames === 1) fire(element, ['playing']);
    if (media.frames % 30 === 0) paint(element, source); // follows object-fit changes
    if (media.callbacks.size && !media.paused) {
      const callbacks = media.callbacks, now = performance.now();
      media.callbacks = new Map();
      const metadata = { presentationTime: now, expectedDisplayTime: now, width: source.width, height: source.height,
                         mediaTime: (now - media.start) / 1000, presentedFrames: media.frames, processingDuration: 0 };
      callbacks.forEach(callback => { try { callback(now, metadata); } catch (e) { setTimeout(() => { throw e; }); } });
    }
  }

  // Binds the element to the stream's current video and audio tracks.
  function connect(element) {
    const media = state(element);
    const video = liveTrack(element, 'video'), videoSource = video ? video._source : null;
    if (media.video !== videoSource) {
      if (media.video) media.video.videos.delete(element);
      media.video = videoSource;
      if (videoSource) {
        videoSource.videos.add(element);
        if (videoSource.frames) later(() => { if (state(element) === media) frameArrived(element, videoSource, true); });
      }
    }
    const audio = liveTrack(element, 'audio'), audioSource = audio ? audio._source : null;
    const wanted = audioSource && !media.paused && !element.muted && element.volume > 0;
    if (media.audio && (!wanted || media.audio.source !== audioSource)) {
      media.audio.source.listeners.delete(media.audio.listener);
      try { media.audio.gain.disconnect(); } catch (e) {}
      media.audio = null;
    }
    if (wanted && !media.audio) {
      const context = output(), gain = context.createGain();
      gain.connect(context.destination);
      const player = new Player(context, gain), listener = (samples, rate) => player.push(samples, rate);
      audioSource.listeners.add(listener);
      media.audio = { source: audioSource, gain, listener };
    }
    if (media.audio) media.audio.gain.gain.value = element.volume;
    if (!videoSource && audioSource && media.frames === 0) {
      media.frames = 1;
      later(() => fire(element, ['loadedmetadata', 'loadeddata', 'canplay', 'canplaythrough']));
    }
  }

  const ownProperties = {
    videoWidth: { get() { const s = state(this).video; return s && s.frames ? s.width : 0; } },
    videoHeight: { get() { const s = state(this).video; return s && s.frames ? s.height : 0; } },
    readyState: { get() { return state(this).frames ? 4 : 0; } },
    networkState: { get() { return 2; } },
    paused: { get() { return state(this).paused; } },
    ended: { get() { return !state(this).stream.active; } },
    seeking: { get() { return false; } },
    currentTime: { get() { return (performance.now() - state(this).start) / 1000; }, set() {} },
    duration: { get() { return Infinity; } },
    play: { value() {
      const media = state(this);
      if (media.paused) {
        media.paused = false;
        fire(this, ['play']);
        if (media.frames) fire(this, ['playing']);
        connect(this);
      }
      return Promise.resolve();
    } },
    pause: { value() {
      const media = state(this);
      if (!media.paused) { media.paused = true; connect(this); fire(this, ['pause']); }
    } },
    load: { value() {} },
    requestVideoFrameCallback: { value(callback) { const media = state(this), id = media.nextCallback++; media.callbacks.set(id, callback); return id; } },
    cancelVideoFrameCallback: { value(id) { state(this).callbacks.delete(id); } },
  };
  const styleKeys = ['background-image', 'background-size', 'background-position', 'background-repeat'];

  function attach(element, stream) {
    const media = {
      stream, frames: 0, start: performance.now(), paused: !element.autoplay, video: null, audio: null,
      callbacks: new Map(), nextCallback: 1,
      style: styleKeys.map(key => [key, element.style.getPropertyValue(key), element.style.getPropertyPriority(key)]),
      onVolume: () => { if (state(element) === media) connect(element); },
    };
    element.__harborMedia = media;
    attachedElements.add(element);
    for (const key in ownProperties) Object.defineProperty(element, key, Object.assign({ configurable: true }, ownProperties[key]));
    element.addEventListener('volumechange', media.onVolume);
    for (const track of stream.getTracks()) track.addEventListener('ended', media.onVolume);
    connect(element);
    if (!media.paused) later(() => { if (state(element) === media) fire(element, ['play']); });
  }

  function detach(element) {
    const media = state(element);
    if (!media) return;
    if (media.video) media.video.videos.delete(element);
    if (media.audio) { media.audio.source.listeners.delete(media.audio.listener); try { media.audio.gain.disconnect(); } catch (e) {} }
    element.removeEventListener('volumechange', media.onVolume);
    for (const track of media.stream.getTracks()) track.removeEventListener('ended', media.onVolume);
    for (const key in ownProperties) delete element[key];
    for (const [key, value, priority] of media.style) element.style.setProperty(key, value, priority);
    delete element.__harborMedia;
    attachedElements.delete(element);
  }

  const mediaProto = HTMLMediaElement.prototype;
  const srcObject = Object.getOwnPropertyDescriptor(mediaProto, 'srcObject');
  Object.defineProperty(mediaProto, 'srcObject', {
    configurable: true, enumerable: true,
    get() { return state(this) ? state(this).stream : (srcObject ? srcObject.get.call(this) : null); },
    set(value) {
      detach(this);
      if (isStream(value)) attach(this, value);
      else if (srcObject) srcObject.set.call(this, value);
    },
  });
  const src = Object.getOwnPropertyDescriptor(mediaProto, 'src');
  if (src && src.set) {
    Object.defineProperty(mediaProto, 'src', {
      configurable: true, enumerable: true,
      get() { return src.get.call(this); },
      set(value) { detach(this); src.set.call(this, value); },
    });
  }

  // Anything that reads pixels from a stream's <video> gets the newest frame instead.
  const frameOf = value => {
    if (value instanceof HTMLVideoElement && state(value)) {
      const source = state(value).video;
      return source ? source.frame : null;
    }
    return value;
  };
  const wrap = (owner, name, index, async) => {
    const original = owner && owner[name];
    if (typeof original !== 'function') return;
    owner[name] = function (...args) {
      if (args[index] instanceof HTMLVideoElement && state(args[index])) {
        const frame = frameOf(args[index]);
        if (!frame) {
          if (async) return Promise.reject(fail('InvalidStateError', 'The video has no frame yet'));
          if (name === 'createPattern') return null;
          return undefined;
        }
        args[index] = frame;
      }
      return original.apply(this, args);
    };
  };
  wrap(window.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype, 'drawImage', 0);
  wrap(window.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype, 'createPattern', 0);
  wrap(window.OffscreenCanvasRenderingContext2D && OffscreenCanvasRenderingContext2D.prototype, 'drawImage', 0);
  wrap(window.OffscreenCanvasRenderingContext2D && OffscreenCanvasRenderingContext2D.prototype, 'createPattern', 0);
  wrap(window, 'createImageBitmap', 0, true);
  for (const gl of [window.WebGLRenderingContext, window.WebGL2RenderingContext]) {
    if (!gl) continue;
    for (const name of ['texImage2D', 'texSubImage2D']) {
      const original = gl.prototype[name];
      if (typeof original !== 'function') continue;
      gl.prototype[name] = function (...args) {
        const last = args.length - 1;
        if (args[last] instanceof HTMLVideoElement && state(args[last])) {
          const frame = frameOf(args[last]);
          if (!frame) return;
          args[last] = frame;
        }
        return original.apply(this, args);
      };
    }
  }

  // ---------- canvas.captureStream ----------
  if (!HTMLCanvasElement.prototype.captureStream) {
    HTMLCanvasElement.prototype.captureStream = function (frameRate) {
      return new Stream([new Track(new CanvasSource(this, frameRate === undefined ? 30 : frameRate))]);
    };
  }

  // ---------- Web Audio ----------
  const streamSourceNode = (context, stream) => {
    const track = stream && stream.getAudioTracks && stream.getAudioTracks().find(t => t._source);
    if (!track) throw fail('InvalidStateError', 'The stream has no audio track');
    const node = context.createGain(), player = new Player(context, node), source = track._source;
    const listener = (samples, rate) => {
      if (context.state === 'closed') { source.listeners.delete(listener); return; }
      player.push(samples, rate);
    };
    source.listeners.add(listener);
    Object.defineProperty(node, 'mediaStream', { value: stream, enumerable: true });
    if (context.state === 'suspended') context.resume().catch(() => {});
    return node;
  };
  const destinationNode = context => {
    const source = new GraphSource(context), node = source.input;
    Object.defineProperty(node, 'stream', { value: new Stream([new Track(source)]), enumerable: true });
    return node;
  };
  for (const Context of new Set([window.AudioContext, window.webkitAudioContext].filter(Boolean))) {
    const proto = Context.prototype, createSource = proto.createMediaStreamSource;
    proto.createMediaStreamSource = function (stream) {
      if (isStream(stream) || !createSource) return streamSourceNode(this, stream);
      return createSource.call(this, stream);
    };
    if (!proto.createMediaStreamDestination) proto.createMediaStreamDestination = function () { return destinationNode(this); };
  }
  if (!window.MediaStreamAudioSourceNode && AudioContextClass) {
    window.MediaStreamAudioSourceNode = function MediaStreamAudioSourceNode(context, options) {
      return streamSourceNode(context, options && options.mediaStream);
    };
  }
  if (!window.MediaStreamAudioDestinationNode && AudioContextClass) {
    window.MediaStreamAudioDestinationNode = function MediaStreamAudioDestinationNode(context) { return destinationNode(context); };
  }

  // ---------- ImageCapture ----------
  if (!window.ImageCapture) {
    window.ImageCapture = class ImageCapture {
      constructor(track) {
        if (!track || track.kind !== 'video') throw new TypeError('ImageCapture needs a video track');
        this.track = track;
      }
      async _frame() {
        const source = this.track._source;
        if (!source || this.track.readyState !== 'live') throw fail('InvalidStateError', 'The track has ended');
        for (let i = 0; !source.frame && i < 100; i++) await new Promise(resolve => setTimeout(resolve, 50));
        if (!source.frame) throw fail('UnknownError', 'No frame arrived');
        return source.frame;
      }
      async grabFrame() { return createImageBitmap(await this._frame()); }
      async takePhoto(settings) {
        const frame = await this._frame(), source = this.track._source;
        const canvas = document.createElement('canvas');
        canvas.width = (settings && settings.imageWidth) || source.width;
        canvas.height = (settings && settings.imageHeight) || source.height;
        canvas.getContext('2d').drawImage(frame, 0, 0, canvas.width, canvas.height);
        return new Promise(resolve => canvas.toBlob(resolve, 'image/jpeg', 0.92));
      }
      async getPhotoCapabilities() {
        const s = this.track._source;
        return { redEyeReduction: 'never', fillLightMode: ['off'], imageWidth: { min: 1, max: s.width, step: 1 },
                 imageHeight: { min: 1, max: s.height, step: 1 } };
      }
      async getPhotoSettings() {
        const s = this.track._source;
        return { redEyeReduction: false, fillLightMode: 'off', imageWidth: s.width, imageHeight: s.height };
      }
    };
  }

  // ---------- MediaRecorder (MP4, encoded natively) ----------
  if (!window.BlobEvent) {
    window.BlobEvent = class BlobEvent extends Event {
      constructor(type, init) { super(type, init); this.data = init && init.data; this.timecode = (init && init.timecode) || 0; }
    };
  }
  const recordable = type => {
    if (!type) return true;
    const parts = String(type).toLowerCase().split(';'), container = parts[0].trim();
    if (!['video/mp4', 'audio/mp4', 'audio/m4a', 'audio/x-m4a', 'video/quicktime'].includes(container)) return false;
    const codecs = (parts.slice(1).join(';').match(/codecs\s*=\s*"?([^"]*)"?/) || [])[1];
    if (!codecs) return true;
    return codecs.split(',').every(codec => /^(avc1|avc3|h264|mp4a|aac)/.test(codec.trim()));
  };
  const MB = 4 * 1024 * 1024;

  class Recorder extends EventTarget {
    constructor(stream, options) {
      super();
      if (!isStream(stream)) throw new TypeError('MediaRecorder needs a MediaStream');
      options = options || {};
      if (!recordable(options.mimeType)) throw fail('NotSupportedError', 'Only MP4 (H.264 and AAC) can be recorded: ' + options.mimeType);
      this.stream = stream;
      this._wanted = options.mimeType || '';
      this.mimeType = this._wanted;
      this.videoBitsPerSecond = options.videoBitsPerSecond || 0;
      this.audioBitsPerSecond = options.audioBitsPerSecond || 0;
      if (options.bitsPerSecond && !this.videoBitsPerSecond) this.videoBitsPerSecond = options.bitsPerSecond;
      this.audioBitrateMode = options.audioBitrateMode || 'variable';
      this.state = 'inactive';
      this.onstart = this.onstop = this.ondataavailable = this.onpause = this.onresume = this.onerror = null;
    }
    static isTypeSupported(type) { return !!type && recordable(type); }
    start(timeslice) {
      if (this.state !== 'inactive') throw fail('InvalidStateError', 'The recorder is already recording');
      const audioOnly = /^audio\//i.test(this._wanted);
      const video = audioOnly ? null : this.stream.getVideoTracks().find(t => t.readyState === 'live' && t._source);
      const audio = this.stream.getAudioTracks().find(t => t.readyState === 'live' && t._source);
      if (!video && !audio) throw fail('NotSupportedError', 'The stream has no live tracks');
      this.state = 'recording';
      this.mimeType = (this._wanted.split(';')[0].trim()) || (video ? 'video/mp4' : 'audio/mp4');
      if (/^audio\/(x-)?m4a/.test(this.mimeType)) this.mimeType = 'audio/mp4';
      this._tracks = [video, audio].filter(Boolean);
      this._slice = timeslice > 0 ? Math.max(timeslice, 250) : 0;
      this._busy = false; this._audio = []; this._audioLength = 0; this._chain = Promise.resolve();
      this._onEnded = () => { if (this._tracks.every(t => t.readyState === 'ended') && this.state !== 'inactive') this.stop(); };
      for (const track of this._tracks) track.addEventListener('ended', this._onEnded);
      this._started = call({
        op: 'recordStart', video: video ? video._source.recordInput() : null, audio: audio ? audio._source.recordInput() : null,
        fragmented: this._slice > 0, timeslice: this._slice, mimeType: this.mimeType,
        videoBitsPerSecond: this.videoBitsPerSecond, audioBitsPerSecond: this.audioBitsPerSecond,
      }).then(info => {
        this._id = info.id;
        this._sources = this._tracks.map(t => t._source).filter(s => s.recordInput().page);
        for (const source of this._sources) source.recorders.add(this);
        this._ping = setInterval(() => call({ op: 'recordPing', id: this._id }).catch(() => {}), 5000);
        if (this._slice) this._timer = setInterval(() => this._flush(), this._slice);
        emit(this, 'start');
      }, error => { this._fail(nativeError(error)); throw error; });
      this._started.catch(() => {});
    }
    _fail(error) {
      if (this.state === 'inactive') return;
      this._cleanup();
      this.state = 'inactive';
      emit(this, 'error', { error });
    }
    _cleanup() {
      clearInterval(this._timer); clearInterval(this._ping);
      for (const source of this._sources || []) source.recorders.delete(this);
      for (const track of this._tracks || []) track.removeEventListener('ended', this._onEnded);
    }
    _queue(work) { this._chain = this._chain.then(work).catch(() => {}); return this._chain; }
    _videoFrame(source) {
      if (this.state !== 'recording' || this._busy || this._id === undefined) return;
      const canvas = source.canvas;
      if (!canvas || !canvas.toBlob) return;
      this._busy = true;
      canvas.toBlob(blob => {
        if (!blob || this.state === 'inactive') { this._busy = false; return; }
        blob64(blob).then(jpeg => this._queue(() => call({ op: 'recordPush', id: this._id, video: jpeg })))
          .finally(() => { this._busy = false; });
      }, 'image/jpeg', 0.9);
    }
    _audioChunk(source, samples, rate) {
      if (this.state !== 'recording' || this._id === undefined) return;
      this._audio.push(samples); this._audioLength += samples.length;
      if (this._audioLength < rate / 10) return;
      const pcm = new Float32Array(this._audioLength);
      let at = 0;
      for (const chunk of this._audio) { pcm.set(chunk, at); at += chunk.length; }
      this._audio = []; this._audioLength = 0;
      this._queue(() => call({ op: 'recordPush', id: this._id, audio: encode64(pcm), sampleRate: rate }));
    }
    async _flush() {
      if (this._id === undefined) return;
      let data = null;
      await this._queue(async () => { data = await call({ op: 'recordData', id: this._id }); });
      if (data && data.data) emit(this, 'dataavailable', { data: new Blob([decode64(data.data)], { type: this.mimeType }), timecode: performance.now() });
    }
    stop() {
      if (this.state === 'inactive') return;
      this.state = 'inactive';
      this._cleanup();
      (async () => {
        try {
          await this._started;
          await this._chain;
          const result = await call({ op: 'recordStop', id: this._id });
          const parts = [];
          for (let offset = 0; offset < result.size; offset += MB) {
            const piece = await call({ op: 'recordRead', id: this._id, offset, length: MB });
            parts.push(decode64(piece));
          }
          call({ op: 'recordRelease', id: this._id }).catch(() => {});
          emit(this, 'dataavailable', { data: new Blob(parts, { type: this.mimeType }), timecode: performance.now() });
        } catch (error) {
          emit(this, 'error', { error: nativeError(error) });
        }
        emit(this, 'stop');
      })();
    }
    pause() {
      if (this.state === 'inactive') throw fail('InvalidStateError', 'The recorder is not recording');
      if (this.state === 'paused') return;
      this.state = 'paused';
      this._started.then(() => call({ op: 'recordPause', id: this._id })).catch(() => {});
      emit(this, 'pause');
    }
    resume() {
      if (this.state === 'inactive') throw fail('InvalidStateError', 'The recorder is not recording');
      if (this.state === 'recording') return;
      this.state = 'recording';
      this._started.then(() => call({ op: 'recordResume', id: this._id })).catch(() => {});
      emit(this, 'resume');
    }
    requestData() {
      if (this.state === 'inactive') throw fail('InvalidStateError', 'The recorder is not recording');
      if (this._slice) this._started.then(() => this._flush()).catch(() => {});
      else later(() => emit(this, 'dataavailable', { data: new Blob([], { type: this.mimeType }), timecode: performance.now() }));
    }
  }
  if (!window.MediaRecorder) window.MediaRecorder = Recorder;

  // ---------- navigator.mediaDevices ----------
  const start = async (kind, constraints) => {
    try {
      return await call({ op: 'start', kind, width: number(constraints.width), height: number(constraints.height),
                          deviceId: text(constraints.deviceId), facingMode: text(constraints.facingMode) });
    } catch (error) {
      throw nativeError(error);
    }
  };
  const getUserMedia = async constraints => {
    constraints = constraints || {};
    if (!constraints.video && !constraints.audio) throw new TypeError('getUserMedia needs video or audio');
    const video = constraints.video ? (typeof constraints.video === 'object' ? constraints.video : {}) : null;
    const audio = constraints.audio ? (typeof constraints.audio === 'object' ? constraints.audio : {}) : null;
    const sources = [];
    try {
      if (video) sources.push(new CameraSource(await start('video', video), video));
      if (audio) sources.push(new MicSource(await start('audio', audio), audio));
    } catch (error) {
      sources.forEach(source => source.end());
      throw error;
    }
    return new Stream(sources.map(source => {
      const track = new Track(source);
      track._constraints = Object.assign({}, source.constraints);
      return track;
    }));
  };
  const deviceInfo = d => {
    const info = { deviceId: d.deviceId, groupId: d.groupId || '', kind: d.kind, label: d.label };
    return Object.assign({ toJSON: () => Object.assign({}, info), getCapabilities: () => ({ deviceId: d.deviceId, groupId: d.groupId || '' }) }, info);
  };
  const enumerateDevices = async () => (await call({ op: 'devices' })).map(deviceInfo);

  const devices = existing || new EventTarget();
  devices.getUserMedia = getUserMedia;
  devices.enumerateDevices = enumerateDevices;
  devices.getSupportedConstraints = () => ({
    deviceId: true, groupId: true, facingMode: true, width: true, height: true, aspectRatio: true, frameRate: true,
    resizeMode: true, sampleRate: true, sampleSize: true, channelCount: true, echoCancellation: true,
    noiseSuppression: true, autoGainControl: true, latency: true,
  });
  if (!devices.addEventListener) {
    const target = new EventTarget();
    devices.addEventListener = target.addEventListener.bind(target);
    devices.removeEventListener = target.removeEventListener.bind(target);
    devices.dispatchEvent = target.dispatchEvent.bind(target);
  }
  // devicechange: watch native only once a page listens.
  let watching = false;
  const watch = async () => {
    if (watching) return;
    watching = true;
    while (true) {
      let changed;
      try { changed = await call({ op: 'watchDevices' }); } catch (e) { return; }
      if (changed) emit(devices, 'devicechange');
    }
  };
  const addListener = devices.addEventListener;
  devices.addEventListener = function (type, ...rest) { if (type === 'devicechange') watch(); return addListener.call(this, type, ...rest); };
  let ondevicechange = null;
  Object.defineProperty(devices, 'ondevicechange', {
    configurable: true, enumerable: true,
    get() { return ondevicechange; },
    set(value) { ondevicechange = value; if (value) watch(); },
  });
  if (!existing) Object.defineProperty(navigator, 'mediaDevices', { value: devices, configurable: true, enumerable: true });
  if (!navigator.getUserMedia) navigator.getUserMedia = (c, ok, err) => { getUserMedia(c).then(ok, err); };
  if (!navigator.webkitGetUserMedia) navigator.webkitGetUserMedia = navigator.getUserMedia;

  // ---------- permissions.query({ name: 'camera' | 'microphone' }) ----------
  const permissions = navigator.permissions;
  if (permissions && typeof permissions.query === 'function') {
    const query = permissions.query.bind(permissions);
    permissions.query = async function (descriptor) {
      const name = descriptor && descriptor.name;
      if (name !== 'camera' && name !== 'microphone') return query(descriptor);
      const status = new EventTarget();
      status.name = name; status.onchange = null;
      status.state = await call({ op: 'permission', name });
      return status;
    };
  }
})();
