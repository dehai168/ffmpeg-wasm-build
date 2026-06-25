(function () {
  function stringToNewUTF8(module, text) {
    if (typeof module.stringToNewUTF8 === 'function') {
      return module.stringToNewUTF8(text);
    }

    const bytes = new TextEncoder().encode(`${text}\0`);
    const pointer = module._malloc(bytes.byteLength);
    module.HEAPU8.set(bytes, pointer);
    return pointer;
  }

  function utf8ToString(module, pointer) {
    if (!pointer) {
      return '';
    }

    if (typeof module.UTF8ToString === 'function') {
      return module.UTF8ToString(pointer);
    }

    let end = pointer;
    while (module.HEAPU8[end] !== 0) {
      end += 1;
    }

    return new TextDecoder().decode(module.HEAPU8.subarray(pointer, end));
  }

  function copyHeapBytes(module, pointer, size) {
    if (!pointer || size <= 0) {
      return new Uint8Array();
    }
    return module.HEAPU8.slice(pointer, pointer + size);
  }

  function createAudioBuffer(module, frameIndex) {
    const sampleRate = module._iov_decoder_frame_sample_rate(frameIndex);
    const channels = Math.max(1, module._iov_decoder_frame_channels(frameIndex));
    const samples = module._iov_decoder_frame_audio_samples(frameIndex);
    const bytes = module._iov_decoder_frame_audio_bytes(frameIndex);
    const pointer = module._iov_decoder_frame_audio_data(frameIndex);

    if (!sampleRate || !samples || !bytes || !pointer) {
      return null;
    }

    const AudioContextCtor = self.AudioContext || self.webkitAudioContext;
    if (!AudioContextCtor) {
      return null;
    }

    const audioContext = new AudioContextCtor({ sampleRate });
    const buffer = audioContext.createBuffer(channels, samples, sampleRate);
    const pcm = new Float32Array(copyHeapBytes(module, pointer, bytes).buffer);

    for (let channel = 0; channel < channels; channel += 1) {
      const channelData = buffer.getChannelData(channel);
      for (let i = 0; i < samples; i += 1) {
        channelData[i] = pcm[i * channels + channel];
      }
    }

    void audioContext.close();
    return buffer;
  }

  function collectDecodedFrames(module) {
    const frames = [];
    const count = module._iov_decoder_frame_count();

    for (let index = 0; index < count; index += 1) {
      if (module._iov_decoder_frame_is_video(index)) {
        const width = module._iov_decoder_frame_width(index);
        const height = module._iov_decoder_frame_height(index);
        const formatPtr = module._iov_decoder_frame_format(index);
        const format = formatPtr ? utf8ToString(module, formatPtr) : 'i420';
        const yPtr = module._iov_decoder_frame_plane(index, 0);
        const uPtr = module._iov_decoder_frame_plane(index, 1);
        const vPtr = module._iov_decoder_frame_plane(index, 2);
        const ySize = module._iov_decoder_frame_plane_size(index, 0);
        const uSize = module._iov_decoder_frame_plane_size(index, 1);
        const vSize = module._iov_decoder_frame_plane_size(index, 2);

        frames.push({
          type: 'video',
          timestamp: module._iov_decoder_frame_timestamp(index),
          width,
          height,
          format,
          planes: {
            y: copyHeapBytes(module, yPtr, ySize),
            u: copyHeapBytes(module, uPtr, uSize),
            v: copyHeapBytes(module, vPtr, vSize)
          }
        });
        continue;
      }

      const audioBuffer = createAudioBuffer(module, index);
      if (audioBuffer) {
        frames.push({
          type: 'audio',
          timestamp: module._iov_decoder_frame_timestamp(index),
          data: audioBuffer
        });
      }
    }

    return frames;
  }

  if (!Module._iov_decoder_decode) {
    return;
  }

  Module.iovDecoder = {
    configure(config) {
      const jsonPtr = stringToNewUTF8(Module, JSON.stringify(config || {}));
      try {
        Module._iov_decoder_configure(jsonPtr);
      } finally {
        Module._free(jsonPtr);
      }
    },
    decode(payload, context) {
      const inputPtr = Module._malloc(payload.byteLength);
      Module.HEAPU8.set(payload, inputPtr);
      const contextPtr = stringToNewUTF8(Module, JSON.stringify(context || {}));

      try {
        const result = Module._iov_decoder_decode(inputPtr, payload.byteLength, contextPtr);
        if (result < 0) {
          throw new Error('iov_decoder_decode failed with code ' + result);
        }
        return collectDecodedFrames(Module);
      } finally {
        Module._free(contextPtr);
        Module._free(inputPtr);
      }
    },
    flush() {
      Module._iov_decoder_flush();
      return collectDecodedFrames(Module);
    },
    close() {
      Module._iov_decoder_close();
    }
  };
})();
