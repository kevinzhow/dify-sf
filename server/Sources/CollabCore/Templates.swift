

/// Seed documents for new workflows.
public enum Templates {
    public static func named(_ name: String?) -> Document? {
        switch name ?? "example" {
        case "example": return example()
        case "empty": return empty()
        default: return nil
        }
    }

    private static func seed(_ ops: [Op]) -> Document {
        var doc = Document()
        // Genesis stamps use seq 0, which is never greater than any base, so they can never conflict.
        for op in ops { doc.apply(op, at: Stamp(seq: 0, client: "genesis")) }
        return doc
    }

    public static func empty() -> Document {
        seed([.addNode(Node(id: "start", type: "start", title: "Start", x: 80, y: 120))])
    }

    /// start -> llm -> code -> answer, with variable references and a keyed list (the code node's outputs).
    public static func example() -> Document {
        func ref(_ n: String, _ o: String) -> Value { .ref(OutputRef(node: n, output: o)) }
        return seed([
            .addNode(Node(id: "start", type: "start", title: "Start", x: 80, y: 120, config: [
                "variables": .items([Item(id: "v-query", value: .map(["name": .string("query"), "type": .string("string")]))]),
            ])),
            .addNode(Node(id: "llm", type: "llm", title: "Answer the question", x: 380, y: 120, config: [
                "model": .map(["provider": .string("openai"), "name": .string("gpt-4o")]),
                "prompt": .string("Answer briefly: {{#start.query#}}"),
                "context": ref("start", "query"),
            ])),
            .addNode(Node(id: "code", type: "code", title: "Post-process", x: 680, y: 120, config: [
                "language": .string("python3"),
                "code": .string("def main(text):\n    return {'result': text.strip()}"),
                "inputs": ref("llm", "text"),
                "outputs": .items([Item(id: "o-result", value: .map(["name": .string("result"), "type": .string("string")]))]),
            ])),
            .addNode(Node(id: "answer", type: "answer", title: "Answer", x: 980, y: 120, config: [
                "answer": ref("code", "result"),
            ])),
            .addEdge(Edge(id: "e-start-llm", source: "start", target: "llm")),
            .addEdge(Edge(id: "e-llm-code", source: "llm", target: "code")),
            .addEdge(Edge(id: "e-code-answer", source: "code", target: "answer")),
        ])
    }
}
