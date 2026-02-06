// Emscripten JS library for WASM profiling markers.
//
// Enabled via `zig build -Dwasm=true -Denable_wasm_perf_markers=true`.
//
// This maps Zig `utils/profiler.zig` zones to `performance.mark/measure` so they
// show up in Chrome/Firefox performance traces with the same zone names.

var $ZscPerf = {
  nextId: 1,
  active: Object.create(null),
};

mergeInto(LibraryManager.library, {
  zsc_perf_zone_begin: function (namePtr) {
    if (typeof performance === "undefined" || !performance.mark) return 0;
    var name = UTF8ToString(namePtr);
    var id = ($ZscPerf.nextId++ | 0);
    var start = "zsc:" + name + "#" + id + ":start";
    var end = "zsc:" + name + "#" + id + ":end";
    $ZscPerf.active[id] = { name: name, start: start, end: end };
    performance.mark(start);
    return id;
  },

  zsc_perf_zone_end: function (id) {
    if (!id) return;
    var entry = $ZscPerf.active[id];
    if (!entry) return;
    delete $ZscPerf.active[id];
    if (typeof performance === "undefined" || !performance.mark || !performance.measure) return;
    performance.mark(entry.end);
    performance.measure("zsc:" + entry.name, entry.start, entry.end);
    if (performance.clearMarks) {
      performance.clearMarks(entry.start);
      performance.clearMarks(entry.end);
    }
  },

  zsc_perf_frame_mark: function () {
    if (typeof performance === "undefined" || !performance.mark) return;
    performance.mark("zsc:frame");
  },
});

