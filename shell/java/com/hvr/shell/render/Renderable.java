package com.hvr.shell.render;

/**
 * 可以被双目渲染器绘制的东西。
 *
 * 存在的理由只有一个：{@link StereoRenderer} 原来把 {@code new Scene()} 写死在里面，
 * 只能画那个网格 + 立方体的演示场景。总控要在 VR 里显示自己的主界面（文件列表、
 * 状态），所以把「画什么」抽出来。渲染器只负责「用哪只眼睛、什么投影」，
 * 具体内容由实现方决定。
 *
 * 三个方法都在 GL 线程上调用，且 {@link #init()} 只在上下文创建时调一次。
 */
public interface Renderable {

    /** 上下文就绪后调用一次：编译着色器、上传纹理。 */
    void init();

    /**
     * 画一帧。
     *
     * @param viewProjection 该眼的 view * projection 矩阵，列主序 4x4
     */
    void draw(float[] viewProjection);

    /** 上下文销毁时释放 GL 资源。 */
    void release();
}
