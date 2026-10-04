/// The colours of one kind of sand, and of the backdrop it's shown against.
///
/// Every grain gets its own colour when it's created: a weighted pick from the palette's tones, with
/// a little brightness and warmth jitter on top, plus the odd glinting grain of quartz or mica.
public struct SandPalette: Sendable, Identifiable {
    public struct Tone: Sendable {
        public let r, g, b: UInt8
        public let weight: Float

        public init(_ hex: UInt32, _ weight: Float = 1) {
            r = UInt8(hex >> 16 & 0xFF)
            g = UInt8(hex >> 8 & 0xFF)
            b = UInt8(hex & 0xFF)
            self.weight = weight
        }
    }

    public let id: String
    public let name: String
    public let tones: [Tone]
    /// Sand-art palettes pour their tones in bands instead of mixing them.
    public let layered: Bool
    /// The colour a glinting grain flashes.
    public let sparkle: Tone
    /// The fraction of grains that glint.
    public let sparkleChance: Float
    /// Backdrop gradient, top to bottom, as 0xRRGGBB.
    public let backgroundTop: UInt32
    public let backgroundBottom: UInt32
    /// How much grains vary in brightness, as a fraction.
    public let jitter: Float

    private let cumulative: [Float]

    public init(id: String, name: String, tones: [Tone], layered: Bool = false, sparkle: Tone,
                sparkleChance: Float, backgroundTop: UInt32, backgroundBottom: UInt32,
                jitter: Float = 0.07) {
        self.id = id
        self.name = name
        self.tones = tones
        self.layered = layered
        self.sparkle = sparkle
        self.sparkleChance = sparkleChance
        self.backgroundTop = backgroundTop
        self.backgroundBottom = backgroundBottom
        self.jitter = jitter
        var total: Float = 0
        cumulative = tones.map { total += $0.weight; return total }
    }

    /// A new grain's packed RGBA colour and flags. `band` picks the tone for layered palettes.
    public func makeGrain(_ rng: inout FastRandom, band: Int = 0) -> (color: UInt32, flags: UInt8) {
        let tone: Tone
        if layered {
            tone = tones[((band % tones.count) + tones.count) % tones.count]
        } else {
            let pick = rng.unit() * (cumulative.last ?? 1)
            tone = tones[cumulative.firstIndex { pick < $0 } ?? tones.count - 1]
        }
        let sparkles = rng.unit() < sparkleChance
        let brightness = 1 + rng.signedUnit() * jitter
        let warmth = rng.signedUnit() * jitter * 0.5
        let r = Float(tone.r) * brightness * (1 + warmth)
        let g = Float(tone.g) * brightness
        let b = Float(tone.b) * brightness * (1 - warmth)
        let color = SandPalette.pack(r, g, b)
        return (color, sparkles ? SandWorld.sparkleFlag : 0)
    }

    @inline(__always)
    static func pack(_ r: Float, _ g: Float, _ b: Float, _ a: UInt32 = 255) -> UInt32 {
        let r = UInt32(max(0, min(255, r)))
        let g = UInt32(max(0, min(255, g)))
        let b = UInt32(max(0, min(255, b)))
        return r | g << 8 | b << 16 | a << 24
    }

    public var packedSparkle: UInt32 {
        SandPalette.pack(Float(sparkle.r), Float(sparkle.g), Float(sparkle.b))
    }
}

extension SandPalette {
    public static let sahara = SandPalette(
        id: "sahara", name: "Sahara",
        tones: [
            Tone(0xE6C48E, 3), Tone(0xDBB37A, 3), Tone(0xCFA268, 2.5), Tone(0xEDD6A8, 1.5),
            Tone(0xBD9059, 1.2), Tone(0xA87A4A, 0.5), Tone(0xC4835A, 0.35), Tone(0x7D5D3E, 0.18),
        ],
        sparkle: Tone(0xFFF7E3), sparkleChance: 0.025,
        backgroundTop: 0x24170E, backgroundBottom: 0x0B0705)

    public static let coral = SandPalette(
        id: "coral", name: "Pink Beach",
        tones: [
            Tone(0xF4D3C4, 3), Tone(0xECBDAC, 2.5), Tone(0xF9E6DA, 2), Tone(0xE2A08F, 1.2),
            Tone(0xD47F70, 0.5), Tone(0xFFF4EC, 0.4), Tone(0xB5655E, 0.15),
        ],
        sparkle: Tone(0xFFFFFF), sparkleChance: 0.02,
        backgroundTop: 0x2A1420, backgroundBottom: 0x0E060B)

    public static let volcanic = SandPalette(
        id: "volcanic", name: "Black Sand",
        tones: [
            Tone(0x55524F, 3), Tone(0x46433F, 3), Tone(0x625D58, 1.5), Tone(0x3A3735, 2),
            Tone(0x726A62, 0.8), Tone(0x8A7E70, 0.25),
        ],
        sparkle: Tone(0xDCE8FF), sparkleChance: 0.08,
        backgroundTop: 0x34495C, backgroundBottom: 0x111820, jitter: 0.14)

    public static let gypsum = SandPalette(
        id: "gypsum", name: "White Sands",
        tones: [
            Tone(0xF5F2EB, 3), Tone(0xEAE5DA, 3), Tone(0xDDD6C7, 2), Tone(0xF0E9D8, 1.5),
            Tone(0xCFC6B4, 0.6),
        ],
        sparkle: Tone(0xFFFFFF), sparkleChance: 0.04,
        backgroundTop: 0x1E2638, backgroundBottom: 0x0A0D14, jitter: 0.05)

    public static let sandArt = SandPalette(
        id: "art", name: "Sand Art",
        tones: [
            Tone(0xC8553D), Tone(0xF2A541), Tone(0xF4E3B2), Tone(0x2A9D8F), Tone(0x6D597A),
            Tone(0xE9C46A), Tone(0x355070), Tone(0xE56B6F),
        ],
        layered: true,
        sparkle: Tone(0xFFFFFF), sparkleChance: 0.015,
        backgroundTop: 0x1C1A24, backgroundBottom: 0x09080C, jitter: 0.06)

    public static let all: [SandPalette] = [.sahara, .coral, .volcanic, .gypsum, .sandArt]

    public static func named(_ id: String) -> SandPalette {
        all.first { $0.id == id } ?? .sahara
    }
}
