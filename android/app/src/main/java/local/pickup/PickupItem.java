package local.pickup;

/** 一条待取件。字段和 iOS 版保持一致，方便两端对拍。 */
public class PickupItem {
    public String code = "";
    public String site = "";
    public String station = "";
    public String place = "";
    /** 快递单号，比如 YT7656364590990；没有就空串 */
    public String mailNo = "";
    /** 快递主图 / 商品图的绝对地址；没有就空串 */
    public String img = "";
    public boolean manual = false;

    public PickupItem() {}

    public PickupItem(String code, String site, String station, String place) {
        this.code = code == null ? "" : code;
        this.site = site == null ? "" : site;
        this.station = station == null ? "" : station;
        this.place = place == null ? "" : place;
    }

    public PickupItem(String code, String site, String station, String place, String mailNo, String img) {
        this(code, site, station, place);
        this.mailNo = mailNo == null ? "" : mailNo;
        this.img = img == null ? "" : img;
    }
}
