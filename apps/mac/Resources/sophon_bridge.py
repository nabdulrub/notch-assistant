"""The bridge between the app and a Sophon-Realtime model running on this Mac.

Sophon listens and talks by itself: it decides when the user has finished, can be talked over, and makes small talk. This
bridge adds the two things the app needs on top of that:

  * a hand-off. The model is told to answer a real request with the word HANDOFF and what was asked. That reply is never
    spoken; it goes to the app, which passes it to the Claude Code session.
  * a way to stay out of it. Talk in the room that is not meant for it is answered with the word SILENT, which is
    never spoken either.
  * a way to speak words it is given. What the session answers is said in the model's voice, word for word.

It serves one WebSocket on this Mac only (127.0.0.1). Binary frames are PCM16 mono audio at 24 kHz in both directions.
Text frames are JSON:

  from the app   {"type": "say", "text": ..., "id": ...}   speak this
                 {"type": "interrupt"}                    stop talking now
  to the app     {"type": "ready"}
                 {"type": "handoff", "id": ..., "request": ...}
                 {"type": "goodbye"}                      the user sent it away
                 {"type": "voice_text", "text": ...}      what it is saying, as it grows
                 {"type": "interrupt"}                    stop playing: drop the audio not yet played
                 {"type": "cut", "said": ...}             the user cut in; this much had been heard
                 {"type": "silent"}                       it heard a turn and found nothing in it to answer
                 {"type": "error", "message": ...}

It needs Sophon-Realtime's Mac build installed (github.com/adventists-ai/sophon-realtime, mac/install.sh) and is run
with that install's own Python. JarvisBrain.reply and JarvisBrain._talk follow Brain.reply in its mac/engine.py
(Copyright 2026 Adventists.ai, Apache License 2.0), changed so that a reply can be recognised as a hand-off before any
of it is spoken, and so that given text can be spoken without the model writing it.
"""
import argparse, asyncio, base64, collections, json, os, re, sys, threading, time, uuid

ap = argparse.ArgumentParser()
ap.add_argument("--app", required=True, help="the folder that holds Sophon's engine.py")
ap.add_argument("--root", required=True, help="the folder that holds the model")
ap.add_argument("--prompt", required=True, help='a JSON file with the system prompt: {"en": "..."}')
ap.add_argument("--port", type=int, default=8791)
ap.add_argument("--voice", default="chelsie")
ap.add_argument("--parent", type=int, default=0, help="exit when this process is gone")
ap.add_argument("--speaker-model", help="WeSpeaker's voxceleb_resnet34_LM.onnx; default: models/speaker/ next to --app. Without the file, every voice is heard")
ap.add_argument("--speaker-threshold", type=float, default=0.4, help="likeness to the owner's voice below which speech is someone else's")
ap.add_argument("--any-voice", action="store_true", help="listen to everyone, even when the speaker model is there")
a = ap.parse_args()

sys.path.append(a.app)
import numpy as np, websockets, mlx.core as mx
from scipy.signal import resample_poly
from mlx_lm import stream_generate
from mlx_lm.sample_utils import make_sampler
from engine import Brain, Session, SR, LEAD, STREAM_S, MAX_REPLY_TOK, OWNER_N, tag_clean, resample

FR = 320                      # the engine takes 20 ms frames at 16 kHz
RATE = 24000                  # audio on the wire, both directions
HANDOFF, GOODBYE, SILENT = "HANDOFF", "GOODBYE", "SILENT"
CUT = "……（被用户打断）"        # the engine's own mark for a reply the user cut off


def control(text):
    """Which control word a reply is, if it is one. The model is told to write nothing else in such a reply."""
    t = text.strip().lstrip("\"'*[(").upper()
    return "handoff" if t.startswith(HANDOFF) else "goodbye" if t.startswith(GOODBYE) else "silent" if t.startswith(SILENT) else None


# The model saying it could not hear, in the ways it says it. It hears the whole room, and a small model
# answers talk it cannot make out with this instead of staying out of it.
UNHEARD = re.compile(
    r"\b(?:can(?:no|')?t|could ?n[o']t|did ?n[o']t|unable to|not sure i|having trouble|hard to)\b[^.?!]{0,24}"
    r"\b(?:hear|hearing|catch|make out|got that|get that|understand|understanding)\b"
    r"|\bspeak up\b|\bspeak (?:a little |a bit )?louder\b|\b(?:say|repeat) that again\b")
UNHEARD_LEAD = 48             # characters of a reply read before it is spoken, to tell
OWNER_MIN_S = 1.0             # less speech than this with the name in it is too little to learn a voice from


def speech_in(x, frame=320, floor=0.012):
    """The stretch of x (16 kHz) from its first loud 20 ms to its last, or None when too little of it is speech to learn
    a voice from. The app sends the quiet before and after the name as well, and a voice is not learned from quiet."""
    x = np.asarray(x, np.float32); n = len(x) // frame
    if n == 0: return None
    loud = np.flatnonzero(np.sqrt(np.mean(np.square(x[: n * frame].reshape(n, frame)), axis=1)) > floor)
    if len(loud) * frame < OWNER_MIN_S * 16000: return None
    return x[loud[0] * frame: (loud[-1] + 1) * frame]


def unheard(text):
    """Whether a reply is the model asking to be spoken to more clearly. Such a reply is never worth saying."""
    return bool(UNHEARD.search(text.lower().replace("\u2019", "'")))


# The model filling the air. It cannot do anything itself, so a reply of its own that opens with an apology
# or with what it cannot do is a request it should have handed over, and "I'm listening" is it answering a
# sound that asked nothing. A hello or a "yes, I'm here" does not open this way.
STALLING = re.compile(
    r"^(?:(?:oh|ah|um|uh|well|hmm|okay|ok)\b[,.!]?\s+)?"
    r"(?:i'?m (?:so |really |very )?sorry\b|i am (?:so |really |very )?sorry\b|sorry\b|i apologi[sz]e\b"
    r"|i can(?:no|')?t\b|i (?:am|'m) (?:not able|unable)\b|i do ?n[o']t have\b"
    r"|i(?:'m| am) (?:still |just |here,? )?listening\b|i can hear (?:you're|you are|that you)\b)")


def stalling(text):
    """Whether a reply of the model's own opens as an apology, a refusal or "I'm listening"."""
    t = re.sub(r"^(?:\s|\[[^\]]*\]|[\"'*(.,-])+", "", text.lower().replace("\u2019", "'"))
    return bool(STALLING.match(t))


def request_of(text):
    """What was asked for, out of 'HANDOFF: check how the release is going.'"""
    t = text[text.upper().find(HANDOFF) + len(HANDOFF):]
    return t.lstrip(" :-,.").strip()


class JarvisBrain(Brain):
    def warmup(self):
        # MLX ties what it has not computed yet to the thread that made it. The engine's own warm-up reply settles
        # these as a side effect of speaking, but here that reply can be a control word, with nothing spoken.
        mx.eval(self.role, self.bos, self.eos, self.pad, self.codec)
        super().warmup()
        self.speak("Okay.", lambda x: None, lambda: False)

    def reply(self, history, user, emit, cancelled, max_tok=MAX_REPLY_TOK, said="", on_text=None):
        msgs, audios = self._conv(history)
        msgs.append({"role": "user", "content": "<|audio|>"}); audios.append(user)
        ids, E, sig = self._layout(msgs, audios)
        if said:
            t = self.tok.encode(said, add_special_tokens=False); ids = ids + t; sig = sig + t
            E = mx.concatenate([E, self.lm.model.embed_tokens(mx.array(t))])
        self._prefill(ids, E, sig, len(ids) - 1)
        gen = stream_generate(self.lm, self.tok, mx.array(ids[-1:]), input_embeddings=E[-1:], prompt_cache=self.cache, max_tokens=max_tok,
                              sampler=make_sampler(temp=0.4, top_p=0.9))
        st = {"raw": "", "clean": "", "sent": 0, "buf": [], "done": False, "closed": False, "spoken": False, "opened": False, "shown": "", "ntok": 0,
              "calls": 0}
        t0 = time.time(); self.timing = {}; self.dropped = None

        def pull():
            fin = False
            try:
                r = next(gen); st["raw"] += r.text; st["ntok"] += 1
                if st["ntok"] == 1: self.timing["tok1"] = round(time.time() - t0, 3)
            except StopIteration:
                fin = True
            txt = tag_clean(st["raw"], fin).lstrip(); st["clean"] = txt
            if not st["closed"]:
                # Once it is talking, a hand-off that turns up mid-reply ends the spoken part there.
                at = txt.upper().find(HANDOFF) if st["spoken"] or st["opened"] else -1
                say = txt if at < 0 else txt[:at]
                tid = self.tok.encode(say, add_special_tokens=False) if say else []
                stable = tid if fin or at >= 0 else tid[:-1]
                if len(stable) > st["sent"]:
                    st["buf"] += [self.te([t]) for t in stable[st["sent"]:]]; st["sent"] = len(stable)
                if fin or at >= 0: st["buf"].append(self.eos); st["closed"] = True
                if st["spoken"] and on_text is not None and say != st["shown"]: st["shown"] = say; on_text(say)
            if fin: st["done"] = True

        # Enough of the reply to tell a control word from something to say.
        while not st["done"] and len(st["raw"].strip()) < len(HANDOFF) + 1 and not cancelled(): pull()
        if not said and control(st["raw"]):
            while not st["done"] and not cancelled(): pull()
            self.sig += [("gen", i) for i in range(st["ntok"])]
            return st["clean"] or st["raw"], None
        # A little more of it before a word is spoken: a reply that says it could not hear, or that only
        # fills the air, is dropped, and goes down as having stayed out of it.
        st["opened"] = True
        while not st["done"] and len(st["raw"].strip()) < UNHEARD_LEAD and not cancelled(): pull()
        if not said and (unheard(st["clean"] or st["raw"]) or stalling(st["clean"] or st["raw"])):
            while not st["done"] and not cancelled(): pull()
            self.sig += [("gen", i) for i in range(st["ntok"])]
            self.dropped = st["clean"] or st["raw"]
            return SILENT, None
        st["spoken"] = True
        while not st["done"] and len(st["buf"]) < LEAD:
            if cancelled(): break
            pull()
        self.timing["lead"] = round(time.time() - t0, 3)
        out = self._talk(st, pull, emit, cancelled)
        while not st["done"] and not cancelled(): pull()       # finish the text for the history even if the talker stopped early
        self.sig += [("gen", i) for i in range(st["ntok"])]
        return st["clean"] or st["raw"], (np.concatenate(out) if out else None)

    def speak(self, text, emit, cancelled):
        """Says the given words in the model's voice. The thinker is not involved."""
        tid = self.tok.encode(text, add_special_tokens=False)
        if not tid: return None
        st = {"buf": [self.te([t]) for t in tid] + [self.eos], "done": True, "calls": 0}
        out = self._talk(st, lambda: None, emit, cancelled)
        return np.concatenate(out) if out else None

    def _talk(self, st, pull, emit, cancelled):
        out = []
        if not st["buf"] or cancelled(): return out
        first = st["buf"].pop(0); brain = self

        class Trail:
            @property
            def shape(s):
                st["calls"] += 1
                if cancelled(): raise KeyboardInterrupt
                if not st["done"] and st["calls"] % 2 == 0: pull()
                while not st["done"] and len(st["buf"]) <= st.get("used", 0):   # never let the talker run out of text mid-reply
                    if cancelled(): raise KeyboardInterrupt
                    pull()
                return (1, len(st["buf"]), brain.pad.shape[-1])

            def __getitem__(s, k):
                st["used"] = k[1].start + 1; return st["buf"][k[1].start]

        pre = mx.concatenate([self.role, mx.concatenate([mx.broadcast_to(self.pad, (1, 5, self.pad.shape[-1])), self.bos], 1) + self.codec[:, :-1],
                              first + self.codec[:, -1:]], 1)
        self.tts._prepare_generation_inputs = lambda *a, **k: (pre, Trail(), self.pad)
        try:
            for r in self.tts.generate(text="x", lang_code="chinese", stream=True, streaming_interval=STREAM_S, temperature=0.7, max_tokens=4000):
                if cancelled(): break
                x = np.array(r.audio, dtype=np.float32); out.append(x); emit(x)
        except KeyboardInterrupt:
            pass
        return out


class JarvisSession(Session):
    """One conversation that outlives its connections, so what was said before the app last hung up is still known."""

    def __init__(self, brain, speaker=None, speaker_thr=0.4):
        self.note = lambda e: None
        self.hushed = 0.0
        super().__init__(brain, lambda x: None, log=self._log, speaker=speaker, speaker_thr=speaker_thr)

    def _speaker_worker(self):
        """Whether the speech in progress is the owner's. Someone else's is dropped, and what it cut off is put back.

        The engine takes the first voice it hears for the owner. Here that could be anyone: this conversation outlives its
        connections, and one may open with the session speaking to a room. So the owner is only ever the voice that said the
        name (see enrol), and until one is known every voice is heard."""
        while True:
            uid, audio = self.spk_q.get()
            try:
                e = self.spk.embed(audio)
                if e is None: continue
                with self.lock:
                    if uid != self.uid or self.owner is None: continue
                    score = float(e @ (self.owner / np.linalg.norm(self.owner))); mine = score >= self.spk_thr
                    print(f"voice: {score:.2f}, {'the owner' if mine else 'someone else'}", flush=True)
                    if mine:
                        if self.owner_n < OWNER_N: self.owner = self.owner + e; self.owner_n += 1
                    else:
                        self.note({"type": "bystander", "score": round(score, 2)}); self._bystander()
            except Exception as ex:
                print(f"voice check failed: {ex!r}", flush=True)

    def enrol(self, x):
        """Learns the owner's voice from the speech the name was heard in. A voice that is not the known owner's takes
        over: whoever calls it by name is who it listens to. Too little speech teaches nothing, and changes nothing."""
        x = speech_in(x) if self.spk is not None else None
        if x is None: return
        try: e = self.spk.embed(x)
        except Exception as ex: print(f"voice check failed: {ex!r}", flush=True); return
        if e is None: return
        with self.lock:
            if self.owner is not None:
                score = float(e @ (self.owner / np.linalg.norm(self.owner)))
                if score >= self.spk_thr:
                    if self.owner_n < OWNER_N: self.owner = self.owner + e; self.owner_n += 1
                    print(f"owner's voice: the same one said the name ({score:.2f})", flush=True); return
                print(f"owner's voice: a new one said the name ({score:.2f})", flush=True)
            else:
                print("owner's voice: learned", flush=True)
            self.owner = e.copy(); self.owner_n = 1; self.bystander = False

    def attach(self, play, note):
        with self.lock: self.play = play; self.note = note

    def detach(self):
        with self.lock:
            if self.reply is not None: self.reply["cancel"] = True
            self.play = lambda x: None; self.note = lambda e: None; self.hushed = time.time(); self.cut = None; self._reset()

    def _log(self, m):
        e = json.loads(m); ev = e.get("ev")
        if ev == "barge_in": self.note({"type": "cut", "said": e.get("said", "")})
        elif ev == "error": self.note({"type": "error", "message": e.get("err", "")}); print(m, flush=True)

    def _commit(self, r, a16, text):
        # What it was given to say is kept out of what the model remembers. With the session's answers in its own
        # history it starts answering questions about the user's work itself, and it makes those answers up.
        if "say" in r: r["entry"] = {"user": r["user"], "ukey": r["ukey"], "a_audio": None, "akey": "", "a_text": text}
        else: super()._commit(r, a16, text)

    def say(self, text, ident=None):
        r = {"say": text, "id": ident, "text": text, "a16": None, "user": np.zeros(int(0.3 * SR), np.float32), "ukey": uuid.uuid4().hex,
             "cancel": False, "done": False, "gen_s": 0.0, "t_sil": time.time(), "t_out": None, "sgen": self.sgen, "queued": time.time()}
        self.jobs.put(("reply", r))

    def hush(self):
        """Stop talking, and forget what was still waiting to be said."""
        with self.lock:
            self.hushed = time.time(); r = self.reply
            if r is not None: r["cancel"] = True
            self.play(None)

    def _emit(self, r):
        def emit(x):
            if r["cancel"]: return
            if r["t_out"] is None: r["t_out"] = time.time()
            r["gen_s"] += len(x) / 24000; self.play(x)
        return emit

    def _run_reply(self, r):
        if "say" in r: return self._run_say(r)
        t0 = time.time()
        with self.lock: r["started"] = True
        text, a24 = self.b.reply(self.history, (r["ukey"], r["user"]), self._emit(r), lambda: r["cancel"],
                                 on_text=lambda t: None if r["cancel"] else self.note({"type": "voice_text", "text": t}))
        handed = HANDOFF in text.upper(); kind = control(text) or ("handoff" if handed else None)
        if self.b.dropped and not r["cancel"]: self.note({"type": "unheard", "text": self.b.dropped})
        r["text"] = text; r["a16"] = resample(a24, 24000, SR) if a24 is not None else None; r["done"] = True
        with self.lock:
            if not r["cancel"]:
                self._commit(r, r["a16"], text); self.last_said = "" if kind else text
                # Nothing was said, so there is nothing for the user to cut off or pick up again.
                if a24 is None and self.reply is r: self.reply = None
            elif r.get("cut") is not None and r.get("entry") is None:      # cut in on while still generating: keep what was actually heard
                played, frac = r["cut"]; said = text[: int(len(text) * frac)]
                a16 = r["a16"][: int(played * SR)] if r["a16"] is not None and played > 0.5 else None
                if said or a16 is not None: self._commit(r, a16, said + CUT)
                self.last_said = said
        if not r["cancel"] or a24 is None:
            if kind == "handoff" and request_of(text): self.note({"type": "handoff", "id": uuid.uuid4().hex[:12], "request": request_of(text)})
            elif kind == "goodbye": self.note({"type": "goodbye"})
            # Said so the app can tell a noise from a request: a line that a noise cut off is picked back up.
            elif kind == "silent": self.note({"type": "silent"})
        self.ev("reply_done", text=text, audio_s=round(r["gen_s"], 2), cancelled=r["cancel"], sec=round(time.time() - t0, 2), hist=len(self.history))

    def _run_say(self, r):
        with self.lock:
            if r["queued"] < self.hushed: return
            # Someone mid-sentence is heard out first; the turn checks need this thread in the meantime.
            wait = (self.speech_ms > 0 or self.pending) and time.time() - r["queued"] < 8
            if not wait: r["started"] = True; self.reply = r; self.prev_user = None; self.t_reply = time.time()
        if wait:
            time.sleep(0.05); self.jobs.put(("reply", r)); return
        self.note({"type": "voice_text", "text": r["say"], "given": True})
        self.b.speak(r["say"], self._emit(r), lambda: r["cancel"]); r["done"] = True
        with self.lock:
            if not r["cancel"]:
                self._commit(r, None, r["say"]); self.last_said = r["say"]
            elif r.get("cut") is not None and r.get("entry") is None:
                said = r["say"][: int(len(r["say"]) * r["cut"][1])]
                if said: self._commit(r, None, said + CUT)
                self.last_said = said
        self.ev("say_done", cancelled=r["cancel"], audio_s=round(r["gen_s"], 2))

    def _run_resume(self, r):
        """After "mm-hmm" over something it was given to say, the rest of it is said; the model does not make up an ending."""
        r0 = r["resume"]
        if "say" not in r0: return super()._run_resume(r)
        r["started"] = True; e = r0["entry"]; said = e["a_text"].replace(CUT, "")
        said = said[: said.rfind(" ") + 1]; rest = r0["say"][len(said):].strip()
        if rest:
            self.note({"type": "voice_text", "text": rest, "given": True})
            self.b.speak(rest, self._emit(r), lambda: r["cancel"])
        r["text"] = rest; r["done"] = True
        with self.lock:
            if any(h is e for h in self.history):
                full = said + rest
                if r["cancel"] and r.get("cut") is not None: full = said + rest[: int(len(rest) * r["cut"][1])] + CUT
                e["a_text"] = full; e["a_audio"] = None; r["entry"] = e
        self.ev("say_done", resumed=True, cancelled=r["cancel"], audio_s=round(r["gen_s"], 2))


busy = False


async def handle(ws):
    global busy
    if busy:
        await ws.close(1013, "one conversation at a time"); return
    busy = True
    loop = asyncio.get_running_loop(); out = asyncio.Queue()
    played = collections.deque(); ends = [0.0]          # what the app is playing and when, so its echo is not taken for the user

    def play(x): loop.call_soon_threadsafe(out.put_nowait, None if x is None else np.asarray(x, np.float32))
    def note(e): loop.call_soon_threadsafe(out.put_nowait, json.dumps(e, ensure_ascii=False))

    async def send():
        while True:
            m = await out.get()
            if m is None:
                played.clear(); ends[0] = 0.0; await ws.send(json.dumps({"type": "interrupt"}))
            elif isinstance(m, str):
                await ws.send(m)
            else:
                await ws.send((np.clip(m, -1.0, 1.0) * 32767.0).astype("<i2").tobytes())
                start = max(ends[0], loop.time()); ends[0] = start + len(m) / RATE
                ref = resample_poly(m, 2, 3).astype(np.float32)
                for i in range(0, len(ref), FR): played.append((start + i / SR, ref[i:i + FR]))

    sess.attach(play, note); sender = asyncio.ensure_future(send())
    buf = np.zeros(0, np.float32)
    try:
        await ws.send(json.dumps({"type": "ready"}))
        async for m in ws:
            if isinstance(m, str):
                try: e = json.loads(m)
                except ValueError: continue
                if not isinstance(e, dict): continue
                if e.get("type") == "say" and str(e.get("text") or "").strip(): sess.say(str(e["text"]).strip(), e.get("id"))
                elif e.get("type") == "interrupt": sess.hush()
                elif e.get("type") == "owner":
                    # The speech the name was heard in, as the app sends its audio: 24 kHz, 16-bit.
                    try: pcm = base64.b64decode(str(e.get("pcm") or ""))
                    except ValueError: continue
                    heard = np.frombuffer(pcm[: len(pcm) // 2 * 2], "<i2").astype(np.float32) / 32768.0
                    sess.enrol(resample_poly(heard, 2, 3).astype(np.float32))
                continue
            x = np.frombuffer(m[: len(m) // 2 * 2], "<i2").astype(np.float32) / 32768.0
            buf = np.concatenate([buf, resample_poly(x, 2, 3).astype(np.float32)])
            while len(buf) >= FR:
                f, buf = buf[:FR], buf[FR:]
                now = loop.time(); far = np.zeros(FR, np.float32)
                while played and played[0][0] + 0.02 <= now: played.popleft()
                if played and played[0][0] <= now: far[: len(played[0][1])] = played[0][1]
                sess.feed(f, far)
    except websockets.ConnectionClosed:
        pass
    finally:
        sess.detach(); sender.cancel(); busy = False


async def main():
    async with websockets.serve(handle, "127.0.0.1", a.port, max_size=1 << 22):
        print(f"ready on ws://127.0.0.1:{a.port}", flush=True)
        await asyncio.Future()


def watch_parent():
    while True:
        time.sleep(2)
        if os.getppid() != a.parent: os._exit(0)


if a.parent: threading.Thread(target=watch_parent, daemon=True).start()
print("loading the model", flush=True)
brain = JarvisBrain(a.root, lang="en", voice=a.voice, sys_prompt=a.prompt); brain.warmup()
speaker = None
speaker_model = a.speaker_model or os.path.join(os.path.dirname(os.path.abspath(a.app)), "models", "speaker", "voxceleb_resnet34_LM.onnx")
if a.any_voice:
    print("owner's voice: off, every voice is heard", flush=True)
elif not os.path.exists(speaker_model):
    print(f"owner's voice: off, no speaker model at {speaker_model}", flush=True)
else:
    try:
        from speaker import Speaker
        speaker = Speaker(speaker_model); print("owner's voice: on, learned from whoever says the name", flush=True)
    except Exception as ex:
        print(f"owner's voice: off ({ex!r})", flush=True)
sess = JarvisSession(brain, speaker, a.speaker_threshold)
try:
    asyncio.run(main())
except KeyboardInterrupt:
    os._exit(0)          # skip interpreter teardown (MLX streams owned by the worker thread would complain)
