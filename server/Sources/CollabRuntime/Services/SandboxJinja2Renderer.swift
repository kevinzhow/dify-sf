// Ported from Dify 1.17.1 (https://github.com/langgenius/dify, Apache-2.0 with Dify's conditions):
// api/core/workflow/template_rendering.py (CodeExecutorJinja2TemplateRenderer); graphon 0.7.0
// (https://github.com/langgenius/graphon, Apache-2.0): graphon/template_rendering.py (TemplateRenderError).
// See ../NOTICE.md.

/// `TemplateRenderError`: the template could not be rendered (the template transform node reports it as its error).
public struct TemplateRenderError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Jinja2 through the code sandbox, as Dify renders it (`jinja2.sandbox.SandboxedEnvironment` in the sandbox's Python).
public struct SandboxJinja2Renderer: Jinja2TemplateRenderer {
    public let executor: any CodeExecutor

    public init(executor: any CodeExecutor) {
        self.executor = executor
    }

    /// Sandbox errors become `TemplateRenderError`; an answer without result markers stays an unexpected error.
    public func renderTemplate(_ template: String, inputs: JSONObject) async throws -> String {
        let result: JSONObject
        do {
            result = try await CodeTemplateTransformer.execute(executor, language: .jinja2, code: template, inputs: inputs)
        } catch let e as CodeExecutionError {
            throw TemplateRenderError(e.message)
        }
        guard case .string(let rendered)? = result["result"] else { throw TemplateRenderError("Template render result must be a string.") }
        return rendered
    }
}
