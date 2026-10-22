/// Decides which frames need the sand rendered again.
///
/// A frame in which nothing visibly changed can show the last image again, which costs next to
/// nothing; on a long hourglass, where a grain falls only now and then, that's most frames. The
/// picture can change when grains move, when the last render drew something that only lasts a
/// frame (highlights on grains that were moving, streaks, glints), when the light turns, or when
/// something outside the simulation changes the sand. Sand at rest is still rendered every
/// `glintEvery` frames so it keeps twinkling, and that render brings the glints of the frames
/// skipped (see `SandRenderer.render(stillFrames:)`).
public struct RenderSchedule: Sendable {
    public var glintEvery = 6

    private var framesSince = 0
    private var movesSince = 0
    private var fades = false
    private var lighting: SandRenderer.Lighting?
    private var invalidated = true

    public init() {}

    /// Another frame, in which grains made `moves` moves and the light falls from `lighting`.
    /// Returns how many frames a render now would stand for, or `nil` if the last image will do.
    public mutating func frame(moves: Int, lighting: SandRenderer.Lighting) -> Int? {
        framesSince += 1
        movesSince += moves
        let due = invalidated || movesSince > 0 || fades || lighting != self.lighting
            || framesSince >= glintEvery
        return due ? framesSince : nil
    }

    /// The sand was just rendered, lit from `lighting`, with or without streaks and glints.
    public mutating func rendered(lighting: SandRenderer.Lighting, streaks: Bool, glints: Bool) {
        fades = movesSince > 0 || streaks || glints
        self.lighting = lighting
        framesSince = 0
        movesSince = 0
        invalidated = false
    }

    /// The sand changed outside the simulation, or was rendered some other way: render the next
    /// frame whatever happens in it.
    public mutating func invalidate() {
        invalidated = true
    }
}
