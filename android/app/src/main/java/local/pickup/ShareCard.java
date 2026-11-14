package local.pickup;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Typeface;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.List;
import java.util.Locale;

/**
 * 分享用：把选中的取件码画成一张 1080 宽的图。
 * 纯 Canvas 绘制，不依赖额外库，也不要求把界面截屏。
 */
public class ShareCard {

    public static Bitmap render(List<PickupItem> items, Store store) {
        int w = 1080;
        int pad = 72;
        int rowH = 170;
        int listTop = 330;
        int h = listTop + items.size() * rowH + 150;

        Bitmap bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
        Canvas c = new Canvas(bmp);
        c.drawColor(Color.rgb(251, 249, 248));

        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);

        // 顶部红色小条
        p.setColor(Color.rgb(217, 26, 64));
        c.drawRoundRect(pad, 88, pad + 110, 100, 6, 6, p);

        // 标题
        p.setColor(Color.rgb(20, 20, 20));
        p.setTextSize(76);
        p.setTypeface(Typeface.create(Typeface.DEFAULT, Typeface.BOLD));
        c.drawText("待取件", pad, 212, p);

        // 副标题
        p.setColor(Color.rgb(107, 107, 107));
        p.setTextSize(34);
        p.setTypeface(Typeface.DEFAULT);
        String when = new SimpleDateFormat("M月d日 HH:mm", Locale.CHINA).format(new Date());
        c.drawText("共 " + items.size() + " 件 · " + when, pad, 286, p);

        int y = listTop;
        for (int i = 0; i < items.size(); i++) {
            PickupItem it = items.get(i);

            p.setColor(Color.rgb(18, 18, 18));
            p.setTextSize(74);
            p.setTypeface(Typeface.create(Typeface.MONOSPACE, Typeface.BOLD));
            c.drawText(it.code, pad, y + 74, p);

            StringBuilder sb = new StringBuilder(store.siteLabel(it.site));
            if (it.station != null && !it.station.isEmpty()) sb.append(" · ").append(it.station);
            if (it.place != null && !it.place.isEmpty()) sb.append(" · ").append(it.place);
            p.setColor(Color.rgb(115, 115, 115));
            p.setTextSize(32);
            p.setTypeface(Typeface.DEFAULT);
            c.drawText(sb.toString(), pad, y + 128, p);

            if (i < items.size() - 1) {
                p.setColor(Color.rgb(230, 230, 230));
                c.drawRect(pad, y + 148, w - pad, y + 150, p);
            }
            y += rowH;
        }

        p.setColor(Color.rgb(217, 217, 217));
        c.drawRect(pad, y + 14, w - pad, y + 16, p);

        p.setColor(Color.rgb(90, 90, 90));
        p.setTextSize(30);
        p.setTypeface(Typeface.create(Typeface.DEFAULT, Typeface.BOLD));
        c.drawText("茉莉取件", pad, y + 74, p);

        p.setColor(Color.rgb(140, 140, 140));
        p.setTextSize(26);
        p.setTypeface(Typeface.DEFAULT);
        c.drawText("取件码以驿站实际为准", pad, y + 116, p);

        return bmp;
    }
}
