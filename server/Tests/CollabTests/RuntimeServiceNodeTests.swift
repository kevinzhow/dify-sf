import Foundation
import Synchronization
import Testing
@testable import CollabRuntime

/// The service-backed nodes of runtime phase P2 (protocol 1.14) over fakes: template transform and code (the code
/// sandbox), HTTP request (the SSRF-proxied client). The real sandbox and proxy are exercised by the runtime E2E.
final class FakeSandbox: CodeExecutor, @unchecked Sendable {
    struct Call { var language: String; var code: String; var preload: String }
    let calls = Mutex<[Call]>([])
    let answer: @Sendable (String, String) throws -> String
    let limits: CodeNodeLimits

    init(limits: CodeNodeLimits = .difyDefaults, answer: @escaping @Sendable (_ language: String, _ code: String) throws -> String) {
        self.answer = answer
        self.limits = limits
    }

    func run(language: String, code: String, preload: String, enableNetwork: Bool) async throws -> String {
        calls.withLock { $0.append(Call(language: language, code: code, preload: preload)) }
        return try answer(language, code)
    }

    /// The JSON inputs the runner carries (base64 between `b64decode('` / `Buffer.from('` and `'`).
    static func inputs(of code: String) -> JSONValue? {
        for marker in ["json.loads(b64decode('", "Buffer.from('"] {
            guard let r = code.range(of: marker) else { continue }
            let rest = code[r.upperBound...]
            guard let end = rest.firstIndex(of: "'"), let data = Data(base64Encoded: String(rest[..<end])) else { return nil }
            return try? JSONValue.parse(data)
        }
        return nil
    }
}

final class FakeHTTP: RuntimeHTTPClient, @unchecked Sendable {
    let requests = Mutex<[RuntimeHTTPRequest]>([])
    let respond: @Sendable (RuntimeHTTPRequest) throws -> RuntimeHTTPResponse
    let requestConfig: HTTPRequestNodeConfig

    init(config: HTTPRequestNodeConfig = .difyDefaults, respond: @escaping @Sendable (RuntimeHTTPRequest) throws -> RuntimeHTTPResponse) {
        self.respond = respond
        requestConfig = config
    }

    func send(_ request: RuntimeHTTPRequest) async throws -> RuntimeHTTPResponse {
        requests.withLock { $0.append(request) }
        return try respond(request)
    }

    static func json(_ text: String, status: Int = 200) -> RuntimeHTTPResponse {
        RuntimeHTTPResponse(status: status, headers: [("Content-Type", "application/json"), ("X-A", "1"), ("x-a", "2")], body: Array(text.utf8))
    }
}

func runNode(_ node: any RuntimeNode, pool: VariablePool = VariablePool()) async -> (NodeRunResult, [GraphNodeEvent]) {
    let events = Mutex<[GraphNodeEvent]>([])
    await NodeRunner.run(node, executionId: "x", context: NodeRunContext(pool: pool)) { e in events.withLock { $0.append(e) } }
    let all = events.withLock { $0 }
    return (all.compactMap(\.result).last ?? NodeRunResult(), all)
}

func pool(_ values: [([String], JSONValue)], secrets: [([String], String)] = []) throws -> VariablePool {
    var p = VariablePool()
    for (sel, v) in values { try p.add(sel, v) }
    for (sel, v) in secrets { try p.add(sel, Segment(.secret, .string(v))) }
    return p
}

@Suite("Runtime template transform and code nodes")
struct RuntimeCodeNodeTests {
    @Test func templateRendersThroughTheSandboxAsJinja2() async throws {
        let sandbox = FakeSandbox { _, _ in "noise<<RESULT>>Hi Ann, 3 items<<RESULT>>\n" }
        let node = try TemplateTransformNode(id: "t", data: ["type": "template-transform", "title": "T", "template": "Hi {{ name }}, {{ n }} items",
                                                             "variables": [["variable": "name", "value_selector": ["start", "name"]],
                                                                           ["variable": "n", "value_selector": ["start", "n"]],
                                                                           ["variable": "missing", "value_selector": ["start", "none"]]]],
                                             renderer: SandboxJinja2Renderer(executor: sandbox))
        let (r, _) = await runNode(node, pool: try pool([(["start", "name"], "Ann"), (["start", "n"], 3)]))
        #expect(r.status == .succeeded)
        #expect(r.outputs == ["output": "Hi Ann, 3 items"])
        #expect(r.inputs == ["name": "Ann", "n": 3, "missing": .null])
        let call = try #require(sandbox.calls.withLock { $0.first })
        #expect(call.language == "python3" && call.preload.contains("_jinja2_preload_"))
        #expect(call.code.contains("SandboxedEnvironment") && call.code.contains(Data("Hi {{ name }}, {{ n }} items".utf8).base64EncodedString()))
        #expect(FakeSandbox.inputs(of: call.code) == ["name": "Ann", "n": 3, "missing": .null])
        #expect(node.variableMapping(graph: try GraphConfig(json: ["nodes": []])).map(\.key) == ["t.name", "t.n", "t.missing"])
    }

    @Test func templateFailures() async throws {
        let data: JSONObject = ["type": "template-transform", "title": "T", "template": "{{ x }}", "variables": []]
        let failing = FakeSandbox { _, _ in throw CodeExecutionError("jinja2.exceptions.UndefinedError: boom") }
        let (r1, _) = await runNode(try TemplateTransformNode(id: "t", data: data, renderer: SandboxJinja2Renderer(executor: failing)))
        #expect(r1.status == .failed && r1.error == "jinja2.exceptions.UndefinedError: boom" && r1.errorType == "")
        let long = FakeSandbox { _, _ in "<<RESULT>>" + String(repeating: "é", count: 6) + "<<RESULT>>" }
        let (r2, _) = await runNode(try TemplateTransformNode(id: "t", data: data, renderer: SandboxJinja2Renderer(executor: long), maxOutputLength: 5))
        #expect(r2.status == .failed && r2.error == "Output length exceeds 5 characters")
        let noTag = FakeSandbox { _, _ in "hello" }
        let (r3, _) = await runNode(try TemplateTransformNode(id: "t", data: data, renderer: SandboxJinja2Renderer(executor: noTag)))
        #expect(r3.status == .failed && r3.errorType == "WorkflowNodeError" && r3.error.hasPrefix("Failed to parse result: no result tag found"))
    }

    func codeData(_ outputs: JSONObject, language: String = "python3", retry: Bool = false) -> JSONObject {
        ["type": "code", "title": "Code", "code_language": .string(language), "code": "def main(a):\n    return {}",
         "variables": [["variable": "a", "value_selector": ["start", "a"]]], "outputs": .object(outputs),
         "retry_config": ["retry_enabled": .bool(retry), "max_retries": 2, "retry_interval": 10]]
    }

    func code(_ outputs: JSONObject, result: String, limits: CodeNodeLimits = .difyDefaults, language: String = "python3") throws -> (CodeNode, FakeSandbox) {
        let sandbox = FakeSandbox(limits: limits) { _, _ in "<<RESULT>>" + result + "<<RESULT>>" }
        return (try CodeNode(id: "c", data: codeData(outputs, language: language), executor: sandbox), sandbox)
    }

    @Test func typedOutputsAreCheckedAndNormalized() async throws {
        let (node, sandbox) = try code(["s": ["type": "string"], "n": ["type": "number"], "b": ["type": "boolean"],
                                        "nums": ["type": "array[number]"], "strs": ["type": "array[string]"],
                                        "o": ["type": "object", "children": ["k": ["type": "string"]]],
                                        "objs": ["type": "array[object]"], "e": ["type": "number"]],
                                       result: #"{"s": "a\u0000b", "n": true, "b": false, "nums": [1, 2.5, false], "strs": ["x", null],"#
                                           + #" "o": {"k": "v"}, "objs": [{"z": 1}, null], "e": "1.5e+3"}"#)
        let (r, _) = await runNode(node, pool: try pool([(["start", "a"], ["q": 1])]))
        #expect(r.status == .succeeded, "\(r.error)")
        #expect(r.outputs == ["s": "ab", "n": 1, "b": false, "nums": [1, 2.5, 0], "strs": ["x", .null], "o": ["k": "v"],
                              "objs": [["z": 1], .null], "e": 1500.0])
        #expect(r.outputs.keys == ["s", "n", "b", "nums", "strs", "o", "objs", "e"])
        #expect(r.inputs == ["a": ["q": 1]])
        let call = try #require(sandbox.calls.withLock { $0.first })
        #expect(call.language == "python3" && call.preload == "")
        #expect(call.code.hasPrefix("def main(a):\n    return {}\n\nimport json\n"))
        #expect(FakeSandbox.inputs(of: call.code) == ["a": ["q": 1]])
    }

    @Test func javascriptRunsAsNodejs() async throws {
        let (node, sandbox) = try code(["r": ["type": "string"]], result: #"{"r": "ok"}"#, language: "javascript")
        let (r, _) = await runNode(node)
        #expect(r.status == .succeeded && r.outputs == ["r": "ok"])
        let call = try #require(sandbox.calls.withLock { $0.first })
        #expect(call.language == "nodejs" && call.code.contains("var output_obj = main(inputs_obj)"))
    }

    @Test func outputValidationErrors() async throws {
        func fails(_ outputs: JSONObject, _ result: String, limits: CodeNodeLimits = .difyDefaults) async throws -> NodeRunResult {
            let (node, _) = try code(outputs, result: result, limits: limits)
            let (r, _) = await runNode(node)
            #expect(r.status == .failed)
            return r
        }
        var r = try await fails(["x": ["type": "string"]], #"{}"#)
        #expect(r.error == "Output x is missing." && r.errorType == "OutputValidationError")
        r = try await fails(["x": ["type": "string"]], #"{"x": "a", "y": 1}"#)
        #expect(r.error == "Not all output parameters are validated." && r.errorType == "CodeNodeError")
        r = try await fails(["x": ["type": "string"]], #"{"x": 1}"#)
        #expect(r.error == "Output x must be a string, got int instead.")
        r = try await fails(["x": ["type": "number"]], #"{"x": "1"}"#)
        #expect(r.error == "Output x is not a number, got <class 'str'> instead.")
        r = try await fails(["x": ["type": "number"]], #"{"x": 1e19}"#)
        #expect(r.error == "Output variable `x` is out of range, it must be between -9223372036854775807 and 9223372036854775807.")
        r = try await fails(["x": ["type": "number"]], #"{"x": 1e-25}"#)
        #expect(r.error == "Output variable `x` has too high precision, it must be less than 20 digits.")
        r = try await fails(["x": ["type": "array[number]"]], #"{"x": [1, "2"]}"#)
        #expect(r.error == "The element at index 1 of output variable `x` must be a number.")
        r = try await fails(["x": ["type": "array[string]"]], #"{"x": ["a", "b", "c"]}"#, limits: limits(strings: 2))
        #expect(r.error == "The length of output variable `x` must be less than 2 elements.")
        r = try await fails(["x": ["type": "array[object]"]], #"{"x": [1]}"#)
        #expect(r.error == "Output x[0] is not an object, got <class 'int'> instead at index 0.")
        r = try await fails(["x": ["type": "array[boolean]"]], #"{"x": [true, 1]}"#)
        #expect(r.error == "Output x[1] is not a boolean, got <class 'int'> instead.")
        r = try await fails(["x": ["type": "object"]], #"{"x": {"a": {"b": {"c": {"d": {"e": 1}}}}}}"#)
        #expect(r.error == "Depth limit 5 reached, object too deep." && r.errorType == "DepthLimitError")
        r = try await fails(["x": ["type": "object"]], #"{"x": {"a": [1, "b"]}}"#)
        #expect(r.error == "Output x.a is not a valid array. make sure all elements are of the same type.")
        r = try await fails(["x": ["type": "string"]], #"{"x": "abcdef"}"#, limits: limits(stringLength: 5))
        #expect(r.error == "The length of output variable `x` must be less than 5 characters")
        r = try await fails(["x": ["type": "object"]], #"{"x": 3}"#)
        #expect(r.error == "Output x is not an object, got <class 'int'> instead.")
    }

    func limits(strings: Int = 30, stringLength: Int = 400_000) -> CodeNodeLimits {
        var l = CodeNodeLimits.difyDefaults
        l.maxStringArrayLength = strings
        l.maxStringLength = stringLength
        return l
    }

    @Test func sandboxErrorsAndUnexpectedAnswers() async throws {
        let failing = FakeSandbox { _, _ in throw CodeExecutionError("Traceback: NameError") }
        let (r1, _) = await runNode(try CodeNode(id: "c", data: codeData(["r": ["type": "string"]]), executor: failing))
        #expect(r1.status == .failed && r1.error == "Traceback: NameError" && r1.errorType == "CodeExecutionError")
        let notDict = FakeSandbox { _, _ in "<<RESULT>>[1]<<RESULT>>" }
        let (r2, _) = await runNode(try CodeNode(id: "c", data: codeData(["r": ["type": "string"]]), executor: notDict))
        #expect(r2.status == .failed && r2.errorType == "WorkflowNodeError" && r2.error == "Result must be a dict, got list")
    }

    @Test func nodeDataRulesAndRetry() throws {
        let sandbox = FakeSandbox { _, _ in "" }
        #expect(throws: NodeDataError.self) { try CodeNode(id: "c", data: codeData(["r": ["type": "file"]]), executor: sandbox) }
        #expect(throws: NodeDataError.self) { try CodeNode(id: "c", data: codeData([:], language: "jinja2"), executor: sandbox) }
        #expect(try CodeNode(id: "c", data: codeData([:], retry: true), executor: sandbox).retryEnabled)
        #expect(try !CodeNode(id: "c", data: codeData([:]), executor: sandbox).retryEnabled)
        #expect(CodeNode.precision(0.1) == 1 && CodeNode.precision(100.0) == 0 && CodeNode.precision(1e-07) == 7 && CodeNode.precision(1.25) == 2)
    }

    @Test func factoryNeedsTheSandbox() async throws {
        let g = try GraphConfig(json: ["nodes": [["id": "c", "data": .object(codeData([:]))]]])
        await #expect(throws: ServiceNotConfigured.self) { _ = try await BuiltinNodeFactory(services: RuntimeServices()).createNode(g.nodes[0], graph: g) }
        let node = try await BuiltinNodeFactory(services: RuntimeServices(codeExecutor: FakeSandbox { _, _ in "" })).createNode(g.nodes[0], graph: g)
        #expect(node is CodeNode)
    }
}

@Suite("Runtime HTTP request node")
struct RuntimeHTTPNodeTests {
    func data(method: String = "get", url: String = "https://api.example.com/v1/items?keep=1&q=old", headers: String = "",
              params: String = "", auth: JSONValue = ["type": "no-auth"], body: JSONValue? = nil, retry: Bool = false,
              strategy: String? = nil) -> JSONObject {
        var d: JSONObject = ["type": "http-request", "title": "HTTP", "method": .string(method), "url": .string(url),
                             "authorization": auth, "headers": .string(headers), "params": .string(params),
                             "retry_config": ["retry_enabled": .bool(retry), "max_retries": 1, "retry_interval": 10]]
        if let body { d["body"] = body }
        if let strategy { d["error_strategy"] = .string(strategy) }
        return d
    }

    @Test func getWithParamsHeadersAndBearer() async throws {
        let http = FakeHTTP { _ in FakeHTTP.json(#"{"ok": true}"#) }
        let node = try HTTPRequestNode(id: "h", data: data(headers: "X-Trace: {{#start.trace#}}\nAccept:application/json\n",
                                                           params: "q: {{#start.q#}}\nempty\n: skipped\nq2: a b&c",
                                                           auth: ["type": "api-key", "config": ["type": "bearer", "api_key": "{{#env.key#}}"]]),
                                       client: http)
        let p = try pool([(["start", "trace"], "t-1"), (["start", "q"], "héllo")], secrets: [(["env", "key"], "sk-1234567890")])
        let (r, _) = await runNode(node, pool: p)
        #expect(r.status == .succeeded, "\(r.error)")
        let req = try #require(http.requests.withLock { $0.first })
        #expect(req.method == "GET")
        #expect(req.url == "https://api.example.com/v1/items?keep=1&q=h%C3%A9llo&empty=&q2=a+b%26c")
        #expect(req.headers.map(\.name) == ["X-Trace", "Accept", "Authorization"])
        #expect(req.headers.last?.value == "Bearer sk-1234567890")
        #expect(req.connectTimeout == 10 && req.readTimeout == 600 && req.followRedirects && req.verifySSL && req.body == nil)
        #expect(r.outputs["status_code"] == 200 && r.outputs["body"] == #"{"ok": true}"#)
        #expect(r.outputs["headers"] == ["content-type": "application/json", "x-a": "1, 2"])
        #expect(r.outputs["files"] == [])
        let log = try #require(r.processData["request"]?.string)
        #expect(log.hasPrefix("GET /v1/items?q=h%C3%A9llo&empty=&q2=a+b%26c HTTP/1.1\r\nHost: api.example.com\r\n"))
        #expect(log.contains("Authorization: " + String(repeating: "*", count: "Bearer sk-1234567890".count) + "\r\n"))
        #expect(!log.contains("sk-1234567890"))
        #expect(node.variableMapping(graph: try GraphConfig(json: ["nodes": []])).map(\.key) == ["h.#start.trace#", "h.#start.q#"])
    }

    @Test func bodies() async throws {
        let http = FakeHTTP { _ in FakeHTTP.json("{}") }
        let p = try pool([(["start", "name"], "Ann"), (["start", "n"], 2)])
        let json = try HTTPRequestNode(id: "h", data: data(method: "post", url: "http://x.test",
                                                           body: ["type": "json", "data": [["type": "text", "value": #"{"name": "{{#start.name#}}", "n": {{#start.n#}}}"#]]]),
                                       client: http)
        _ = await runNode(json, pool: p)
        let form = try HTTPRequestNode(id: "h", data: data(method: "post", url: "http://x.test", headers: "Content-Type: text/whatever",
                                                           body: ["type": "x-www-form-urlencoded",
                                                                  "data": [["type": "text", "key": "a b", "value": "{{#start.name#}}&1"]]]),
                                       client: http)
        _ = await runNode(form, pool: p)
        let multi = try HTTPRequestNode(id: "h", data: data(method: "post", url: "http://x.test", headers: "content-type: x",
                                                            body: ["type": "form-data", "data": [["type": "text", "key": "k", "value": "v"],
                                                                                                 ["type": "file", "key": "f", "file": ["start", "file"]]]]),
                                        client: http)
        let (rm, _) = await runNode(multi, pool: p)
        let raw = try HTTPRequestNode(id: "h", data: data(method: "put", url: "http://x.test", body: ["type": "raw-text", "data": "plain {{#start.n#}}"]),
                                      client: http)
        _ = await runNode(raw, pool: p)
        let reqs = http.requests.withLock { $0 }
        #expect(reqs.count == 4)
        #expect(reqs[0].body.map { String(decoding: $0, as: UTF8.self) } == #"{"name":"Ann","n":2}"#)
        #expect(reqs[0].headers.first { $0.name == "Content-Type" }?.value == "application/json")
        #expect(reqs[1].body.map { String(decoding: $0, as: UTF8.self) } == "a+b=Ann%261")
        #expect(reqs[1].headers.filter { $0.name.lowercased() == "content-type" }.map(\.value) == ["text/whatever"])
        let ct = try #require(reqs[2].headers.first { $0.name.lowercased() == "content-type" }?.value)
        #expect(ct.hasPrefix("multipart/form-data; boundary=") && reqs[2].headers.filter { $0.name.lowercased() == "content-type" }.count == 1)
        let boundary = String(ct.dropFirst("multipart/form-data; boundary=".count))
        let mbody = String(decoding: reqs[2].body ?? [], as: UTF8.self)
        #expect(mbody == "--\(boundary)\r\nContent-Disposition: form-data; name=\"k\"\r\n\r\nv\r\n"
            + "--\(boundary)\r\nContent-Disposition: form-data; name=\"__multipart_placeholder__\"\r\nContent-Type: application/octet-stream\r\n\r\n\r\n"
            + "--\(boundary)--\r\n")
        let mlog = try #require(rm.processData["request"]?.string)
        #expect(mlog.contains("Content-Type: multipart/form-data; boundary=----WebKitFormBoundary") && mlog.contains("name=\"k\"\r\n\r\nv\r\n"))
        #expect(reqs[3].method == "PUT" && reqs[3].body.map { String(decoding: $0, as: UTF8.self) } == "plain 2")
        #expect(reqs[3].headers.first { $0.name == "Content-Type" }?.value == "text/plain")
    }

    @Test func requestErrors() async throws {
        let http = FakeHTTP { _ in FakeHTTP.json("{}") }
        func fails(_ d: JSONObject, _ p: VariablePool = VariablePool()) async throws -> NodeRunResult {
            let (r, _) = await runNode(try HTTPRequestNode(id: "h", data: d, client: http), pool: p)
            #expect(r.status == .failed)
            return r
        }
        var r = try await fails(data(url: "ftp://x"))
        #expect(r.error == "url should start with http:// or https://" && r.errorType == "InvalidURLError")
        r = try await fails(data(url: ""))
        #expect(r.error == "url is required")
        r = try await fails(data(url: "{{#start.none#}}"))
        #expect(r.error == "url should start with http:// or https://")
        r = try await fails(data(auth: ["type": "api-key", "config": ["type": "custom", "api_key": "  ", "header": "X-K"]]))
        #expect(r.errorType == "AuthorizationConfigError" && r.error.hasPrefix("API key is required"))
        r = try await fails(data(method: "post", body: ["type": "json", "data": [["type": "text", "value": "{not json"]]]))
        #expect(r.error == "Failed to parse JSON: {not json" && r.errorType == "RequestBodyError")
        r = try await fails(data(method: "post", body: ["type": "raw-text", "data": [["type": "text", "value": "a"], ["type": "text", "value": "b"]]]))
        #expect(r.error == "raw-text body type should have exactly one item")
        r = try await fails(data(method: "post", body: ["type": "binary", "data": [["type": "file", "file": ["start", "f"]]]]))
        #expect(r.errorType == "FileFetchError" && r.error == "cannot fetch file with selector ['start', 'f']")
        r = try await fails(data(method: "options"))
        #expect(r.errorType == "InvalidHttpMethodError" && r.error == "Invalid http method options")
        #expect(r.processData["request"]?.string?.hasPrefix("OPTIONS ") == true)
        #expect(throws: NodeDataError.self) { try HTTPRequestNode(id: "h", data: data(auth: ["type": "api-key"]), client: http) }
    }

    @Test func responsesStatusesSizesAndFiles() async throws {
        func run(_ response: RuntimeHTTPResponse, retry: Bool = false, strategy: String? = nil,
                 config: HTTPRequestNodeConfig = .difyDefaults) async throws -> NodeRunResult {
            let http = FakeHTTP(config: config) { _ in response }
            return await runNode(try HTTPRequestNode(id: "h", data: data(retry: retry, strategy: strategy), client: http)).0
        }
        let notFound = FakeHTTP.json(#"{"e": 1}"#, status: 404)
        #expect(try await run(notFound).status == .succeeded)
        let retried = try await run(notFound, retry: true)
        #expect(retried.status == .failed && retried.errorType == "HTTPResponseCodeError" && retried.error == "Request failed with status code 404")
        #expect(retried.outputs["status_code"] == 404)
        #expect(try await run(notFound, strategy: "default-value").status == .failed)
        var small = HTTPRequestNodeConfig.difyDefaults
        small.maxTextSize = 4
        let big = try await run(FakeHTTP.json("123456"), config: small)
        #expect(big.errorType == "ResponseSizeError" && big.error == "Text size is too large, max size is 0.00 MB, but current size is 6 bytes.")
        let png = try await run(RuntimeHTTPResponse(status: 200, headers: [("Content-Type", "image/png")], body: [0x89, 0x50]))
        #expect(png.status == .failed && png.error == HTTPRequestNode.fileResponseError)
        let pdf = try await run(RuntimeHTTPResponse(status: 200, headers: [("Content-Type", "application/pdf")], body: [0x25]))
        #expect(pdf.status == .failed)
        let text = try await run(RuntimeHTTPResponse(status: 200, headers: [("Content-Type", "text/plain; charset=latin-1")], body: [0x63, 0xE9]))
        #expect(text.status == .succeeded && text.outputs["body"] == "cé")
        let jsonish = try await run(RuntimeHTTPResponse(status: 200, headers: [("Content-Type", "application/x-custom")], body: Array(#"{"a":1}"#.utf8)))
        #expect(jsonish.status == .succeeded)
    }

    @Test func transportErrorsAndRetryFlag() async throws {
        let down = FakeHTTP { _ in throw RuntimeHTTPError.request("connection refused") }
        let (r1, _) = await runNode(try HTTPRequestNode(id: "h", data: data(), client: down))
        #expect(r1.status == .failed && r1.errorType == "HttpRequestNodeError" && r1.error == "connection refused")
        #expect(r1.processData["request"]?.string?.hasPrefix("GET /v1/items?keep=1&q=old HTTP/1.1") == true)
        let blocked = FakeHTTP { _ in throw RuntimeHTTPError.ssrfBlocked("Access to 'http://10.0.0.1' was blocked by SSRF protection") }
        let (r2, _) = await runNode(try HTTPRequestNode(id: "h", data: data(url: "http://10.0.0.1"), client: blocked))
        #expect(r2.status == .failed && r2.errorType == "WorkflowNodeError" && r2.error.contains("blocked by SSRF protection"))
        #expect(try HTTPRequestNode(id: "h", data: data(retry: true), client: down).retryEnabled)
        let timeouts = try HTTPRequestNode(id: "h", data: data().merging(["timeout": ["connect": 3, "read": 0]]), client: down)
        #expect(timeouts.requestTimeout == (3, 600, 600))
    }

    @Test func basicAuthAndHostHeader() async throws {
        let http = FakeHTTP { _ in FakeHTTP.json("{}") }
        _ = await runNode(try HTTPRequestNode(id: "h", data: data(headers: "Host: virtual.example",
                                                                  auth: ["type": "api-key", "config": ["type": "basic", "api_key": "u:p", "header": ""]]),
                                              client: http))
        let req = try #require(http.requests.withLock { $0.first })
        #expect(req.headers.first { $0.name == "Authorization" }?.value == "Basic dTpw")
        #expect(req.headers.first { $0.name == "Host" }?.value == "virtual.example")
    }
}
