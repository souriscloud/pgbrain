import XCTest
import PostgresNIO
@testable import pgBrain

@MainActor
final class FunctionInspectorTests: XCTestCase {

    // Exact argument string PG reports — fed back into FunctionNode.arguments
    // so FunctionInspector's overload match succeeds.
    private func argString(_ db: TestDB, _ s: String, _ name: String) async throws -> String {
        try await db.scalarString("""
        SELECT pg_get_function_arguments(p.oid)
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = '\(s)' AND p.proname = '\(name)' LIMIT 1
        """)
    }

    private func node(_ s: String, _ name: String, kind: FunctionNode.Kind, args: String) -> FunctionNode {
        FunctionNode(schema: s, name: name, kind: kind, arguments: "(\(args))", returnType: "")
    }

    func testVolatilityMapping() {
        XCTAssertEqual(FunctionInspector.Volatility(proChar: "i"), .immutable)
        XCTAssertEqual(FunctionInspector.Volatility(proChar: "s"), .stable)
        XCTAssertEqual(FunctionInspector.Volatility(proChar: "v"), .volatile)
        XCTAssertEqual(FunctionInspector.Volatility(proChar: "?"), .volatile)
        XCTAssertEqual(FunctionInspector.Volatility.allCases.count, 3)
        for v in FunctionInspector.Volatility.allCases { XCTAssertEqual(v.id, v.rawValue) }
    }

    func testInspectorErrorDescriptions() {
        XCTAssertEqual(FunctionInspector.InspectorError.notConnected.errorDescription, "Not connected.")
        XCTAssertEqual(FunctionInspector.InspectorError.notFound.errorDescription,
                       "Function not found — it may have been dropped.")
    }

    func testFetchSimpleFunction() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE FUNCTION "\(s)".f(a int) RETURNS int LANGUAGE sql AS 'SELECT a + 1';
            """)
            let args = try await argString(db, s, "f")
            let def = try await FunctionInspector.fetch(client: db.client, function: node(s, "f", kind: .function, args: args))
            XCTAssertEqual(def.language, "sql")
            XCTAssertEqual(def.returnType, "integer")
            XCTAssertEqual(def.body, "SELECT a + 1")
            XCTAssertEqual(def.volatility, .volatile)
            XCTAssertFalse(def.isStrict)
            XCTAssertFalse(def.securityDefiner)
            XCTAssertEqual(def.kind, .function)
            XCTAssertTrue(def.isStructurallySimple, "plain SQL function with default attrs")
            XCTAssertFalse(def.identityArguments.isEmpty)
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    func testFetchProcedureHasEmptyReturnType() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE PROCEDURE "\(s)".p() LANGUAGE sql AS 'SELECT 1';
            """)
            let def = try await FunctionInspector.fetch(client: db.client, function: node(s, "p", kind: .procedure, args: ""))
            XCTAssertEqual(def.kind, .procedure)
            XCTAssertEqual(def.returnType, "", "pg_get_function_result is NULL for procedures")
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    func testFetchAttributesAndNotStructurallySimple() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE FUNCTION "\(s)".g() RETURNS int LANGUAGE sql
              IMMUTABLE STRICT SECURITY DEFINER SET search_path = pg_catalog AS 'SELECT 1';
            """)
            let def = try await FunctionInspector.fetch(client: db.client, function: node(s, "g", kind: .function, args: ""))
            XCTAssertEqual(def.volatility, .immutable)
            XCTAssertTrue(def.isStrict)
            XCTAssertTrue(def.securityDefiner)
            // A SET clause (proconfig) means the structured editor can't round-trip it.
            XCTAssertFalse(def.isStructurallySimple)
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    func testFetchNotFoundThrows() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("CREATE SCHEMA \"\(s)\"")
            // No such function → the arguments match finds nothing → notFound.
            do {
                _ = try await FunctionInspector.fetch(client: db.client, function: node(s, "ghost", kind: .function, args: ""))
                XCTFail("expected notFound")
            } catch FunctionInspector.InspectorError.notFound {
                // expected
            }
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    func testParametersIncludesDefaultsAndVariadic() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            // A VARIADIC arg can't follow a defaulted one, so split the two
            // cases across two functions.
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE FUNCTION "\(s)".hd(a int, b text DEFAULT 'z') RETURNS int LANGUAGE sql AS 'SELECT a';
            CREATE FUNCTION "\(s)".hv(a int, VARIADIC c int[]) RETURNS int LANGUAGE sql AS 'SELECT a';
            """)
            let argsD = try await argString(db, s, "hd")
            let paramsD = try await FunctionInspector.parameters(client: db.client, function: node(s, "hd", kind: .function, args: argsD))
            XCTAssertEqual(paramsD.map(\.name), ["a", "b"])
            XCTAssertEqual(paramsD.map(\.mode), ["IN", "IN"])

            let a = try XCTUnwrap(paramsD.first { $0.name == "a" })
            XCTAssertEqual(a.type, "integer")
            XCTAssertFalse(a.hasDefault)

            let b = try XCTUnwrap(paramsD.first { $0.name == "b" })
            XCTAssertTrue(b.hasDefault)
            XCTAssertNotNil(b.defaultExpr)

            let argsV = try await argString(db, s, "hv")
            let paramsV = try await FunctionInspector.parameters(client: db.client, function: node(s, "hv", kind: .function, args: argsV))
            // information_schema has no VARIADIC concept — it reports mode 'IN'.
            XCTAssertEqual(paramsV.count, 2)
            // int[] → data_type 'ARRAY', so the label falls back to udt_name.
            let c = try XCTUnwrap(paramsV.first { $0.name == "c" })
            XCTAssertEqual(c.type, "_int4")
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }
}
