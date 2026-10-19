/// Parameter rules (`parameter_rules`) and their templates (`use_template`).
///
/// Which semantics Dify 1.17.1 shows: the parameter-rules endpoint (`GET .../models/parameter-rules`, what the editor's
/// parameter modal lists) asks the plugin process for the model schema (`dispatch/model/schema`), and the plugin SDK builds
/// it from the YAML with `ParameterRule.validate_label` (dify-plugin-sdks `entities/model/schema.py`): the template is
/// copied and the rule's own keys are laid over it (rule keys win, whole values: a rule's `label` replaces the template's),
/// and only when neither has a label it becomes `{en_US: name}`. So `{name: temperature, use_template: temperature}` shows
/// "Temperature" / "温度". (The daemon's `TransformTemplate`, which sets `label = {en_US: name}` first, shapes only the
/// declarations of `management/models`; their parameter rules are not served to the editor.) Custom models additionally go
/// through the SDK's `_get_customizable_model_schema`, which fills max/min/default/precision/required when falsy and the
/// help (`hydrateCustomizable`).
public enum ParameterRules {
    /// The SDK's `PARAMETER_RULE_TEMPLATE` (en_US/zh_Hans; graphon keeps no other languages).
    public static let templates: [String: [String: JSON]] = [
        "temperature": [
            "label": ["en_US": "Temperature", "zh_Hans": "温度"],
            "type": "float",
            "help": [
                "en_US": "Controls randomness. Lower temperature results in less random completions. As the temperature approaches zero, the model will become deterministic and repetitive. Higher temperature results in more random completions.",
                "zh_Hans": "温度控制随机性。较低的温度会导致较少的随机完成。随着温度接近零，模型将变得确定性和重复性。较高的温度会导致更多的随机完成。",
            ],
            "required": false, "default": .double(0.0), "min": .double(0.0), "max": .double(1.0), "precision": 2,
        ],
        "top_p": [
            "label": ["en_US": "Top P", "zh_Hans": "Top P"],
            "type": "float",
            "help": [
                "en_US": "Controls diversity via nucleus sampling: 0.5 means half of all likelihood-weighted options are considered.",
                "zh_Hans": "通过核心采样控制多样性：0.5表示考虑了一半的所有可能性加权选项。",
            ],
            "required": false, "default": .double(1.0), "min": .double(0.0), "max": .double(1.0), "precision": 2,
        ],
        "top_k": [
            "label": ["en_US": "Top K", "zh_Hans": "Top K"],
            "type": "int",
            "help": [
                "en_US": "Limits the number of tokens to consider for each step by keeping only the k most likely tokens.",
                "zh_Hans": "通过只保留每一步中最可能的 k 个标记来限制要考虑的标记数量。",
            ],
            "required": false, "default": 50, "min": 1, "max": 100, "precision": 0,
        ],
        "presence_penalty": [
            "label": ["en_US": "Presence Penalty", "zh_Hans": "存在惩罚"],
            "type": "float",
            "help": [
                "en_US": "Applies a penalty to the log-probability of tokens already in the text.",
                "zh_Hans": "对文本中已有的标记的对数概率施加惩罚。",
            ],
            "required": false, "default": .double(0.0), "min": .double(0.0), "max": .double(1.0), "precision": 2,
        ],
        "frequency_penalty": [
            "label": ["en_US": "Frequency Penalty", "zh_Hans": "频率惩罚"],
            "type": "float",
            "help": [
                "en_US": "Applies a penalty to the log-probability of tokens that appear in the text.",
                "zh_Hans": "对文本中出现的标记的对数概率施加惩罚。",
            ],
            "required": false, "default": .double(0.0), "min": .double(0.0), "max": .double(1.0), "precision": 2,
        ],
        "max_tokens": [
            "label": ["en_US": "Max Tokens", "zh_Hans": "最大标记"],
            "type": "int",
            "help": [
                "en_US": "Specifies the upper limit on the length of generated results. If the generated results are truncated, you can increase this parameter.",
                "zh_Hans": "指定生成结果长度的上限。如果生成结果截断，可以调大该参数。",
            ],
            "required": false, "default": 64, "min": 1, "max": 2048, "precision": 0,
        ],
        "response_format": [
            "label": ["en_US": "Response Format", "zh_Hans": "回复格式"],
            "type": "string",
            "help": [
                "en_US": "Set a response format, ensure the output from llm is a valid code block as possible, such as JSON, XML, etc.",
                "zh_Hans": "设置一个返回格式，确保llm的输出尽可能是有效的代码块，如JSON、XML等",
            ],
            "required": false, "options": ["JSON", "XML"],
        ],
        "json_schema": [
            "label": ["en_US": "JSON Schema"],
            "type": "text",
            "help": [
                "en_US": "Set a response json schema will ensure LLM to adhere it.",
                "zh_Hans": "设置返回的json schema，llm将按照它返回",
            ],
            "required": false,
        ],
    ]

    /// A rule of a predefined model's YAML as the parameter-rules endpoint serves it (the SDK's `validate_label`, then
    /// graphon's `ParameterRule` serialisation).
    public static func predefined(_ raw: [String: JSON]) -> JSON {
        output(merged(raw))
    }

    /// The SDK's `validate_label`: the template (if `use_template` names one) with the rule's keys laid over it; then a
    /// missing or empty label becomes `{en_US: name}`.
    public static func merged(_ raw: [String: JSON]) -> [String: JSON] {
        var data = raw
        if let t = raw["use_template"]?.string, let template = templates[t] {
            data = template.merging(raw) { _, rule in rule }
        }
        if !(data["label"]?.isTruthy ?? false) { data["label"] = ["en_US": data["name"] ?? ""] }
        return data
    }

    /// The SDK's `_get_customizable_model_schema` step for one (already merged) rule of a custom model: with a known
    /// template, falsy max/min/default/precision/required take the template's, and the help is filled from it.
    public static func hydrateCustomizable(_ rule: [String: JSON]) -> [String: JSON] {
        guard let t = rule["use_template"]?.string, let template = templates[t] else { return rule }
        var r = rule
        for key in ["max", "min", "default", "precision", "required"] where !(r[key]?.isTruthy ?? false) {
            if let v = template[key] { r[key] = v }
        }
        if let th = template["help"] {
            if !(r["help"]?.isTruthy ?? false) {
                r["help"] = ["en_US": th["en_US"] ?? ""]
            } else if var h = r["help"]?.object {
                if !(h["en_US"]?.isTruthy ?? false) { h["en_US"] = th["en_US"] ?? "" }
                if !(h["zh_Hans"]?.isTruthy ?? false) { h["zh_Hans"] = th["zh_Hans"] ?? th["en_US"] ?? "" }
                r["help"] = .object(h)
            }
        }
        return r
    }

    /// graphon's `ParameterRule` as serialised: name, use_template, label, type, help, required, default, min, max (floats),
    /// precision (int), options (strings); i18n objects as `{en_US, zh_Hans}`.
    public static func output(_ r: [String: JSON]) -> JSON {
        func float(_ v: JSON?) -> JSON { v?.double.map(JSON.double) ?? .null }
        return [
            "name": r["name"] ?? "",
            "use_template": r["use_template"]?.string.map(JSON.string) ?? .null,
            "label": ModelCatalog.i18n(r["label"]) ?? ["en_US": r["name"] ?? "", "zh_Hans": r["name"] ?? ""],
            "type": r["type"] ?? .null,
            "help": ModelCatalog.i18n(r["help"]) ?? .null,
            "required": .bool(r["required"]?.bool ?? false),
            "default": r["default"] ?? .null,
            "min": float(r["min"]),
            "max": float(r["max"]),
            "precision": r["precision"]?.int.map(JSON.int) ?? .null,
            "options": .array((r["options"]?.array ?? []).compactMap { $0.scalarText.map(JSON.string) }),
        ]
    }
}
