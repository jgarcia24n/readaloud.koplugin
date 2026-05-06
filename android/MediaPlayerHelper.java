package org.koreader.plugin.readaloud;

import android.content.Context;
import android.media.AudioManager;
import android.media.MediaPlayer;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * Polling-friendly MediaPlayer wrapper for the KOReader readaloud plugin.
 * All callbacks update volatile fields that Lua reads via JNI polling.
 */
public class MediaPlayerHelper {

    private final AudioManager audioManager;
    private final Object mpLock = new Object();
    private MediaPlayer mediaPlayer;
    private volatile boolean playbackDone = false;

    public MediaPlayerHelper(Context context) {
        audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
    }

    @SuppressWarnings("deprecation")
    private void requestAudioFocus() {
        if (audioManager != null) {
            audioManager.requestAudioFocus(null,
                AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN);
        }
    }

    @SuppressWarnings("deprecation")
    private void abandonAudioFocus() {
        if (audioManager != null) {
            audioManager.abandonAudioFocus(null);
        }
    }

    private int startPlayback(String path, int offsetMs) {
        stopPlayback();
        playbackDone = false;
        requestAudioFocus();
        synchronized (mpLock) {
            try {
                mediaPlayer = new MediaPlayer();
                mediaPlayer.setDataSource(path);
                mediaPlayer.setOnCompletionListener(mp -> {
                    playbackDone = true;
                    AudioFocus();
                });
                mediaPlayer.setOnErrorListener((mp, what, extra) -> {
                    playbackDone = true;
                    abandonAudioFocus();
                    return true;
                });
                mediaPlayer.prepare();
                if (offsetMs > 0) {
                    mediaPlayer.seekTo(offsetMs);
                }
                mediaPlayer.start();
                return mediaPlayer.getDuration();
            } catch (Exception e) {
                playbackDone = true;
                abandonAudioFocus();
                if (mediaPlayer != null) {
                    try { mediaPlayer.release(); } catch (Exception ignored) {}
                    mediaPlayer = null;
                }
                return -1;
            }
        }
    }

    /** Play file from beginning. Returns duration in ms, or -1 on error. */
    public int playFile(String path) {
        return startPlayback(path, 0);
    }

    /** Play file starting at offsetMs. Returns duration in ms, or -1 on error. */
    public int playFileFrom(String path, int offsetMs) {
        return startPlayback(path, offsetMs);
    }

    public boolean isPlaying() {
        synchronized (mpLock) {
            try {
                return mediaPlayer != null && mediaPlayer.isPlaying();
            } catch (IllegalStateException e) {
                return false;
            }
        }
    }

    /** Returns true when playback finished (completion or error). */
    public boolean isPlaybackDone() {
        return playbackDone;
    }

    /** Current playback position within the file, in milliseconds. */
    public int getCurrentPositionMs() {
        synchronized (mpLock) {
            try {
                if (mediaPlayer != null) {
                    return mediaPlayer.getCurrentPosition();
                }
            } catch (IllegalStateException ignored) {}
            return 0;
        }
    }

    public void pausePlayback() {
        synchronized (mpLock) {
            try {
                if (mediaPlayer != null && mediaPlayer.isPlaying()) {
                    mediaPlayer.pause();
                }
            } catch (IllegalStateException ignored) {}
        }
    }

    public void resumePlayback() {
        synchronized (mpLock) {
            try {
                if (mediaPlayer != null && !mediaPlayer.isPlaying()) {
                    mediaPlayer.start();
                }
            } catch (IllegalStateException ignored) {}
        }
    }

    public void stopPlayback() {
        synchronized (mpLock) {
            if (mediaPlayer != null) {
                // Clear listeners before release to avoid callbacks firing on a
                // destroyed native object.
                mediaPlayer.setOnCompletionListener(null);
                mediaPlayer.setOnErrorListener(null);
                try {
                    if (mediaPlayer.isPlaying()) mediaPlayer.stop();
                } catch (IllegalStateException ignored) {}
                try { mediaPlayer.release(); } catch (Exception ignored) {}
                mediaPlayer = null;
            }
            playbackDone = false;
        }
        abandonAudioFocus();
    }

    /** Set playback volume (0.0–1.0). */
    public void setVolume(float vol) {
        synchronized (mpLock) {
            try {
                if (mediaPlayer != null) {
                    mediaPlayer.setVolume(vol, vol);
                }
            } catch (IllegalStateException ignored) {}
        }
    }

    /**
     * Extract a single entry from a ZIP/EPUB to a local file.
     * Returns 0 on success, -1 on error.
     */
    public int extractZipEntry(String zipPath, String entryName, String destPath) {
        ZipFile zf = null;
        InputStream in = null;
        FileOutputStream out = null;
        try {
            zf = new ZipFile(zipPath);
            ZipEntry entry = zf.getEntry(entryName);
            if (entry == null) return -1;
            in = zf.getInputStream(entry);
            new File(destPath).getParentFile().mkdirs();
            out = new FileOutputStream(destPath);
            byte[] buf = new byte[65536];
            int n;
            while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
            return 0;
        } catch (Exception e) {
            return -1;
        } finally {
            try { if (out != null) out.close(); } catch (Exception ignored) {}
            try { if (in != null) in.close(); } catch (Exception ignored) {}
            try { if (zf != null) zf.close(); } catch (Exception ignored) {}
        }
    }

    public void shutdown() {
        stopPlayback();
    }
}
