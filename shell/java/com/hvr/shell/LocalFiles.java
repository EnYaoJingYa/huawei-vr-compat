package com.hvr.shell;

import android.content.Context;
import android.content.Intent;
import android.media.MediaScannerConnection;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.Settings;

import java.io.File;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * 「可以访问本地文件」这一块的落地。
 *
 * 分两步，缺一不可：
 * <ol>
 *   <li><b>权限</b> —— {@code MANAGE_EXTERNAL_STORAGE}（安装脚本用 appops 授予），
 *       让总控与原版视频包能读写 /sdcard 任意目录，不再受分区存储限制；</li>
 *   <li><b>索引</b> —— 原版视频包是按 MediaStore 列表取片的，新拷进卡里的片子
 *       系统没扫过就不在列表里。这里主动调 MediaScanner 把它扫进来。</li>
 * </ol>
 *
 * 只做这两件事：文件本身的播放仍然是 com.huawei.himovie.vr 的原版播放器，
 * 总控不接管、不自己实现一个列表。
 */
final class LocalFiles {

    /** 常见媒体扩展名。原版播放器认的格式（2D/SBS/TB/360）都在这里面。 */
    private static final Set<String> MEDIA_EXTENSIONS = new HashSet<>(Arrays.asList(
            "mp4", "mkv", "avi", "mov", "wmv", "flv", "ts", "m2ts", "webm", "3gp", "m4v",
            "jpg", "jpeg", "png", "bmp", "webp", "gif",
            "mp3", "wav", "flac", "aac", "m4a", "ogg"));

    /** 视频单独一份：VR 桌面要列的是片子，不是相册和歌。 */
    private static final Set<String> VIDEO_EXTENSIONS = new HashSet<>(Arrays.asList(
            "mp4", "mkv", "avi", "mov", "wmv", "flv", "ts", "m2ts", "webm", "3gp", "m4v"));

    /** 优先扫这些目录；根目录只扫一层，避免整卡遍历拖死 IO。 */
    private static final String[] PRIORITY_DIRS = {
            "Movies", "Download", "DCIM", "Pictures", "Music", "VR", "VRVideo", "Videos"
    };

    private static final int MAX_DEPTH = 6;
    private static final int MAX_FILES = 8000;

    private LocalFiles() {
    }

    static boolean hasAllFilesAccess(Context context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            // Android 10 及以下：MANAGE_EXTERNAL_STORAGE 不存在，读写外部存储靠
            // 旧版权限 + requestLegacyExternalStorage，这里按「可用」看待。
            return true;
        }
        try {
            return Environment.isExternalStorageManager();
        } catch (Throwable error) {
            return false;
        }
    }

    static void openAllFilesSettings(Context context) {
        try {
            Intent intent = new Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION);
            intent.setData(Uri.parse("package:" + context.getPackageName()));
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            context.startActivity(intent);
        } catch (Throwable error) {
            ShellState.event("打不开「所有文件访问」设置页", error);
            try {
                Intent fallback = new Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION);
                fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                context.startActivity(fallback);
            } catch (Throwable second) {
                ShellState.event("打不开文件访问设置页", second);
            }
        }
    }

    /**
     * 扫一遍本地媒体并交给 MediaScanner 入库。在后台线程调用。
     *
     * @return 本次提交给扫描器的文件数
     */
    static int scanMedia(Context context) {
        if (!hasAllFilesAccess(context)) {
            ShellState.fileNote = "没有「所有文件访问」权限，先授权";
            return 0;
        }
        File root = Environment.getExternalStorageDirectory();
        if (root == null || !root.isDirectory()) {
            ShellState.fileNote = "读不到外部存储";
            return 0;
        }
        List<String> found = new ArrayList<>();
        for (String name : PRIORITY_DIRS) {
            File dir = new File(root, name);
            if (dir.isDirectory()) {
                collect(dir, 0, found);
            }
        }
        // 根目录再扫一层，兜住用户自己建的目录。
        File[] top = root.listFiles();
        if (top != null) {
            for (File entry : top) {
                if (entry.isFile() && isMedia(entry.getName())) {
                    found.add(entry.getAbsolutePath());
                } else if (entry.isDirectory() && !isPriorityDir(entry.getName())) {
                    collect(entry, MAX_DEPTH - 2, found);
                }
                if (found.size() >= MAX_FILES) {
                    break;
                }
            }
        }
        if (found.isEmpty()) {
            ShellState.fileNote = "没找到媒体文件";
            return 0;
        }
        String[] paths = found.toArray(new String[0]);
        MediaScannerConnection.scanFile(context, paths, null, null);
        ShellState.fileNote = "已提交 " + paths.length + " 个文件给媒体库";
        ShellState.event("本地媒体扫描完成：" + paths.length + " 个");
        return paths.length;
    }

    /**
     * 列出本地视频，按修改时间从新到旧。
     *
     * 只找视频（不含图片/音频）：VR 桌面主要用来起片子，先把这条路径做通。
     * 排序用 {@code lastModified} 而不是名字，因为手机拍的片子名字通常是时间戳，
     * 而拷进来的片子名字千奇百怪，时间更能反映"最近看的"。
     */
    static java.util.List<File> listVideos(Context context, int limit) {
        java.util.List<File> result = new java.util.ArrayList<>();
        if (!hasAllFilesAccess(context)) {
            return result;
        }
        File root = Environment.getExternalStorageDirectory();
        if (root == null || !root.isDirectory()) {
            return result;
        }
        java.util.List<String> paths = new java.util.ArrayList<>();
        for (String name : PRIORITY_DIRS) {
            File dir = new File(root, name);
            if (dir.isDirectory()) {
                collect(dir, 0, paths);
            }
        }
        for (String path : paths) {
            if (!isVideo(path)) {
                continue;
            }
            File file = new File(path);
            if (file.isFile()) {
                result.add(file);
            }
        }
        java.util.Collections.sort(result, new java.util.Comparator<File>() {
            @Override
            public int compare(File left, File right) {
                return Long.compare(right.lastModified(), left.lastModified());
            }
        });
        if (result.size() > limit) {
            return result.subList(0, limit);
        }
        return result;
    }

    private static boolean isVideo(String name) {
        int dot = name.lastIndexOf('.');
        if (dot < 0) {
            return false;
        }
        return VIDEO_EXTENSIONS.contains(name.substring(dot + 1).toLowerCase());
    }

    private static boolean isPriorityDir(String name) {        for (String known : PRIORITY_DIRS) {
            if (known.equalsIgnoreCase(name)) {
                return true;
            }
        }
        return false;
    }

    private static void collect(File dir, int depth, List<String> out) {
        if (depth > MAX_DEPTH || out.size() >= MAX_FILES) {
            return;
        }
        File[] children = dir.listFiles();
        if (children == null) {
            return;
        }
        for (File child : children) {
            if (out.size() >= MAX_FILES) {
                return;
            }
            if (child.isDirectory()) {
                if (child.getName().startsWith(".")) {
                    continue;
                }
                collect(child, depth + 1, out);
            } else if (isMedia(child.getName())) {
                out.add(child.getAbsolutePath());
            }
        }
    }

    private static boolean isMedia(String name) {
        int dot = name.lastIndexOf('.');
        if (dot < 0 || dot == name.length() - 1) {
            return false;
        }
        return MEDIA_EXTENSIONS.contains(name.substring(dot + 1).toLowerCase());
    }
}
