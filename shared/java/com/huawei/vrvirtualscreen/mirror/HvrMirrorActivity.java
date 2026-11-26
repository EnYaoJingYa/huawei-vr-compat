package com.huawei.vrvirtualscreen.mirror;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.view.Display;
import android.widget.Toast;

/**
 * 免 root 投屏入口：先向系统申请一次「录制/投射屏幕」授权，再把授权结果交给
 * {@link HvrMirrorService}，由它把手机默认屏镜像到眼镜那块副屏上。
 *
 * 关键点：**无论有没有检测到副屏，都先弹授权框**。没有授权框时，用户至少能在
 * 这里看到是哪一步失败（系统不支持、副屏没识别、授权被取消）。
 */
public final class HvrMirrorActivity extends Activity {

    private static final String TAG = "HvrMirrorActivity";
    private static final int REQUEST_CAPTURE = 0x4856;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Log.i(TAG, "onCreate; " + HvrPanelFinder.describeAll(this));
        Toast.makeText(this, "正在申请录屏授权…", Toast.LENGTH_SHORT).show();

        MediaProjectionManager manager =
                (MediaProjectionManager) getSystemService(MEDIA_PROJECTION_SERVICE);
        if (manager == null) {
            Toast.makeText(this, "系统不支持录屏：MediaProjectionManager 为空",
                    Toast.LENGTH_LONG).show();
            finish();
            return;
        }
        try {
            startActivityForResult(manager.createScreenCaptureIntent(), REQUEST_CAPTURE);
        } catch (Throwable error) {
            Log.w(TAG, "cannot request screen capture: " + error);
            Toast.makeText(this, "无法打开录屏授权：" + error,
                    Toast.LENGTH_LONG).show();
            finish();
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode != REQUEST_CAPTURE) {
            super.onActivityResult(requestCode, resultCode, data);
            return;
        }
        if (resultCode != RESULT_OK || data == null) {
            Toast.makeText(this, "已取消录屏授权", Toast.LENGTH_SHORT).show();
            finish();
            return;
        }

        Display panel = HvrPanelFinder.find(this);
        if (panel == null) {
            Log.w(TAG, "capture granted but no panel; " + HvrPanelFinder.describeAll(this));
            new AlertDialog.Builder(this)
                    .setTitle("已获得录屏授权，但没有找到眼镜副屏")
                    .setMessage("请确认眼镜已插好，并且系统把它识别为第二块屏幕"
                            + "（扩展模式）。\n\n当前屏幕：\n"
                            + HvrPanelFinder.describeAll(this))
                    .setPositiveButton("关闭", (dialog, which) -> finish())
                    .setCancelable(false)
                    .show();
            return;
        }

        Toast.makeText(this, "已授权，投屏到：" + panel.getName(),
                Toast.LENGTH_SHORT).show();
        Intent service = new Intent(this, HvrMirrorService.class);
        service.putExtra(HvrMirrorService.EXTRA_RESULT_CODE, resultCode);
        service.putExtra(HvrMirrorService.EXTRA_RESULT_DATA, data);
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                startForegroundService(service);
            } else {
                startService(service);
            }
        } catch (Throwable error) {
            Log.w(TAG, "cannot start the mirror service: " + error);
            Toast.makeText(this, "无法启动投屏服务：" + error,
                    Toast.LENGTH_LONG).show();
        }
        finish();
    }
}
