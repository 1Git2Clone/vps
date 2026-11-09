"""Apply narrowly scoped CPU fixes to the writable, pinned upstream copy."""

from pathlib import Path


def update(path, replacements):
    original = path.read_text()
    content = original
    for before, after in replacements:
        if after in content:
            continue
        if before in content:
            if content.count(before) != 1:
                raise RuntimeError(f"Ambiguous CPU compatibility edit in {path}")
            content = content.replace(before, after, 1)
        else:
            raise RuntimeError(f"Unrecognized upstream code in {path}; review CPU fixes")
    if content != original:
        temporary = path.with_suffix(path.suffix + ".cpu-tmp")
        temporary.write_text(content)
        temporary.replace(path)


update(
    Path("speech/api.py"),
    [
        ("_TTS_SAY_TIMEOUT_S = 25", "_TTS_SAY_TIMEOUT_S = 120"),
        (
            "    TTS_FIRST_AUDIO_TIMEOUT_MS = 2000  # 发出 TTS 请求后 2s 内没首音频 -> 视为已到达，直接 protect",
            "    TTS_FIRST_AUDIO_TIMEOUT_MS = 120000  # CPU synthesis can take tens of seconds.",
        ),
        (
            "    TTS_INFLIGHT_TIMEOUT_MS = 5000  # 任一句 TTS 5s 内没回 audio_ready/error -> 跳过排空队列，防卡死",
            "    TTS_INFLIGHT_TIMEOUT_MS = 120000  # Preserve queued speech while CPU synthesis runs.",
        ),
    ],
)
update(
    Path("ui/use.js"),
    [
        (
            "    let audioOK = false, pendingLine = null;",
            "    let audioOK = false, pendingLine = null, voicePending = false;",
        ),
        (
            "    async function speak(text, emotion, raw) {\n      if (!text) return false;",
            "    async function speak(text, emotion, raw) {\n"
            "      if (!text || voicePending) return false;\n      voicePending = true;",
        ),
        (
            '        const r = await postAction("/api/tts_say", "tts-say", line);',
            '        if (face.badge) { face.badge.textContent = "Preparing voice…"; face.badge.hidden = false; }\n'
            '        const r = await postAction("/api/tts_say", "tts-say", line);',
        ),
        (
            "        return false;      // TTS down: the text is still there; the health step will say so\n      }\n    }",
            "        return false;      // TTS down: the text is still there; the health step will say so\n"
            "      } finally {\n        voicePending = false;\n"
            '        if (face.badge) face.badge.textContent = "Click to hear her";\n      }\n    }',
        ),
        (
            '    box.addEventListener("pointerdown", () => { if (pendingLine)',
            '    box.addEventListener("pointerdown", (event) => {\n'
            '      if (event.target.closest("button") && !event.target.closest(".portrait")) return;\n'
            '      if (pendingLine)',
        ),
    ],
)
