import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// A downloadable embedding model. Weights are fetched once into the config dir
/// and verified against a pinned digest — they are executed as numeric code, so
/// an unverified CDN payload is not acceptable.
struct ModelAsset {
    let id: String
    let displayName: String
    let parameters: String
    let downloadBytes: Int
    let url: String
    let sha256: String
    /// Vector width, and the token budget a single chunk may use.
    let dimension: Int
    let maxTokens: Int

    /// Retrieval-trained and multilingual, so notes written in different
    /// languages share one vector space.
    static let multilingualE5Small = ModelAsset(
        id: "multilingual-e5-small",
        displayName: "multilingual-e5-small",
        parameters: "118M",
        downloadBytes: 236 * 1024 * 1024,
        url: "https://huggingface.co/intfloat/multilingual-e5-small/resolve/main/model.safetensors",
        sha256: "",   // pinned when the downloader lands
        dimension: 384,
        maxTokens: 256
    )

    static var directory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/editxr/models"
    }

    var localPath: String { "\(ModelAsset.directory)/\(id).safetensors" }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: localPath) }

    /// Human-readable download size, e.g. "236 MB".
    var sizeLabel: String {
        let mb = Double(downloadBytes) / (1024 * 1024)
        return mb >= 1024
            ? String(format: "%.1f GB", mb / 1024)
            : String(format: "%.0f MB", mb)
    }
}

/// What stands between the user and working semantic search, for the backend
/// they picked. Drives the setup panel: `.ready` needs no prompt at all.
enum EmbedderStatus {
    /// Usable right now; the string describes what will be used.
    case ready(String)
    /// The OS ships the model but hasn't fetched its assets yet.
    case needsSystemAssets
    /// A model has to be downloaded before anything can be indexed.
    case needsDownload(ModelAsset)
    /// Backend picked but not usable here (wrong OS, server not running).
    case unavailable(String)
    /// Semantic search deliberately turned off — text search only.
    case disabled

    /// Short label for the settings menu's right-hand column.
    var label: String {
        switch self {
        case .ready: return "ready"
        case .needsSystemAssets: return "setup"
        case .needsDownload(let asset): return asset.sizeLabel
        case .unavailable: return "n/a"
        case .disabled: return "off"
        }
    }

    /// One-line explanation for the Index section of the settings menu.
    var detail: String {
        switch self {
        case .ready(let what): return what
        case .needsSystemAssets: return "Needs one-time system asset download"
        case .needsDownload(let asset): return "Needs \(asset.displayName) (\(asset.sizeLabel))"
        case .unavailable(let why): return why
        case .disabled: return "Semantic search off — text search only"
        }
    }
}

/// Produces vectors for chunks of note text.
///
/// No backend is wired yet: `EmbedderFactory` only reports what *would* be used,
/// which is all the setup panel needs. The index engine plugs in behind this.
protocol Embedder {
    var dimension: Int { get }
    var maxTokens: Int { get }
    func embed(_ texts: [String]) throws -> [[Float]]
}

enum EmbedderFactory {

    /// Whether Apple's on-device contextual embedding is usable on this machine.
    /// macOS 14+ only; older systems only expose per-language sentence vectors,
    /// which measured too weakly for retrieval to be worth offering.
    static var appleIsSupported: Bool {
        #if canImport(NaturalLanguage)
        if #available(macOS 14.0, *) {
            return NLContextualEmbedding(script: .latin) != nil
        }
        #endif
        return false
    }

    /// True once the OS has actually fetched the model assets.
    static var appleHasAssets: Bool {
        #if canImport(NaturalLanguage)
        if #available(macOS 14.0, *) {
            return NLContextualEmbedding(script: .latin)?.hasAvailableAssets ?? false
        }
        #endif
        return false
    }

    /// The model a local-model backend would use.
    static let defaultAsset = ModelAsset.multilingualE5Small

    /// What the given backend needs before it can index, without doing any work.
    static func status(for backend: EmbedBackend, semanticSearch: Bool) -> EmbedderStatus {
        guard semanticSearch, backend != .off else { return .disabled }

        switch backend {
        case .off:
            return .disabled
        case .apple:
            guard appleIsSupported else {
                return .unavailable("Needs macOS 14 or later")
            }
            return appleHasAssets ? .ready("Built into macOS — nothing to download")
                                  : .needsSystemAssets
        case .lmStudio:
            return .ready("Uses your LM Studio server — stays on your machine")
        case .localModel:
            return defaultAsset.isInstalled
                ? .ready("\(defaultAsset.displayName) — installed")
                : .needsDownload(defaultAsset)
        case .auto:
            // Prefer what costs the user nothing, then what they already run.
            if appleIsSupported && appleHasAssets {
                return .ready("Built into macOS — nothing to download")
            }
            if defaultAsset.isInstalled {
                return .ready("\(defaultAsset.displayName) — installed")
            }
            if appleIsSupported { return .needsSystemAssets }
            return .needsDownload(defaultAsset)
        }
    }
}
