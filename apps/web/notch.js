// The notch on this page behaves the way it does on the Mac: one black shape that grows for what it
// has to show, two eyes that follow the pointer, and words that light up as they are spoken.
(() => {
  const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const wait = (ms) => new Promise((done) => setTimeout(done, ms));

  class Notch {
    constructor(screen) {
      this.screen = screen;
      this.eyes = screen.querySelector(".eyes");
      this.caption = screen.querySelector(".caption");
      this.run = 0;
    }
    set(state) { this.screen.dataset.state = state; }
    status(text) {
      this.caption.className = "caption status";
      this.caption.replaceChildren(...[...text].map((letter, i) => {
        const span = document.createElement("span");
        span.textContent = letter; span.style.setProperty("--i", i);
        return span;
      }));
    }
    // Words light up at about the pace a voice says them.
    async say(text, run) {
      this.caption.className = "caption";
      const words = text.split(" ").map((word) => {
        const span = document.createElement("span");
        span.className = "w"; span.textContent = word + " ";
        return span;
      });
      this.caption.replaceChildren(...words);
      for (const word of words) {
        if (run !== this.run) return false;
        word.classList.add("on");
        if (!still) await wait(330);
      }
      return run === this.run;
    }
    look(x, y) {
      const box = this.screen.getBoundingClientRect();
      const dx = Math.max(-1, Math.min(1, (x - (box.left + box.width / 2)) / (innerWidth / 2)));
      const dy = Math.max(-1, Math.min(1, (y - box.top) / (innerHeight / 2)));
      this.eyes.style.setProperty("--dx", (dx * 5).toFixed(1) + "px");
      this.eyes.style.setProperty("--dy", (dy * 3).toFixed(1) + "px");
    }
  }

  const notches = [...document.querySelectorAll(".screen[data-ui]")].map((screen) => new Notch(screen));
  if (!still) addEventListener("pointermove", (event) => notches.forEach((notch) => notch.look(event.clientX, event.clientY)), { passive: true });

  // The first screen: name it, say the name, and answer when it asks.
  const demo = notches.find((notch) => notch.screen.id === "demo");
  const controls = document.getElementById("demo-controls");
  if (demo && controls) {
    const field = controls.elements.name;
    const name = () => field.value.trim() || "Jarvis";
    const rename = () => document.querySelectorAll("[data-name]").forEach((node) => { node.textContent = name(); });
    field.addEventListener("input", rename);
    let answer = null;
    demo.screen.querySelectorAll("[data-answer]").forEach((button) => button.addEventListener("click", () => answer?.(button.dataset.answer)));

    const conversation = async () => {
      const run = ++demo.run;
      const alive = () => run === demo.run;
      demo.status("Listening"); demo.set("listening");
      await wait(1900); if (!alive()) return;
      demo.status("Working on it"); demo.set("working");
      await wait(2100); if (!alive()) return;
      demo.set("speaking");
      if (!await demo.say("Okay so the landing page is done. Want me to push it?", run)) return;
      await wait(700); if (!alive()) return;
      demo.set("asking");
      const said = await Promise.race([new Promise((done) => { answer = done; }), wait(9000).then(() => "nothing")]);
      answer = null; if (!alive()) return;
      demo.set("speaking");
      const line = said === "allow" ? "Pushed. That was the easy part." : said === "deny" ? "Okay, leaving it where it is." : "No rush. Say my name when you want it.";
      if (!await demo.say(line, run)) return;
      await wait(1600); if (!alive()) return;
      demo.set("asleep");
      await wait(2200); if (!alive()) return;
      demo.set("awake");
    };
    controls.addEventListener("submit", (event) => { event.preventDefault(); rename(); conversation(); });
  }

  // On a phone each sentence carries its own small screen, already in its state.
  notches.filter((notch) => notch.screen.classList.contains("step-screen")).forEach((notch) => {
    if (notch.screen.dataset.state !== "speaking") notch.status(notch.caption.textContent);
  });

  // How it works: the same shape, in the state the sentence beside it describes.
  const stage = notches.find((notch) => notch.screen.id === "stage");
  const steps = [...document.querySelectorAll(".step")];
  if (stage && steps.length) {
    const show = (step) => {
      if (step.classList.contains("active")) return;
      steps.forEach((other) => other.classList.toggle("active", other === step));
      const run = ++stage.run; const state = step.dataset.step;
      if (state === "listening") { stage.status("Listening"); stage.set("listening"); }
      else if (state === "working") { stage.status("Working on it"); stage.set("working"); }
      else { stage.set("speaking"); stage.say("Two agents are still working. The reviewer finished with three notes.", run); }
    };
    const watcher = new IntersectionObserver((entries) => entries.forEach((entry) => { if (entry.isIntersecting) show(entry.target); }),
      { rootMargin: "-45% 0px -45% 0px" });
    steps.forEach((step) => watcher.observe(step));
    show(steps[0]);
  }

  // Each part of a section arrives once, a moment after the one before it.
  const parts = [...document.querySelectorAll(".reveal")];
  const arrive = new IntersectionObserver((entries) => entries.forEach((entry) => {
    if (!entry.isIntersecting) return;
    entry.target.classList.add("in"); arrive.unobserve(entry.target);
  }), { rootMargin: "0px 0px -12% 0px" });
  // A showcase row has no box of its own, so its picture is watched for it.
  document.querySelectorAll(".state").forEach((state) => {
    [...state.children].forEach((child, i) => child.style.setProperty("--n", i));
    const seen = new IntersectionObserver((entries) => entries.forEach((entry) => {
      if (entry.isIntersecting) { state.classList.add("in"); seen.disconnect(); }
    }), { rootMargin: "0px 0px -12% 0px" });
    seen.observe(state.querySelector("img"));
  });
  parts.forEach((part) => {
    const siblings = [...part.parentElement.children].filter((node) => node.classList.contains("reveal"));
    part.style.setProperty("--n", siblings.indexOf(part));
    arrive.observe(part);
  });
  document.querySelectorAll("dl > div").forEach((row) => row.style.setProperty("--n", [...row.parentElement.children].indexOf(row)));
})();
