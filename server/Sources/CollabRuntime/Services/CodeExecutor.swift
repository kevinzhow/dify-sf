// Ported from Dify 1.17.1 (https://github.com/langgenius/dify, Apache-2.0 with Dify's conditions):
// api/core/helper/code_executor/code_executor.py (CodeExecutor.execute_workflow_code_template), template_transformer.py,
// python3/python3_transformer.py, javascript/javascript_transformer.py, jinja2/jinja2_transformer.py,
// api/configs/feature/__init__.py (CODE_* limits). See ../NOTICE.md.

import Foundation

/// The code sandbox (Dify's `dify-sandbox`, `POST /v1/sandbox/run`): runs a program and answers its standard output.
/// The server implements it over HTTP; tests use fakes.
public protocol CodeExecutor: Sendable {
    /// `language`: the sandbox's language (`python3`, `nodejs`); `preload`: code run first. Answers stdout; throws
    /// `CodeExecutionError` for the sandbox's errors (Dify's `CodeExecutor.execute_code`).
    func run(language: String, code: String, preload: String, enableNetwork: Bool) async throws -> String

    /// The code node's output limits (Dify's `CODE_MAX_*`) and the template transform's output limit.
    var limits: CodeNodeLimits { get }
}

extension CodeExecutor {
    public var limits: CodeNodeLimits { .difyDefaults }
}

/// `CodeExecutionError`: the sandbox could not run the code or the code failed (its stderr).
public struct CodeExecutionError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// `CodeNodeLimits` + Dify's `TEMPLATE_TRANSFORM_MAX_LENGTH`.
public struct CodeNodeLimits: Sendable, Hashable {
    public var maxStringLength: Int
    public var maxNumber: Int
    public var minNumber: Int
    public var maxPrecision: Int
    public var maxDepth: Int
    public var maxNumberArrayLength: Int
    public var maxStringArrayLength: Int
    public var maxObjectArrayLength: Int
    public var templateTransformMaxLength: Int

    public init(maxStringLength: Int, maxNumber: Int, minNumber: Int, maxPrecision: Int, maxDepth: Int, maxNumberArrayLength: Int,
                maxStringArrayLength: Int, maxObjectArrayLength: Int, templateTransformMaxLength: Int) {
        self.maxStringLength = maxStringLength
        self.maxNumber = maxNumber
        self.minNumber = minNumber
        self.maxPrecision = maxPrecision
        self.maxDepth = maxDepth
        self.maxNumberArrayLength = maxNumberArrayLength
        self.maxStringArrayLength = maxStringArrayLength
        self.maxObjectArrayLength = maxObjectArrayLength
        self.templateTransformMaxLength = templateTransformMaxLength
    }

    /// Dify's defaults.
    public static let difyDefaults = CodeNodeLimits(
        maxStringLength: 400_000, maxNumber: 9_223_372_036_854_775_807, minNumber: -9_223_372_036_854_775_807, maxPrecision: 20,
        maxDepth: 5, maxNumberArrayLength: 1000, maxStringArrayLength: 30, maxObjectArrayLength: 30, templateTransformMaxLength: 400_000)
}

/// `CodeLanguage`.
public enum CodeLanguage: String, Sendable, Hashable {
    case python3
    case javascript
    case jinja2

    /// `code_language_to_running_language`.
    var sandboxLanguage: String { self == .javascript ? "nodejs" : "python3" }
}

/// A sandbox answer that is not what the transformer expects (Dify raises `ValueError` here: not a code-node error).
public struct CodeTransformError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Dify's `TemplateTransformer`s: wrap the code into a runner that reads base64 JSON inputs and prints the result between
/// `<<RESULT>>` markers, then parse the output.
public enum CodeTemplateTransformer {
    static let codePlaceholder = "{{code}}"
    static let inputsPlaceholder = "{{inputs}}"
    static let templatePlaceholder = "{{template_b64}}"
    static let resultTag = "<<RESULT>>"

    static let python3Runner = "{{code}}\n\nimport json\nfrom base64 import b64decode\n\n# decode and prepare input dict\ninputs_obj = json.loads(b64decode('{{inputs}}').decode('utf-8'))\n\n# execute main function\noutput_obj = main(**inputs_obj)\n\n# convert output to json and print\noutput_json = json.dumps(output_obj, indent=4)\nresult = f'''<<RESULT>>{output_json}<<RESULT>>'''\nprint(result)\n"
    static let nodejsRunner = "{{code}}\n\n// decode and prepare input object\nvar inputs_obj = JSON.parse(Buffer.from('{{inputs}}', 'base64').toString('utf-8'))\n\n// execute main function\nvar output_obj = main(inputs_obj)\n\n// convert output to json and print\nvar output_json = JSON.stringify(output_obj)\nvar result = `<<RESULT>>${output_json}<<RESULT>>`\nconsole.log(result)\n"
    static let jinja2Runner = "\nimport json\nfrom base64 import b64decode\nfrom jinja2.sandbox import SandboxedEnvironment\n\n# declare main function\ndef main(**inputs):\n    # Decode base64-encoded template to handle special characters safely\n    template_code = b64decode('{{template_b64}}').decode('utf-8')\n    env = SandboxedEnvironment()\n    template = env.from_string(template_code)\n    return template.render(**inputs)\n\n# decode and prepare input dict\ninputs_obj = json.loads(b64decode('{{inputs}}').decode('utf-8'))\n\n# execute main function\noutput = main(**inputs_obj)\n\n# convert output and print\nresult = f'''<<RESULT>>{output}<<RESULT>>'''\nprint(result)\n\n"
    static let jinja2Preload = "\nfrom jinja2.sandbox import SandboxedEnvironment\nfrom base64 import b64decode\n\ndef _jinja2_preload_():\n    # prepare jinja2 sandboxed environment, load template and render\n    env = SandboxedEnvironment()\n    template = env.from_string('{{s}}')\n    template.render(s='a')\n\nif __name__ == '__main__':\n    _jinja2_preload_()\n\n"

    static func base64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    /// `serialize_inputs`: orjson (compact, UTF-8) in base64.
    static func serializeInputs(_ inputs: JSONObject) -> String { base64(JSONValue.object(inputs).compactJSON()) }

    /// `transform_caller`: (runner, preload).
    public static func transformCaller(_ language: CodeLanguage, code: String, inputs: JSONObject) -> (runner: String, preload: String) {
        switch language {
        case .python3:
            return (python3Runner.replacingOccurrences(of: codePlaceholder, with: code)
                .replacingOccurrences(of: inputsPlaceholder, with: serializeInputs(inputs)), "")
        case .javascript:
            return (nodejsRunner.replacingOccurrences(of: codePlaceholder, with: code)
                .replacingOccurrences(of: inputsPlaceholder, with: serializeInputs(inputs)), "")
        case .jinja2:
            return (jinja2Runner.replacingOccurrences(of: templatePlaceholder, with: base64(code))
                .replacingOccurrences(of: inputsPlaceholder, with: serializeInputs(inputs)), jinja2Preload)
        }
    }

    /// `extract_result_str_from_response`: the text between the first and the last marker (`(.*)` greedy, DOTALL).
    public static func extractResult(_ response: String) throws -> String {
        guard let first = response.range(of: resultTag), let last = response.range(of: resultTag, options: .backwards),
              first.upperBound <= last.lowerBound else {
            throw CodeTransformError("Failed to parse result: no result tag found in response. Response: \(String(response.prefix(200)))...")
        }
        return String(response[first.upperBound..<last.lowerBound])
    }

    /// `transform_response`: Jinja2 gives `{"result": text}`, code a JSON object (scientific-notation strings become numbers).
    public static func transformResponse(_ language: CodeLanguage, _ response: String) throws -> JSONObject {
        let text = try extractResult(response)
        if language == .jinja2 { return ["result": .string(text)] }
        let value: JSONValue
        do { value = try JSONValue.parse(text) } catch {
            throw CodeTransformError("Failed to parse JSON response: \(error).")
        }
        guard case .object(let o) = value else {
            throw CodeTransformError("Result must be a dict, got \(pythonTypeName(value))")
        }
        return o.reduce(into: JSONObject()) { out, kv in out[kv.key] = convertScientific(kv.value) }
    }

    static func pythonTypeName(_ v: JSONValue) -> String {
        switch v {
        case .null: return "NoneType"
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "float"
        case .string: return "str"
        case .array: return "list"
        case .object: return "dict"
        }
    }

    /// `_post_process_result`: strings like `1.5e+10` -> float.
    static func convertScientific(_ v: JSONValue) -> JSONValue {
        switch v {
        case .string(let s):
            if s.range(of: #"^-?\d+\.?\d*[eE][+-]\d+$"#, options: .regularExpression) != nil, let d = Double(s) { return .double(d) }
            return v
        case .object(let o): return .object(o.reduce(into: JSONObject()) { $0[$1.key] = convertScientific($1.value) })
        case .array(let a): return .array(a.map(convertScientific))
        default: return v
        }
    }

    /// `CodeExecutor.execute_workflow_code_template`.
    public static func execute(_ executor: any CodeExecutor, language: CodeLanguage, code: String, inputs: JSONObject) async throws -> JSONObject {
        let (runner, preload) = transformCaller(language, code: code, inputs: inputs)
        let stdout = try await executor.run(language: language.sandboxLanguage, code: runner, preload: preload, enableNetwork: true)
        return try transformResponse(language, stdout)
    }
}
