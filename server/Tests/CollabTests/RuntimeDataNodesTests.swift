import Foundation
import Synchronization
import Testing
@testable import CollabRuntime

/// The variable assigner (v1, v2) and the list operator (graphon 0.7.0 semantics), run directly over a pool.
@Suite("Runtime data nodes")
struct RuntimeDataNodesTests {
    struct Run {
        var result: NodeRunResult?
        var updates: [([String], Segment)] = []
    }

    func run(_ node: any RuntimeNode, _ pool: VariablePool) async throws -> Run {
        let box = Mutex(Run())
        try await node.run(NodeRunContext(pool: pool)) { e in
            switch e {
            case .completed(let r): box.withLock { $0.result = r }
            case .variableUpdated(let sel, let v): box.withLock { $0.updates.append((sel, v)) }
            default: break
            }
        }
        return box.withLock { $0 }
    }

    func pool(_ values: [([String], Segment)]) throws -> VariablePool {
        var p = VariablePool()
        for (s, v) in values { try p.add(s, v) }
        return p
    }

    func v2(_ items: [JSONValue]) throws -> VariableAssignerV2Node {
        try VariableAssignerV2Node(id: "a", data: ["type": "assigner", "title": "A", "version": "2", "items": .array(items), "selected": false])
    }

    func item(_ sel: [String], _ op: String, _ input: String = "constant", _ value: JSONValue = .null) -> JSONValue {
        ["variable_selector": .array(sel.map(JSONValue.string)), "input_type": .string(input), "operation": .string(op), "value": value]
    }

    // MARK: v2

    @Test func v2OperationsPerType() async throws {
        let p = try pool([
            (["conversation", "n"], Segment(.integer, 5)), (["conversation", "f"], Segment(.float, 1.5)),
            (["conversation", "s"], Segment(.string, "x")), (["conversation", "a"], Segment(.arrayString, [])),
            (["conversation", "o"], Segment(.object, ["k": 1])), (["start", "q"], Segment(.string, "hello")),
            (["conversation", "nums"], Segment(.arrayNumber, [1, 2, 3])),
        ])
        func one(_ i: JSONValue) async throws -> (Segment?, NodeRunResult) {
            let r = try await run(try v2([i]), p)
            return (r.updates.first?.1, r.result!)
        }
        #expect(try await one(item(["conversation", "n"], "+=", "constant", 2)).0 == Segment(.integer, 7))
        #expect(try await one(item(["conversation", "n"], "/=", "constant", 2)).0 == Segment(.integer, 2.5))
        #expect(try await one(item(["conversation", "n"], "*=", "constant", 1.5)).0 == Segment(.integer, 7.5))
        #expect(try await one(item(["conversation", "f"], "-=", "constant", 1)).0 == Segment(.float, 0.5))
        #expect(try await one(item(["conversation", "s"], "over-write", "variable", ["start", "q"])).0 == Segment(.string, "hello"))
        #expect(try await one(item(["conversation", "a"], "append", "variable", ["start", "q"])).0 == Segment(.arrayString, ["hello"]))
        #expect(try await one(item(["conversation", "a"], "clear", "variable")).0 == Segment(.arrayString, []))
        #expect(try await one(item(["conversation", "o"], "set", "constant", #"{"z": [1]}"#)).0 == Segment(.object, ["z": [1]]))
        #expect(try await one(item(["conversation", "nums"], "remove-first", "variable")).0 == Segment(.arrayNumber, [2, 3]))
        #expect(try await one(item(["conversation", "nums"], "remove-last", "variable")).0 == Segment(.arrayNumber, [1, 2]))
        #expect(try await one(item(["conversation", "nums"], "extend", "variable", ["conversation", "nums"])).0
                == Segment(.arrayNumber, [1, 2, 3, 1, 2, 3]))
        #expect(try await one(item(["conversation", "n"], "clear", "variable")).0 == Segment(.integer, 0))
        // graphon accepts constants only for set-like and arithmetic operations of scalars.
        #expect(try await one(item(["conversation", "nums"], "clear")).1.error == "Input type constant is not supported for operation clear")

        let (_, ok) = try await one(item(["conversation", "s"], "over-write", "variable", ["start", "q"]))
        #expect(ok.status == .succeeded && ok.outputs.isEmpty)
        #expect(ok.processData["s"] == "hello")
        #expect(ok.processData["__updated_variables"] == [["name": "s", "selector": ["conversation", "s"], "value_type": "string",
                                                           "new_value": "hello"]])
        #expect(ok.inputs["items"]?.array?.count == 1 && ok.inputs["selected"] == false && ok.inputs["version"] == "2"
                && ok.inputs["retry_config"]?["max_retries"] == 0)
    }

    @Test func v2Errors() async throws {
        let p = try pool([(["conversation", "s"], Segment(.string, "x")), (["conversation", "n"], Segment(.integer, 1)),
                          (["start", "none"], Segment.none)])
        func error(_ i: JSONValue) async throws -> String? {
            let r = try await run(try v2([i]), p)
            #expect(r.updates.isEmpty)
            return r.result?.status == .failed ? r.result?.error : nil
        }
        #expect(try await error(item(["conversation", "s"], "+=", "constant", 1)) == "Operation += is not supported for type string")
        #expect(try await error(item(["conversation", "n"], "+=", "variable", ["start", "n"]))
                == "Input type variable is not supported for operation +=")
        #expect(try await error(item(["conversation", "x"], "clear", "variable")) == "Variable ['conversation', 'x'] not found")
        #expect(try await error(item(["conversation", "n"], "/=", "constant", 0)) == "Invalid input value 0")
        #expect(try await error(item(["conversation", "s"], "over-write", "constant", 3)) == "Invalid input value 3")
        #expect(try await error(item(["conversation", "s"], "over-write", "variable", ["start", "missing"]))
                == "Variable ['start', 'missing'] not found")
        // A None source skips the update (the run succeeds without writing).
        let r = try await run(try v2([item(["conversation", "s"], "over-write", "variable", ["start", "none"])]), p)
        #expect(r.result?.status == .succeeded && r.updates.isEmpty)
    }

    @Test func v2ReadsItsOwnWritesAndDeduplicates() async throws {
        let p = try pool([(["conversation", "n"], Segment(.integer, 1))])
        let r = try await run(try v2([item(["conversation", "n"], "+=", "constant", 1), item(["conversation", "n"], "*=", "constant", 10)]), p)
        #expect(r.updates.count == 1 && r.updates[0].1 == Segment(.integer, 20))
        // The pool itself is untouched (the engine applies the update event).
        #expect(p.get(["conversation", "n"]) == Segment(.integer, 1))
    }

    @Test func v2BlocksAndMapping() throws {
        let n = try v2([item(["conversation", "a"], "over-write", "variable", ["start", "q"]), item(["conversation", "b"], "clear")])
        #expect(n.blocksVariableOutput([["conversation", "b"]]) && !n.blocksVariableOutput([["start", "q"]]))
        let m = n.variableMapping(graph: try GraphConfig(json: ["nodes": [], "edges": []]))
        #expect(m.map(\.key) == ["a.#conversation.a#", "a.#start.q#", "a.#conversation.b#"])
    }

    // MARK: v1

    @Test func v1Modes() async throws {
        let p = try pool([(["conversation", "arr"], Segment(.arrayString, ["a"])), (["conversation", "s"], Segment(.string, "x")),
                          (["start", "q"], Segment(.string, "q"))])
        func node(_ mode: String, _ assigned: String) throws -> VariableAssignerV1Node {
            try VariableAssignerV1Node(id: "v1", data: ["type": "assigner", "write_mode": .string(mode),
                                                        "assigned_variable_selector": ["conversation", .string(assigned)],
                                                        "input_variable_selector": ["start", "q"]])
        }
        let over = try await run(try node("over-write", "s"), p)
        #expect(over.updates.first?.1 == Segment(.string, "q") && over.result?.inputs == ["value": "q"])
        #expect(over.result?.processData == ["__updated_variables": [["name": "s", "selector": ["conversation", "s"], "value_type": "string",
                                                                      "new_value": "q"]]])
        #expect(try await run(try node("append", "arr"), p).updates.first?.1 == Segment(.arrayString, ["a", "q"]))
        let clear = try await run(try node("clear", "arr"), p)
        #expect(clear.updates.first?.1 == Segment(.arrayString, []) && clear.result?.inputs == ["value": []])
        await #expect(throws: NodeError.self) { _ = try await run(try node("append", "s"), p) }
        await #expect(throws: NodeError.self) { _ = try await run(try node("over-write", "missing"), p) }
        #expect(try node("clear", "s").blocksVariableOutput([["conversation", "s"]]))
        #expect(try node("clear", "s").variableMapping(graph: try GraphConfig(json: ["nodes": [], "edges": []])).map(\.key)
                == ["v1.#conversation.s#", "v1.#start.q#"])
    }

    @Test func factoryPicksTheVersion() async throws {
        let f = BuiltinNodeFactory(services: RuntimeServices())
        let g = try GraphConfig(json: ["nodes": [], "edges": []])
        let v1 = try await f.createNode(NodeConfig(id: "a", data: ["type": "assigner", "write_mode": "clear",
                                                                    "assigned_variable_selector": ["conversation", "x"],
                                                                    "input_variable_selector": []]), graph: g)
        #expect(v1 is VariableAssignerV1Node)
        let v2 = try await f.createNode(NodeConfig(id: "a", data: ["type": "assigner", "version": "2", "items": []]), graph: g)
        #expect(v2 is VariableAssignerV2Node)
    }

    // MARK: List operator

    func list(_ extra: JSONObject, variable: [String] = ["start", "xs"]) throws -> ListOperatorNode {
        var d: JSONObject = ["type": "list-operator", "variable": .array(variable.map(JSONValue.string)),
                             "filter_by": ["enabled": false, "conditions": []], "order_by": ["enabled": false, "key": "", "value": "asc"],
                             "limit": ["enabled": false, "size": 10]]
        for (k, v) in extra { d[k] = v }
        return try ListOperatorNode(id: "lo", data: d)
    }

    @Test func listFilterOrderLimitExtract() async throws {
        let p = try pool([(["start", "xs"], Segment(.arrayString, ["banana", "apple", "cherry", "avocado"])),
                          (["start", "ns"], Segment(.arrayNumber, [3, 1.5, 10, 2])), (["start", "pre"], Segment(.string, "a"))])
        let f = try await run(try list(["filter_by": ["enabled": true, "conditions": [["comparison_operator": "start with",
                                                                                     "value": "{{#start.pre#}}"]]],
                                        "order_by": ["enabled": true, "value": "desc"]]), p).result!
        #expect(f.outputs == ["result": ["avocado", "apple"], "first_record": "avocado", "last_record": "apple"])
        #expect(f.inputs == ["variable": ["banana", "apple", "cherry", "avocado"]] && f.processData == f.inputs)

        let n = try await run(try list(["filter_by": ["enabled": true, "conditions": [["comparison_operator": "≥", "value": "2"]]],
                                        "order_by": ["enabled": true, "value": "asc"], "limit": ["enabled": true, "size": 2]],
                                       variable: ["start", "ns"]), p).result!
        #expect(n.outputs["result"] == [2, 3])
        // Python's value[:-1] for the default size -1.
        let neg = try await run(try list(["limit": ["enabled": true, "size": -1]], variable: ["start", "ns"]), p).result!
        #expect(neg.outputs["result"] == [3, 1.5, 10])
        let ex = try await run(try list(["extract_by": ["enabled": true, "serial": "2"]]), p).result!
        #expect(ex.outputs == ["result": ["apple"], "first_record": "apple", "last_record": "apple"])
        let inFilter = try await run(try list(["filter_by": ["enabled": true, "conditions": [["comparison_operator": "in", "value": "applepie"]]]]), p).result!
        #expect(inFilter.outputs["result"] == ["apple"])
        let notEmpty = try await run(try list(["filter_by": ["enabled": true, "conditions": [["comparison_operator": "not contains", "value": "an"]]]]), p).result!
        #expect(notEmpty.outputs["result"] == ["apple", "cherry", "avocado"])
    }

    @Test func listEdgeCasesAndErrors() async throws {
        let p = try pool([(["start", "xs"], Segment(.arrayString, ["a", "b"])), (["start", "empty"], Segment(.arrayString, [])),
                          (["start", "objs"], Segment(.arrayObject, [["a": 1]])), (["start", "bs"], Segment(.arrayBoolean, [true, false, true]))])
        let empty = try await run(try list([:], variable: ["start", "empty"]), p).result!
        #expect(empty.status == .succeeded && empty.outputs == ["result": [], "first_record": nil, "last_record": nil]
                && empty.inputs == ["variable": []])
        let missing = try await run(try list([:], variable: ["start", "nope"]), p).result!
        #expect(missing.status == .failed && missing.error == "Variable not found for selector: ['start', 'nope']")
        let objs = try await run(try list([:], variable: ["start", "objs"]), p).result!
        #expect(objs.error == "Variable ['start', 'objs'] is not an array type, actual type: <class 'graphon.variables.variables.ArrayObjectVariable'>")
        let tooFar = try await run(try list(["extract_by": ["enabled": true, "serial": "3"]]), p).result!
        #expect(tooFar.status == .failed && tooFar.error == "Invalid serial index: must be <= 2, got 3" && tooFar.inputs == ["variable": ["a", "b"]])
        await #expect(throws: NodeError.self) { _ = try await run(try list(["extract_by": ["enabled": true, "serial": "0"]]), p) }
        let badOp = try await run(try list(["filter_by": ["enabled": true, "conditions": [["comparison_operator": ">", "value": "1"]]]]), p).result!
        #expect(badOp.error == "Invalid condition: >")
        let bools = try await run(try list(["filter_by": ["enabled": true, "conditions": [["comparison_operator": "is not", "value": true]]]],
                                           variable: ["start", "bs"]), p).result!
        #expect(bools.outputs["result"] == [false])
        await #expect(throws: NodeError.self) {
            _ = try await run(try list(["filter_by": ["enabled": true, "conditions": [["comparison_operator": "is", "value": "true"]]]],
                                       variable: ["start", "bs"]), p)
        }
        #expect(throws: NodeDataError.self) { _ = try ListOperatorNode(id: "x", data: ["type": "list-operator"]) }
    }
}
