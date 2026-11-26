package dev.vrdemo.posedriver.render;

/**
 * 桶形畸变参数。
 *
 * <p>{@code scale = 1 + k1·r² + k2·r⁴}，{@code r} 是归一化到 [-1,1] 的眼内半径。
 * {@code k1 > 0} 表示把画面向外预畸变，用来抵消透镜的桶形畸变。</p>
 *
 * <p><b>华为 CV10 的真实参数未知</b>：原厂从
 * {@code HIDIOCGFEATURE(48)} 的「光学信息」里取，但 48 字节的字段含义没有还原
 * （见文档 §9）。{@link #GENERIC_BARREL} 只是让管线可见的通用值，必须按实际
 * 镜片调。</p>
 */
public final class LensProfile {

    public static final LensProfile NONE = new LensProfile(0f, 0f, 0f);
    public static final LensProfile GENERIC_BARREL = new LensProfile(0.16f, 0.035f, 0.003f);

    public final float k1;
    public final float k2;
    /** 色差补偿强度，0 = 关闭。 */
    public final float chroma;

    public LensProfile(float k1, float k2, float chroma) {
        this.k1 = k1;
        this.k2 = k2;
        this.chroma = chroma;
    }
}
