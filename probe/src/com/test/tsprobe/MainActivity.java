package com.test.tsprobe;
import android.app.Activity;
import android.graphics.Color;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioTimestamp;
import android.media.AudioTrack;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Gravity;
import android.widget.TextView;
import java.lang.reflect.Method;

/** Probe: logs AudioTrack.getTimestamp vs getPlaybackHeadPosition; optional click+flash A/V test and pause/resume cycling. */
public class MainActivity extends Activity {
  Thread worker; TextView view; Handler ui = new Handler(Looper.getMainLooper());
  volatile long lastClickShownFrame = -1;
  @Override protected void onCreate(Bundle b) {
    super.onCreate(b);
    view = new TextView(this); view.setTextSize(22); view.setGravity(Gravity.CENTER); view.setBackgroundColor(Color.BLACK); view.setTextColor(Color.WHITE);
    setContentView(view);
    getWindow().addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    final int rate = getIntent().getIntExtra("rate", 48000);
    final int bufMs = getIntent().getIntExtra("bufms", 500);
    final int secs = getIntent().getIntExtra("secs", 30);
    final int enc = getIntent().getIntExtra("enc", 2);
    final boolean click = getIntent().getBooleanExtra("click", false);
    final int cycleMs = getIntent().getIntExtra("cyclems", 0); // >0: pause 4 s every cycleMs
    final int newTrackMs = getIntent().getIntExtra("newtrackms", 0); // >0: destroy and recreate the AudioTrack every N ms
    worker = new Thread(new Runnable() { public void run() { if (newTrackMs > 0) newTrackLoop(rate, bufMs, secs, enc, newTrackMs); else probe(rate, bufMs, secs, enc, click, cycleMs); } });
    worker.start();
  }
  @Override protected void onDestroy() { super.onDestroy(); if (worker != null) worker.interrupt(); }

  void show(final String s, final boolean flash) {
    ui.post(new Runnable() { public void run() { view.setText(s); view.setBackgroundColor(flash ? Color.WHITE : Color.BLACK); view.setTextColor(flash ? Color.BLACK : Color.WHITE); } });
  }

  /** Shorts-like pattern: a fresh AudioTrack every newTrackMs, blocking writes, log timestamp error over each track's life. */
  void newTrackLoop(int rate, int bufMs, int secs, int enc, int newTrackMs) {
    int bps = (enc == 2) ? 2 : 4; int bufFrames = rate * bufMs / 1000; int chunkFrames = rate / 100;
    java.nio.ByteBuffer bb = java.nio.ByteBuffer.allocateDirect(chunkFrames * 2 * bps).order(java.nio.ByteOrder.nativeOrder());
    double ph = 0;
    for (int i = 0; i < chunkFrames; i++) { double v = Math.sin(ph) * 0.18; ph += 2 * Math.PI * 1000 / rate;
      for (int c = 0; c < 2; c++) { if (enc == 2) bb.putShort((short)(v * 32767)); else if (enc == 4) bb.putFloat((float) v); else bb.putInt((int)(v * 2147483647.0)); } }
    long t0 = System.nanoTime(); int n = 0; AudioTimestamp ts = new AudioTimestamp();
    Log.i("TSPROBE", "START newtrack enc=" + enc + " rate=" + rate + " bufFrames=" + bufFrames + " newTrackMs=" + newTrackMs);
    while (!Thread.currentThread().isInterrupted() && (System.nanoTime() - t0) / 1e9 < secs) {
      n++;
      AudioTrack at = new AudioTrack.Builder()
        .setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
        .setAudioFormat(new AudioFormat.Builder().setEncoding(enc).setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build())
        .setBufferSizeInBytes(bufFrames * 2 * bps).setTransferMode(AudioTrack.MODE_STREAM).build();
      long tStart = System.nanoTime(); long written = 0, lastLog = 0; at.play();
      Log.i("TSPROBE", "TRACK " + n + " created session=" + at.getAudioSessionId());
      while ((System.nanoTime() - tStart) / 1000000 < newTrackMs && !Thread.currentThread().isInterrupted()) {
        bb.rewind(); at.write(bb, bb.remaining(), AudioTrack.WRITE_BLOCKING); written += chunkFrames;
        long now = System.nanoTime();
        if (now - lastLog > 500000000L) {
          lastLog = now; long head = at.getPlaybackHeadPosition() & 0xffffffffL; boolean ok = at.getTimestamp(ts);
          long tsNow = ok ? ts.framePosition + (now - ts.nanoTime) * rate / 1000000000L : -1;
          Log.i("TSPROBE", String.format("TRACK %d age=%.1f written=%d head=%d queued_ms=%d ts_ok=%b ts_pos_now=%d head_minus_ts_ms=%d written_minus_ts_ms=%d",
            n, (now - tStart) / 1e9, written, head, (written - head) * 1000 / rate, ok, tsNow, ok ? (head - tsNow) * 1000 / rate : -1, ok ? (written - tsNow) * 1000 / rate : -1));
          final String msg = String.format("track %d  ts-head = %+d ms", n, ok ? (tsNow - head) * 1000 / rate : 0); show(msg, false);
        }
      }
      at.stop(); at.release();
      Log.i("TSPROBE", "TRACK " + n + " released");
    }
    Log.i("TSPROBE", "END"); finish();
  }

  void probe(int rate, int bufMs, int secs, int enc, boolean click, int cycleMs) {
    int bps = (enc == 2) ? 2 : 4;
    int bufFrames = rate * bufMs / 1000;
    AudioTrack at = new AudioTrack.Builder()
      .setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
      .setAudioFormat(new AudioFormat.Builder().setEncoding(enc).setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build())
      .setBufferSizeInBytes(bufFrames * 2 * bps).setTransferMode(AudioTrack.MODE_STREAM).build();
    int chunkFrames = rate / 100; // 10 ms
    java.nio.ByteBuffer bb = java.nio.ByteBuffer.allocateDirect(chunkFrames * 2 * bps).order(java.nio.ByteOrder.nativeOrder());
    Integer lat = null;
    try { Method m = AudioTrack.class.getMethod("getLatency"); lat = (Integer) m.invoke(at); } catch (Throwable t) { }
    Log.i("TSPROBE", "START enc=" + enc + " rate=" + rate + " bufFrames=" + at.getBufferSizeInFrames() + " click=" + click + " cycleMs=" + cycleMs + " getLatency=" + lat);
    at.play();
    long written = 0, t0 = System.nanoTime(), lastLog = 0, lastCycle = t0, lastUi = 0; int cycles = 0; boolean paused = false; long pausedAt = 0;
    AudioTimestamp ts = new AudioTimestamp();
    double ph = 0;
    while (!Thread.currentThread().isInterrupted()) {
      long now = System.nanoTime();
      if (cycleMs > 0) {
        if (!paused && now - lastCycle > cycleMs * 1000000L) { at.pause(); paused = true; pausedAt = now; Log.i("TSPROBE", "PAUSE cycle=" + (cycles + 1)); }
        if (paused && now - pausedAt > 4000000000L) { at.play(); paused = false; lastCycle = now; cycles++; Log.i("TSPROBE", "RESUME cycle=" + cycles); }
      }
      if (!paused) {
        bb.clear();
        for (int i = 0; i < chunkFrames; i++) {
          long f = written + i; double v;
          if (click) { long inSec = f % rate; v = (inSec < rate / 200) ? Math.sin(ph) * 0.8 : 0.0; } // 5 ms burst once per second
          else v = Math.sin(ph) * 0.18;
          ph += 2 * Math.PI * 1000 / rate;
          for (int c = 0; c < 2; c++) { if (enc == 2) bb.putShort((short)(v * 32767)); else if (enc == 4) bb.putFloat((float) v); else bb.putInt((int)(v * 2147483647.0)); }
        }
        bb.flip(); at.write(bb, bb.remaining(), AudioTrack.WRITE_BLOCKING); written += chunkFrames;
      } else { try { Thread.sleep(5); } catch (InterruptedException e) { break; } }
      now = System.nanoTime();
      long head = at.getPlaybackHeadPosition() & 0xffffffffL;
      boolean ok = at.getTimestamp(ts);
      long tsNow = ok ? ts.framePosition + (now - ts.nanoTime) * rate / 1000000000L : -1;
      if (click && ok && now - lastUi > 4000000L) {
        lastUi = now;
        long sec = tsNow / rate; long inSec = tsNow % rate;
        boolean flash = inSec < rate / 12; // flash for ~80 ms after the predicted click instant
        if (flash && sec != lastClickShownFrame) lastClickShownFrame = sec;
        show(String.format("ts-head = %+d ms\nqueued = %d ms\n\nFLASH = timestamp says click plays now", (tsNow - head) * 1000 / rate, (written - head) * 1000 / rate), flash);
      }
      if (now - lastLog > 1000000000L) {
        lastLog = now;
        Log.i("TSPROBE", String.format("t=%.1f cycles=%d paused=%b written=%d head=%d queued_ms=%d ts_ok=%b ts_age_ms=%d ts_pos_now=%d head_minus_ts_ms=%d written_minus_ts_ms=%d",
          (now - t0) / 1e9, cycles, paused, written, head, (written - head) * 1000 / rate, ok, ok ? (now - ts.nanoTime) / 1000000 : -1, tsNow,
          ok ? (head - tsNow) * 1000 / rate : -1, ok ? (written - tsNow) * 1000 / rate : -1));
        if (!click) show(String.format("ts-head = %+d ms\nqueued = %d ms\ncycles = %d", ok ? (tsNow - head) * 1000 / rate : 0, (written - head) * 1000 / rate, cycles), false);
        if ((now - t0) / 1e9 > secs) break;
      }
    }
    at.stop(); at.release();
    Log.i("TSPROBE", "END");
    finish();
  }
}
