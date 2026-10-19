import Foundation
import Yams

/// A predefined model, read from a plugin's `models/<type>/<model>.yaml` the way Dify 1.17.1's plugin daemon declares it
/// (`dify-plugin-daemon` `pkg/entities/plugin_entities/model_declaration.go`): a missing label is the model name,
/// `fetch_from` defaults to `predefined-model`.
public struct ModelDefinition: Sendable {
    public let model: String
    public let label: JSON
    public let modelType: String
    /// Nil when the YAML has none (Dify answers `null`).
    public let features: [String]?
    public let fetchFrom: String
    public let modelProperties: [String: JSON]
    public let deprecated: Bool
    /// The YAML's parameter rules, unresolved (see `ParameterRules.predefined`).
    public let rawParameterRules: [[String: JSON]]

    /// The rules as Dify's parameter-rules endpoint answers them (templates resolved).
    public var parameterRules: [JSON] { rawParameterRules.map(ParameterRules.predefined) }
}

/// An icon file of a provider.
public struct ProviderIcon: Sendable {
    public let data: Data
    public let contentType: String
}

/// One provider of the catalog: the plugin's `provider/<name>.yaml` plus its predefined models, normalised to the shapes
/// Dify's console API serves (graphon's `ProviderEntity`: every i18n object is `{en_US, zh_Hans}` with `zh_Hans` defaulting
/// to `en_US`; credential form schemas keep graphon's fields only).
public struct ProviderDefinition: Sendable {
    public let id: ProviderID
    public let pluginVersion: String
    public let label: JSON
    public let description: JSON?
    public let background: String?
    public let help: JSON?
    /// icon file name per language (`en_US`, `zh_Hans`), nil when the provider has none.
    public let iconSmall: [String: String]?
    public let iconSmallDark: [String: String]?
    public let supportedModelTypes: [String]
    public let configurateMethods: [String]
    public let providerCredentialSchema: JSON?
    public let modelCredentialSchema: JSON?
    /// Predefined models in declaration order (files sorted by name per model type).
    public let models: [ModelDefinition]
    /// `_position.yaml` lists keyed by the YAML's model type key (`llm`, `text_embedding`, ...), as the daemon passes them.
    public let positions: [String: [String]]
    let iconFiles: [String: ProviderIcon]

    public var supportsPredefinedModels: Bool { configurateMethods.contains("predefined-model") }
    public var supportsCustomModels: Bool { configurateMethods.contains("customizable-model") }

    public var providerFormSchemas: [JSON] { providerCredentialSchema?["credential_form_schemas"]?.array ?? [] }
    public var modelFormSchemas: [JSON] { modelCredentialSchema?["credential_form_schemas"]?.array ?? [] }

    /// The `secret-input` variables of the provider form (or of the custom-model form).
    public func secretVariables(forModel: Bool) -> Set<String> {
        Set((forModel ? modelFormSchemas : providerFormSchemas).compactMap { f in
            f["type"]?.string == "secret-input" ? f["variable"]?.string : nil
        })
    }

    /// Dify's `get_provider_icon`: `icon_small` or `icon_small_dark`, `zh_Hans` (any case) or else `en_US`.
    public func icon(type: String, lang: String) -> ProviderIcon? {
        let files: [String: String]?
        switch type.lowercased() {
        case "icon_small": files = iconSmall
        case "icon_small_dark": files = iconSmallDark
        default: return nil
        }
        guard let files else { return nil }
        let name = lang.lowercased() == "zh_hans" ? (files["zh_Hans"] ?? files["en_US"]) : files["en_US"]
        return name.flatMap { iconFiles[$0] }
    }

    public func model(_ name: String, type: String) -> ModelDefinition? {
        models.first { $0.model == name && $0.modelType == type }
    }
}

public struct CatalogError: Error, CustomStringConvertible, Sendable {
    public var description: String
    init(_ d: String) { description = d }
}

/// The model providers dify-sf knows: the vendored official plugin definitions (`Resources/dify-official-plugins`, see
/// its SOURCE.md), loaded once at startup. Immutable.
public struct ModelCatalog: Sendable {
    public let providers: [ProviderDefinition]
    private let byId: [String: Int]

    /// Display order (the plugin directories); directories not listed come after, by name.
    public static let displayOrder = ["openai", "anthropic", "gemini", "azure_openai", "tongyi", "zhipuai", "moonshot", "deepseek",
                                      "ollama", "openai_api_compatible"]

    public init(providers: [ProviderDefinition]) {
        self.providers = providers
        var m: [String: Int] = [:]
        for (i, p) in providers.enumerated() { m[p.id.description] = i }
        byId = m
    }

    /// The provider for a long or bare id (normalised like Dify's `ModelProviderID`).
    public func provider(_ id: String) -> ProviderDefinition? {
        guard let pid = ProviderID(id), let i = byId[pid.description] else { return nil }
        return providers[i]
    }

    /// The definitions shipped with the server: the target's resource bundle (`DifySF_CollabModels.bundle`) next to the
    /// executable (the Docker image copies it beside `collab-server`), or the directory in `COLLAB_MODELS_DIR`. Throws
    /// (instead of SwiftPM's `Bundle.module`, which traps) when neither is there.
    public static func bundled() throws -> ModelCatalog { try load(from: bundledDirectory()) }

    public static func bundledDirectory() throws -> URL {
        let fm = FileManager.default
        if let dir = ProcessInfo.processInfo.environment["COLLAB_MODELS_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        let executableDir = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL, executableDir].compactMap { $0 }
        for base in candidates {
            let dir = base.appendingPathComponent("DifySF_CollabModels.bundle").appendingPathComponent("dify-official-plugins")
            if fm.fileExists(atPath: dir.appendingPathComponent("SOURCE.md").path) { return dir }
        }
        throw CatalogError("the vendored provider definitions (DifySF_CollabModels.bundle) are not next to the executable; set COLLAB_MODELS_DIR")
    }

    /// Loads every plugin directory under `dir` (each with `manifest.yaml` and `provider/*.yaml`).
    public static func load(from dir: URL) throws -> ModelCatalog {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: dir.path).filter { name in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir) && isDir.boolValue
                && fm.fileExists(atPath: dir.appendingPathComponent(name).appendingPathComponent("manifest.yaml").path)
        }
        let ordered = displayOrder.filter(names.contains) + names.filter { !displayOrder.contains($0) }.sorted()
        return ModelCatalog(providers: try ordered.map { try loadPlugin(dir.appendingPathComponent($0)) })
    }

    // MARK: - Loading

    static func loadPlugin(_ dir: URL) throws -> ProviderDefinition {
        let manifest = try yaml(dir.appendingPathComponent("manifest.yaml"))
        guard let org = manifest["author"]?.string, let plugin = manifest["name"]?.string else {
            throw CatalogError("\(dir.lastPathComponent): manifest without author/name")
        }
        guard let providerFile = manifest["plugins"]?["models"]?.array?.first?.string else {
            throw CatalogError("\(dir.lastPathComponent): manifest declares no model provider")
        }
        let p = try yaml(dir.appendingPathComponent(providerFile))
        guard let name = p["provider"]?.string, let id = ProviderID("\(org)/\(plugin)/\(name)") else {
            throw CatalogError("\(dir.lastPathComponent): provider without a valid name")
        }
        // Model files and positions (`models.<type key>.predefined` globs, `.position`).
        var models: [ModelDefinition] = []
        var positions: [String: [String]] = [:]
        for typeKey in ["llm", "text_embedding", "tts", "speech2text", "moderation", "rerank"] {
            guard let entry = p["models"]?[typeKey] else { continue }
            if let pos = entry["position"]?.string {
                let url = dir.appendingPathComponent(pos)
                if FileManager.default.fileExists(atPath: url.path) {
                    positions[typeKey] = (try yaml(url)).array?.compactMap(\.scalarText) ?? []
                }
            }
            for pattern in entry["predefined"]?.array?.compactMap(\.string) ?? [] {
                for file in try glob(dir, pattern) {
                    models.append(try loadModel(file))
                }
            }
        }
        var iconFiles: [String: ProviderIcon] = [:]
        let iconSmall = fileMap(p["icon_small"]), iconSmallDark = fileMap(p["icon_small_dark"])
        for file in Set((iconSmall?.values.map { $0 } ?? []) + (iconSmallDark?.values.map { $0 } ?? [])) {
            let url = dir.appendingPathComponent("_assets").appendingPathComponent(file)
            if let data = FileManager.default.contents(atPath: url.path) {
                iconFiles[file] = ProviderIcon(data: data, contentType: contentType(of: file))
            }
        }
        return ProviderDefinition(
            id: id,
            pluginVersion: manifest["version"]?.scalarText ?? "",
            label: i18n(p["label"]) ?? ["en_US": .string(name), "zh_Hans": .string(name)],
            description: i18n(p["description"]),
            background: p["background"]?.string,
            help: p["help"].flatMap { h -> JSON? in
                guard let title = i18n(h["title"]), let url = i18n(h["url"]) else { return nil }
                return ["title": title, "url": url]
            },
            iconSmall: iconSmall.flatMap { $0.isEmpty ? nil : $0 },
            iconSmallDark: iconSmallDark.flatMap { $0.isEmpty ? nil : $0 },
            supportedModelTypes: p["supported_model_types"]?.array?.compactMap(\.string) ?? [],
            configurateMethods: p["configurate_methods"]?.array?.compactMap(\.string) ?? [],
            providerCredentialSchema: p["provider_credential_schema"].flatMap { s -> JSON? in
                guard s.object != nil else { return nil }
                return ["credential_form_schemas": .array(formSchemas(s["credential_form_schemas"]))]
            },
            modelCredentialSchema: p["model_credential_schema"].flatMap { s -> JSON? in
                guard s.object != nil else { return nil }
                let model = s["model"]
                return [
                    "model": ["label": i18n(model?["label"]) ?? ["en_US": "Model Name", "zh_Hans": "Model Name"],
                              "placeholder": i18n(model?["placeholder"]) ?? .null],
                    "credential_form_schemas": .array(formSchemas(s["credential_form_schemas"])),
                ]
            },
            models: models,
            positions: positions,
            iconFiles: iconFiles)
    }

    static func loadModel(_ url: URL) throws -> ModelDefinition {
        let m = try yaml(url)
        guard let model = m["model"]?.scalarText, let type = m["model_type"]?.string else {
            throw CatalogError("\(url.lastPathComponent): model without model/model_type")
        }
        // The daemon's `MarshalJSON`: an empty `en_US` becomes the model name (graphon then fills `zh_Hans` from it).
        let en = m["label"]?["en_US"]?.scalarText ?? m["label"]?.string ?? ""
        let zh = m["label"]?["zh_Hans"]?.scalarText ?? ""
        let enLabel = en.isEmpty ? model : en
        let label: JSON = ["en_US": .string(enLabel), "zh_Hans": .string(zh.isEmpty ? enLabel : zh)]
        let props = (m["model_properties"]?.object ?? [:]).filter { modelPropertyKeys.contains($0.key) }
        return ModelDefinition(
            model: model,
            label: label,
            modelType: type,
            features: m["features"]?.array.map { $0.compactMap(\.string).filter(modelFeatures.contains) },
            fetchFrom: m["fetch_from"]?.string ?? "predefined-model",
            modelProperties: props,
            deprecated: m["deprecated"]?.bool ?? false,
            rawParameterRules: m["parameter_rules"]?.array?.compactMap(\.object) ?? [])
    }

    /// graphon's `ModelPropertyKey` (other keys are not part of Dify's answers).
    static let modelPropertyKeys: Set<String> = ["mode", "context_size", "max_chunks", "file_upload_limit", "supported_file_extensions",
                                                 "max_characters_per_chunk", "default_voice", "voices", "word_limit", "audio_type",
                                                 "max_workers"]
    /// graphon's `ModelFeature`.
    static let modelFeatures: Set<String> = ["tool-call", "multi-tool-call", "agent-thought", "vision", "stream-tool-call", "document",
                                             "video", "audio", "structured-output", "polling"]

    /// `dir/pattern` where the last path component may contain `*`: matching files sorted by name (Go's `filepath.Glob`),
    /// without `_`-prefixed files (`_position.yaml`).
    static func glob(_ dir: URL, _ pattern: String) throws -> [URL] {
        let parts = pattern.split(separator: "/").map(String.init)
        guard let last = parts.last else { return [] }
        let base = parts.dropLast().reduce(dir) { $0.appendingPathComponent($1) }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return [] }
        let star = last.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        return names.filter { name in
            guard !name.hasPrefix("_") else { return false }
            if star.count == 1 { return name == last }
            return name.hasPrefix(star.first!) && name.hasSuffix(star.last!) && name.count >= star.first!.count + star.last!.count
        }.sorted().map { base.appendingPathComponent($0) }
    }

    static func fileMap(_ v: JSON?) -> [String: String]? {
        guard let m = v?.object else { return nil }
        var out = m.compactMapValues(\.string)
        if out["zh_Hans"] == nil, let en = out["en_US"] { out["zh_Hans"] = en }
        return out
    }

    static func contentType(of file: String) -> String {
        switch (file as NSString).pathExtension.lowercased() {
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }

    /// graphon's `I18nObject` as serialised: `{"en_US", "zh_Hans"}`, `zh_Hans` = `en_US` when missing or empty. A plain
    /// string counts as `en_US`. Nil for anything else.
    public static func i18n(_ v: JSON?) -> JSON? {
        switch v {
        case .string(let s)?: return ["en_US": .string(s), "zh_Hans": .string(s)]
        case .object(let m)?:
            let en = m["en_US"]?.scalarText ?? ""
            let zh = m["zh_Hans"]?.scalarText ?? ""
            return ["en_US": .string(en), "zh_Hans": .string(zh.isEmpty ? en : zh)]
        default: return nil
        }
    }

    /// graphon's `CredentialFormSchema` fields (variable, label, type, required, default, options, placeholder, max_length,
    /// show_on), with the daemon's defaults (`required: false`, `options: []`, `show_on: []`). Defaults are strings.
    static func formSchemas(_ v: JSON?) -> [JSON] {
        (v?.array ?? []).compactMap { f -> JSON? in
            guard let variable = f["variable"]?.string, let type = f["type"]?.string else { return nil }
            let options: [JSON] = (f["options"]?.array ?? []).compactMap { o -> JSON? in
                guard let value = o["value"]?.scalarText else { return nil }
                return ["label": i18n(o["label"]) ?? ["en_US": .string(value), "zh_Hans": .string(value)], "value": .string(value),
                        "show_on": .array(showOn(o["show_on"]))]
            }
            return [
                "variable": .string(variable),
                "label": i18n(f["label"]) ?? ["en_US": .string(variable), "zh_Hans": .string(variable)],
                "type": .string(type),
                "required": .bool(f["required"]?.bool ?? false),
                "default": f["default"]?.scalarText.map(JSON.string) ?? .null,
                "options": .array(options),
                "placeholder": i18n(f["placeholder"]) ?? .null,
                "max_length": .int(f["max_length"]?.int ?? 0),
                "show_on": .array(showOn(f["show_on"])),
            ]
        }
    }

    static func showOn(_ v: JSON?) -> [JSON] {
        (v?.array ?? []).compactMap { s -> JSON? in
            guard let variable = s["variable"]?.string, let value = s["value"]?.scalarText else { return nil }
            return ["variable": .string(variable), "value": .string(value)]
        }
    }

    // MARK: - YAML

    static func yaml(_ url: URL) throws -> JSON {
        guard let data = FileManager.default.contents(atPath: url.path) else { throw CatalogError("cannot read \(url.lastPathComponent)") }
        guard let node = try Yams.compose(yaml: String(decoding: data, as: UTF8.self)) else { return .null }
        return try json(node)
    }

    /// Scalars by their resolved YAML tag; timestamps and other tags stay strings (like the DSL importer).
    static func json(_ node: Yams.Node) throws -> JSON {
        switch node {
        case .scalar(let s):
            switch Resolver.default.resolveTag(of: node) {
            case Tag.Name.null: return .null
            case Tag.Name.bool: return .bool(Bool.construct(from: s) ?? false)
            case Tag.Name.int: if let i = Int.construct(from: s) { return .int(i) }; return .string(s.string)
            case Tag.Name.float: if let d = Double.construct(from: s) { return .double(d) }; return .string(s.string)
            default: return .string(s.string)
            }
        case .sequence(let seq): return .array(try seq.map(json))
        case .mapping(let map):
            var m: [String: JSON] = [:]
            for (k, v) in map {
                guard case .scalar(let ks) = k else { throw CatalogError("non-scalar map key") }
                m[ks.string] = try json(v)
            }
            return .object(m)
        case .alias: throw CatalogError("YAML aliases are not supported")
        }
    }
}
