// Evaluated in the page by N64Recomp-browser's tools/play_page.mjs (tools/play_plan.json) and tools/record_shaders.mjs
// (tools/shader_plan.json), with n64r, RDRAM words at N64 addresses: where the game is, read as src/main/fps_controls.cpp
// reads it (docs/RAM_NOTES.md has the rest).
//
//   mode()  the game's top-level mode (0x801407B8): 0-4 the boot screens and the title, 8 the front end (the menus),
//       20 the fade between modes, anything else a match.
//   paused()  a match is paused (0x801407D4).
//   screen()  the front end's screen (func_00299898's answer: *0x80144E18, or the top of the screen stack at
//       *0x80144E00 when that's -1): 3 the main menu, 0x1A how many players, 7 character select, 8 loadout select,
//       0x14 level select, 0x15 the match's options, 0x19 the Rumble Pak notice; -1 none.
//   inMatch()  a match is on and not paused, its player there (the player pointer at 0x8013EF84).
//   matchTime()  the match's clock, the float at 0x801407F4 (counting down; 0 with no time limit).
//   state()  all of them, for the console.
//   untilScreen(n, ms), untilMatch(ms)  resolve once screen() is n or a match is on, or after ms, with what was found.
(() => {
  const s32 = (a) => n64r(a) | 0;
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const valid = (p) => p >= 0x80000000 && p < 0x80800000;

  window.mode = () => s32(0x801407B8);
  window.paused = () => s32(0x801407D4) !== 0;
  window.screen = () => {
    const screen = s32(0x80144E18);
    if (screen >= 0) return screen;
    const stack = n64r(0x80144E00);
    if (!valid(stack)) return -1;
    const top = s32(stack + 4), entries = n64r(stack + 0xC);
    if (top < 0 || !valid(entries)) return -1;
    return s32(entries + 28 * top + 4);
  };
  window.inMatch = () => {
    const m = mode();
    return m > 4 && m !== 8 && m !== 20 && !paused() && valid(n64r(0x8013EF84));
  };
  const f32 = new Float32Array(1), u32 = new Uint32Array(f32.buffer);
  window.matchTime = () => { u32[0] = n64r(0x801407F4); return f32[0]; };
  window.state = () => `mode ${mode()} screen 0x${screen().toString(16)} paused ${paused()} inMatch ${inMatch()}` +
    ` matchTime ${matchTime().toFixed(1)}`;
  const until = async (test, ms) => {
    const end = Date.now() + ms;
    while (!test() && Date.now() < end) await sleep(50);
    return (test() ? 'there: ' : 'not there: ') + state();
  };
  window.untilScreen = (n, ms) => until(() => mode() === 8 && screen() === n, ms);
  window.untilMatch = (ms) => until(inMatch, ms);
})();
