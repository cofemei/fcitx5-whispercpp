"""Minimal D-Bus service for fcitx5 whispercpp input method."""

from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass, field

import numpy as np
import sounddevice as sd
from gi.repository import GLib
from pydbus import SessionBus
from pydbus.generic import signal

from pywhispercpp.model import Model

logger = logging.getLogger(__name__)

DBUS_NAME = "org.fcitx.Fcitx5.WhisperCpp"
DBUS_PATH = "/org/fcitx/Fcitx5/WhisperCpp"

DBUS_INTERFACE = """
<node>
  <interface name='org.fcitx.Fcitx5.WhisperCpp'>
    <method name='StartRecording'></method>
    <method name='StopRecording'></method>
    <method name='GetStatus'>
      <arg type='s' name='status' direction='out'/>
    </method>
    <signal name='TranscriptionComplete'>
      <arg type='s' name='text'/>
      <arg type='i' name='segment_num'/>
    </signal>
    <signal name='TranscriptionDelta'>
      <arg type='s' name='text'/>
    </signal>
    <signal name='RecordingStarted'></signal>
    <signal name='RecordingStopped'></signal>
    <signal name='Error'>
      <arg type='s' name='message'/>
    </signal>
  </interface>
</node>
"""

# Keep a process-lifetime reference to SessionBus, otherwise the name owner may
# get dropped after GC and systemd(Type=dbus) will terminate the daemon.
_SESSION_BUS: SessionBus | None = None


@dataclass
class Recorder:
    samplerate: int = 16000
    channels: int = 1
    blocksize: int = 1600
    _chunks: list[np.ndarray] = field(default_factory=list)
    _lock: threading.Lock = field(default_factory=threading.Lock)
    _stream: sd.InputStream | None = None

    def start(self) -> None:
        if self._stream is not None:
            return

        self._chunks = []

        def callback(indata: np.ndarray, frames: int, time, status) -> None:
            if status:
                logger.warning("Audio status: %s", status)
            with self._lock:
                self._chunks.append(indata.copy().reshape(-1))

        self._stream = sd.InputStream(
            samplerate=self.samplerate,
            channels=self.channels,
            dtype="float32",
            blocksize=self.blocksize,
            callback=callback,
        )
        self._stream.start()

    def _collect_audio(self) -> np.ndarray:
        """Concatenate buffered chunks; caller must hold _lock."""
        if not self._chunks:
            return np.array([], dtype=np.float32)
        return np.concatenate(self._chunks)

    def stop(self) -> np.ndarray:
        if self._stream is not None:
            self._stream.stop()
            self._stream.close()
            self._stream = None

        with self._lock:
            audio = self._collect_audio()
            self._chunks.clear()
            return audio

    def snapshot(self) -> np.ndarray:
        with self._lock:
            return self._collect_audio()


class WhisperCppService:
    dbus = DBUS_INTERFACE

    TranscriptionComplete = signal()
    TranscriptionDelta = signal()
    RecordingStarted = signal()
    RecordingStopped = signal()
    Error = signal()

    def __init__(
        self, model: str, language: str, device: int | None, prompt: str | None
    ):
        self._language = language
        self._device = device
        self._prompt = prompt
        self._recording = False
        self._busy = False
        self._recorder = Recorder()
        self._model = Model(model)
        self._model_lock = threading.Lock()
        self._stream_stop_event = threading.Event()
        self._stream_thread: threading.Thread | None = None
        self._last_delta_text = ""
        logger.info("Loaded whispercpp model: %s", model)

    @staticmethod
    def _segments_to_text(segments) -> str:
        return "".join(getattr(s, "text", str(s)) for s in segments).strip()

    def _transcribe_kwargs(self) -> dict[str, object]:
        kwargs: dict[str, object] = {
            "language": self._language,
            "print_progress": False,
        }
        if self._prompt:
            kwargs["initial_prompt"] = self._prompt
        return kwargs

    def _transcribe_segments(self, audio: np.ndarray):
        with self._model_lock:
            return self._model.transcribe(
                audio,
                **self._transcribe_kwargs(),
            )

    def StartRecording(self) -> None:
        if self._recording or self._busy:
            return

        try:
            if self._device is not None:
                sd.default.device = (self._device, self._device)
            self._recorder.start()
            self._recording = True
            self._last_delta_text = ""
            self._stream_stop_event.clear()
            self._stream_thread = threading.Thread(
                target=self._stream_transcribe_loop, daemon=True
            )
            self._stream_thread.start()
            self.RecordingStarted()
            logger.info("Recording started")
        except Exception as exc:
            logger.exception("Failed to start recording")
            self.Error(str(exc))

    def StopRecording(self) -> None:
        if not self._recording:
            return

        self._recording = False
        self._stream_stop_event.set()
        if self._stream_thread is not None:
            # Ensure streaming transcription fully exits before final transcription
            # so we never call whisper model inference concurrently.
            self._stream_thread.join()
            self._stream_thread = None
        self.RecordingStopped()
        audio = self._recorder.stop()

        if audio.size == 0:
            logger.info("No audio captured")
            return

        self._busy = True
        thread = threading.Thread(target=self._transcribe, args=(audio,), daemon=True)
        thread.start()

    def GetStatus(self) -> str:
        if self._recording:
            return "recording"
        if self._busy:
            return "busy"
        return "idle"

    def _transcribe(self, audio: np.ndarray) -> None:
        try:
            segments = self._transcribe_segments(audio)
            text = self._segments_to_text(segments)
            if text:
                logger.info("Committed text length=%d", len(text))
                GLib.idle_add(self.TranscriptionComplete, text, 0)
        except Exception as exc:
            logger.exception("Transcription failed")
            self.Error(str(exc))
        finally:
            self._busy = False

    def _stream_transcribe_loop(self) -> None:
        # Best-effort incremental decoding while recording.
        while not self._stream_stop_event.is_set():
            time.sleep(0.8)
            if self._busy:
                continue

            audio = self._recorder.snapshot()
            if audio.size < self._recorder.samplerate:
                continue

            try:
                segments = self._transcribe_segments(audio)
                text = self._segments_to_text(segments)
                if text and text != self._last_delta_text:
                    self._last_delta_text = text
                    logger.info(
                        "Emit TranscriptionDelta len=%d (stream loop)", len(text)
                    )
                    GLib.idle_add(self.TranscriptionDelta, text)
            except Exception:
                # Streaming updates are best-effort; final transcription still runs at stop.
                logger.debug("Streaming partial transcription failed", exc_info=True)


def start_dbus_service(
    model: str, language: str, device: int | None, prompt: str | None
) -> WhisperCppService:
    global _SESSION_BUS
    _SESSION_BUS = SessionBus()
    service = WhisperCppService(
        model=model, language=language, device=device, prompt=prompt
    )
    _SESSION_BUS.publish(DBUS_NAME, (DBUS_PATH, service))
    return service
