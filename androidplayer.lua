--[[--
Android MediaPlayer bridge for the readaloud plugin.
Wraps MediaPlayerHelper.java via JNI using DexClassLoader.
The .dex must be compiled first: cd android && ./build-dex.sh
@module koplugin.readaloud.androidplayer
--]]--

local ffi    = require("ffi")
local logger = require("logger")

local AndroidPlayer = {}

function AndroidPlayer:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o._helper_ref       = nil
    o._helper_class_ref = nil
    o._method           = {}
    o._initialized      = false
    o._android          = nil
    o.plugin_dir        = o.plugin_dir or "."
    return o
end

local function checkException(env)
    if env[0].ExceptionCheck(env) ~= 0 then
        env[0].ExceptionDescribe(env)
        env[0].ExceptionClear(env)
        return true
    end
    return false
end

function AndroidPlayer:init()
    if self._initialized then return true end

    local ok_dev, Device = pcall(require, "device")
    if not ok_dev or not Device:isAndroid() then
        logger.err("AndroidPlayer: not running on Android")
        return false
    end

    local ok_and, android = pcall(require, "android")
    if not ok_and then
        logger.err("AndroidPlayer: cannot load android module:", android)
        return false
    end
    self._android = android

    local dex_path = self.plugin_dir .. "/android/media_player_helper.dex"
    local f = io.open(dex_path, "r")
    if not f then
        logger.err("AndroidPlayer: media_player_helper.dex not found at", dex_path)
        return false
    end
    f:close()

    local cache_dir = self:_getCacheDir()
    if not cache_dir then
        logger.err("AndroidPlayer: cannot determine cache directory")
        return false
    end

    local load_ok = false
    android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env

        -- Get parent ClassLoader from the Activity
        local ctx_class = env[0].GetObjectClass(env, android.app.activity.clazz)
        if checkException(env) or ctx_class == nil then return end
        local get_cl_id = env[0].GetMethodID(env, ctx_class,
            "getClassLoader", "()Ljava/lang/ClassLoader;")
        env[0].DeleteLocalRef(env, ctx_class)
        if checkException(env) or get_cl_id == nil then return end
        local parent_cl = env[0].CallObjectMethod(env,
            android.app.activity.clazz, get_cl_id)
        if checkException(env) or parent_cl == nil then return end

        -- Create DexClassLoader
        local dcl_class = env[0].FindClass(env, "dalvik/system/DexClassLoader")
        if checkException(env) or dcl_class == nil then
            env[0].DeleteLocalRef(env, parent_cl)
            return
        end
        local dcl_init = env[0].GetMethodID(env, dcl_class, "<init>",
            "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V")
        if checkException(env) or dcl_init == nil then
            env[0].DeleteLocalRef(env, parent_cl)
            env[0].DeleteLocalRef(env, dcl_class)
            return
        end

        local j_dex = env[0].NewStringUTF(env, dex_path)
        local j_opt = env[0].NewStringUTF(env, cache_dir)
        local dcl_obj = env[0].NewObject(env, dcl_class, dcl_init,
            j_dex, j_opt, nil, parent_cl)
        env[0].DeleteLocalRef(env, j_dex)
        env[0].DeleteLocalRef(env, j_opt)
        env[0].DeleteLocalRef(env, parent_cl)
        if checkException(env) or dcl_obj == nil then
            env[0].DeleteLocalRef(env, dcl_class)
            return
        end

        -- Load MediaPlayerHelper class from the .dex
        local load_class_id = env[0].GetMethodID(env, dcl_class,
            "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;")
        env[0].DeleteLocalRef(env, dcl_class)
        if checkException(env) or load_class_id == nil then
            env[0].DeleteLocalRef(env, dcl_obj)
            return
        end

        local j_name = env[0].NewStringUTF(env,
            "org.koreader.plugin.readaloud.MediaPlayerHelper")
        local helper_class = env[0].CallObjectMethod(env, dcl_obj, load_class_id, j_name)
        env[0].DeleteLocalRef(env, j_name)
        env[0].DeleteLocalRef(env, dcl_obj)
        if checkException(env) or helper_class == nil then
            logger.err("AndroidPlayer: MediaPlayerHelper not found in .dex")
            return
        end

        -- Instantiate MediaPlayerHelper(Context)
        local helper_init = env[0].GetMethodID(env, helper_class,
            "<init>", "(Landroid/content/Context;)V")
        if checkException(env) or helper_init == nil then
            env[0].DeleteLocalRef(env, helper_class)
            return
        end
        local helper_obj = env[0].NewObject(env, helper_class, helper_init,
            android.app.activity.clazz)
        if checkException(env) or helper_obj == nil then
            env[0].DeleteLocalRef(env, helper_class)
            return
        end

        -- Cache all method IDs
        local m = self._method
        m.playFile             = env[0].GetMethodID(env, helper_class, "playFile",             "(Ljava/lang/String;)I")
        m.playFileFrom         = env[0].GetMethodID(env, helper_class, "playFileFrom",         "(Ljava/lang/String;I)I")
        m.isPlaying            = env[0].GetMethodID(env, helper_class, "isPlaying",            "()Z")
        m.isPlaybackDone       = env[0].GetMethodID(env, helper_class, "isPlaybackDone",       "()Z")
        m.getCurrentPositionMs = env[0].GetMethodID(env, helper_class, "getCurrentPositionMs", "()I")
        m.pausePlayback        = env[0].GetMethodID(env, helper_class, "pausePlayback",        "()V")
        m.resumePlayback       = env[0].GetMethodID(env, helper_class, "resumePlayback",       "()V")
        m.stopPlayback         = env[0].GetMethodID(env, helper_class, "stopPlayback",         "()V")
        m.setVolume            = env[0].GetMethodID(env, helper_class, "setVolume",            "(F)V")
        m.extractZipEntry      = env[0].GetMethodID(env, helper_class, "extractZipEntry",
            "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)I")
        m.shutdown             = env[0].GetMethodID(env, helper_class, "shutdown",             "()V")

        if checkException(env) then
            logger.err("AndroidPlayer: failed to resolve one or more method IDs")
            env[0].DeleteLocalRef(env, helper_obj)
            env[0].DeleteLocalRef(env, helper_class)
            return
        end

        self._helper_ref       = env[0].NewGlobalRef(env, helper_obj)
        self._helper_class_ref = env[0].NewGlobalRef(env, helper_class)
        env[0].DeleteLocalRef(env, helper_obj)
        env[0].DeleteLocalRef(env, helper_class)

        load_ok = true
        logger.info("AndroidPlayer: MediaPlayerHelper loaded OK")
    end)

    if not load_ok then return false end
    self._initialized = true
    return true
end

function AndroidPlayer:_getCacheDir()
    local android = self._android
    if not android then return nil end
    return android.jni:context(android.app.activity.vm, function(jni)
        local cache_file = jni:callObjectMethod(
            android.app.activity.clazz, "getCacheDir", "()Ljava/io/File;")
        if cache_file == nil then return nil end
        local abs_path = jni:callObjectMethod(
            cache_file, "getAbsolutePath", "()Ljava/lang/String;")
        jni.env[0].DeleteLocalRef(jni.env, cache_file)
        if abs_path == nil then return nil end
        local result = jni:to_string(abs_path)
        jni.env[0].DeleteLocalRef(jni.env, abs_path)
        return result
    end)
end

-- ── playback API ──────────────────────────────────────────────────────────────

function AndroidPlayer:playFile(path)
    if not self._initialized or not self._helper_ref then return -1 end
    return self._android.jni:context(self._android.app.activity.vm, function(jni)
        local env = jni.env
        local j_path = env[0].NewStringUTF(env, path)
        local result = env[0].CallIntMethod(env, self._helper_ref, self._method.playFile, j_path)
        env[0].DeleteLocalRef(env, j_path)
        if checkException(env) then return -1 end
        return result
    end)
end

-- Use jvalue array so the jint arg lands in the right register on AArch64.
function AndroidPlayer:playFileFrom(path, offset_ms)
    if not self._initialized or not self._helper_ref then return -1 end
    return self._android.jni:context(self._android.app.activity.vm, function(jni)
        local env = jni.env
        local j_path = env[0].NewStringUTF(env, path)
        local args = ffi.new("jvalue[2]")
        args[0].l = j_path
        args[1].i = offset_ms
        local result = env[0].CallIntMethodA(env,
            self._helper_ref, self._method.playFileFrom, args)
        env[0].DeleteLocalRef(env, j_path)
        if checkException(env) then return -1 end
        return result
    end)
end

function AndroidPlayer:isPlaying()
    if not self._initialized or not self._helper_ref then return false end
    return self._android.jni:context(self._android.app.activity.vm, function(jni)
        return jni.env[0].CallBooleanMethod(jni.env,
            self._helper_ref, self._method.isPlaying) ~= 0
    end)
end

function AndroidPlayer:isPlaybackDone()
    if not self._initialized or not self._helper_ref then return true end
    return self._android.jni:context(self._android.app.activity.vm, function(jni)
        local result = jni.env[0].CallBooleanMethod(jni.env,
            self._helper_ref, self._method.isPlaybackDone)
        if checkException(jni.env) then return true end
        return result ~= 0
    end)
end

function AndroidPlayer:getCurrentPositionMs()
    if not self._initialized or not self._helper_ref then return 0 end
    return self._android.jni:context(self._android.app.activity.vm, function(jni)
        local result = jni.env[0].CallIntMethod(jni.env,
            self._helper_ref, self._method.getCurrentPositionMs)
        if checkException(jni.env) then return 0 end
        return result
    end)
end

function AndroidPlayer:pausePlayback()
    if not self._initialized or not self._helper_ref then return end
    self._android.jni:context(self._android.app.activity.vm, function(jni)
        jni.env[0].CallVoidMethod(jni.env, self._helper_ref, self._method.pausePlayback)
    end)
end

function AndroidPlayer:resumePlayback()
    if not self._initialized or not self._helper_ref then return end
    self._android.jni:context(self._android.app.activity.vm, function(jni)
        jni.env[0].CallVoidMethod(jni.env, self._helper_ref, self._method.resumePlayback)
    end)
end

function AndroidPlayer:stopPlayback()
    if not self._initialized or not self._helper_ref then return end
    self._android.jni:context(self._android.app.activity.vm, function(jni)
        jni.env[0].CallVoidMethod(jni.env, self._helper_ref, self._method.stopPlayback)
    end)
end

function AndroidPlayer:setVolume(vol)
    if not self._initialized or not self._helper_ref then return end
    self._android.jni:context(self._android.app.activity.vm, function(jni)
        local env = jni.env
        local args = ffi.new("jvalue[1]")
        args[0].f = vol
        env[0].CallVoidMethodA(env, self._helper_ref, self._method.setVolume, args)
    end)
end

function AndroidPlayer:extractZipEntry(zip_path, entry_name, dest_path)
    if not self._initialized or not self._helper_ref then return -1 end
    return self._android.jni:context(self._android.app.activity.vm, function(jni)
        local env = jni.env
        local j_zip   = env[0].NewStringUTF(env, zip_path)
        local j_entry = env[0].NewStringUTF(env, entry_name)
        local j_dest  = env[0].NewStringUTF(env, dest_path)
        local result = env[0].CallIntMethod(env, self._helper_ref,
            self._method.extractZipEntry, j_zip, j_entry, j_dest)
        env[0].DeleteLocalRef(env, j_zip)
        env[0].DeleteLocalRef(env, j_entry)
        env[0].DeleteLocalRef(env, j_dest)
        if checkException(env) then return -1 end
        return result
    end)
end

function AndroidPlayer:shutdown()
    if not self._initialized then return end
    if self._android and self._helper_ref then
        self._android.jni:context(self._android.app.activity.vm, function(jni)
            local env = jni.env
            env[0].CallVoidMethod(env, self._helper_ref, self._method.shutdown)
            env[0].DeleteGlobalRef(env, self._helper_ref)
            if self._helper_class_ref then
                env[0].DeleteGlobalRef(env, self._helper_class_ref)
            end
        end)
    end
    self._helper_ref       = nil
    self._helper_class_ref = nil
    self._method           = {}
    self._initialized      = false
    logger.dbg("AndroidPlayer: shutdown complete")
end

return AndroidPlayer
