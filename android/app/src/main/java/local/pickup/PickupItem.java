package local.pickup;

/** 一条待取件。字段和 iOS 版保持一致，方便两端对拍。 */
public class PickupItem {
    public String code = "";
    public String site = "";
    public String station = "";
    public String place = "";
    public boolean manual = false;

    public PickupItem() {}

    public PickupItem(String code, String site, String station, String place) {
        this.code = code == null ? "" : code;
        this.site = site == null ? "" : site;
        this.station = station == null ? "" : station;
        this.place = place == null ? "" : place;
    }
}
