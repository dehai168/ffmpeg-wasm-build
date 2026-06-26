(function () {
  if (typeof Module === 'undefined') {
    return;
  }

  function refreshHeapViews(module) {
    if (module.wasmMemory) {
      module.HEAPU8 = new Uint8Array(module.wasmMemory.buffer);
    }
  }

  function getExport(module, name) {
    const underscored = name.startsWith('_') ? name : `_${name}`;
    const fn = module[underscored];
    return typeof fn === 'function' ? fn : undefined;
  }

  function installBumpAllocator(module) {
    if (!module.__iovBumpPtr) {
      module.__iovBumpPtr = 65536;
    }

    module._malloc = function iovBumpMalloc(size) {
      const aligned = (size + 15) & ~15;
      const pointer = module.__iovBumpPtr;
      module.__iovBumpPtr = pointer + aligned;
      refreshHeapViews(module);
      if (module.HEAPU8 && module.HEAPU8.length < module.__iovBumpPtr && module.wasmMemory) {
        const delta = module.__iovBumpPtr - module.HEAPU8.length;
        module.wasmMemory.grow(Math.ceil(delta / 65536));
        refreshHeapViews(module);
      }
      return pointer;
    };

    module._free = function iovBumpFree() {};
  }

  function bindWasmHeapApi(module) {
    const pairs = [
      ['malloc', 'free'],
      ['iov_wasm_malloc', 'iov_wasm_free']
    ];

    for (let i = 0; i < pairs.length; i += 1) {
      const mallocFn = getExport(module, pairs[i][0]);
      const freeFn = getExport(module, pairs[i][1]);
      if (typeof mallocFn !== 'function' || typeof freeFn !== 'function') {
        continue;
      }

      module._malloc = function iovWasmMalloc(size) {
        return mallocFn(size);
      };
      module._free = function iovWasmFree(ptr) {
        if (ptr) {
          freeFn(ptr);
        }
      };
      return true;
    }

    installBumpAllocator(module);
    return false;
  }

  Module.bindWasmHeapApi = bindWasmHeapApi;
})();
