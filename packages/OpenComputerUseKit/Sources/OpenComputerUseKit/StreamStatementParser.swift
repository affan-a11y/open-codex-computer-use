#if canImport(JavaScriptCore)
import Foundation
import JavaScriptCore

/// Splits a streaming JavaScript prefix into the top-level statements that may
/// run now, using a real parser (acorn, in its own JSContext). A complete
/// statement is held while a later token could still extend it: `if` without
/// `else`, `try` without `finally`, or an unterminated expression whose next
/// token has not fully arrived (JavaScript's own semicolon-insertion rules).
/// Offsets are UTF-16 code units.
final class StreamStatementParser: @unchecked Sendable {  // the JSVirtualMachine lock serializes calls
    struct Scan {
        /// End offsets (exclusive) of the statements that may run now, in order.
        let ends: [Int]
        /// The text after the last complete statement is only whitespace/comments.
        let restIsBlank: Bool
    }

    /// One parser per process: the VM serializes access, and loading acorn costs
    /// a few milliseconds and ~1 MB, which no runtime needs to repeat.
    static let shared = StreamStatementParser()

    private let context: JSContext
    private let scanFunction: JSValue

    private init() {
        context = JSContext(virtualMachine: JSVirtualMachine())
        context.evaluateScript(acornJavaScriptSource)
        context.evaluateScript(Self.harness)
        scanFunction = context.objectForKeyedSubscript("__ocuScan")
    }

    /// Returns the runnable ends; the last element is -1 when the final feed's
    /// leftover text is only whitespace/comments.
    func scan(_ source: String, isFinal: Bool) -> Scan {
        guard var ends = scanFunction.call(withArguments: [source, isFinal])?.toArray() as? [Int] else {
            return Scan(ends: [], restIsBlank: false)
        }
        let restIsBlank = ends.last == -1
        if restIsBlank { ends.removeLast() }
        return Scan(ends: ends, restIsBlank: restIsBlank)
    }

    private static let harness = """
    (function () {
      const OPTIONS = { ecmaVersion: 'latest', sourceType: 'script', allowReturnOutsideFunction: true,
                        allowAwaitOutsideFunction: true, allowHashBang: true, allowReserved: true };
      const EXPRESSION_WORDS = ['in', 'instanceof'];
      // Keywords that could still extend a complete statement; [] means it is closed.
      function words(node, src) {
        switch (node.type) {
          case 'IfStatement': return node.alternate ? words(node.alternate, src) : ['else'];
          case 'TryStatement': return node.finalizer ? [] : ['finally'];
          case 'ForStatement': case 'ForInStatement': case 'ForOfStatement':
          case 'WhileStatement': case 'WithStatement': case 'LabeledStatement': return words(node.body, src);
          case 'BlockStatement': case 'FunctionDeclaration': case 'ClassDeclaration':
          case 'SwitchStatement': case 'EmptyStatement': case 'DoWhileStatement': return [];
          default: return src.charCodeAt(node.end - 1) === 59 ? [] : EXPRESSION_WORDS;  // 59 = ';'
        }
      }
      // Complete top-level statements at the head of src, each with the token after it.
      // A parse error ends the list; if it is a broken literal after a complete statement
      // (the lookahead failed), retry on the text before it so that statement is kept.
      const EXPORTS = Object.create(null);
      function collect(src, retry) {
        const out = [];
        const p = new acorn.Parser(OPTIONS, src);
        try {
          p.nextToken();
          while (p.type !== acorn.tokTypes.eof) {
            const node = p.parseStatement(null, true, EXPORTS);
            const next = { eof: p.type === acorn.tokTypes.eof, end: p.end,
                           name: (p.type.label === 'name' || p.type.keyword) ? String(p.value) : null };
            if (node.type === 'EmptyStatement' && out.length) {
              const prev = out[out.length - 1];
              prev.end = node.end; prev.words = []; prev.next = next;
              continue;
            }
            out.push({ end: node.end, words: words(node, src), next });
          }
        } catch (e) {
          const last = out.length ? out[out.length - 1].end : 0;
          if (retry && typeof e.pos === 'number' && e.pos > last && e.pos < src.length) {
            return collect(src.slice(0, e.pos), false);
          }
        }
        return out;
      }
      globalThis.__ocuScan = function (src, isFinal) {
        const statements = collect(src, true);
        const ends = [];
        for (const s of statements) {
          if (!isFinal && s.words.length) {
            const n = s.next;
            if (n.eof) break;
            // The next token is still streaming and could grow into a continuation keyword.
            if (n.end >= src.length && n.name !== null &&
                s.words.some(w => w.length > n.name.length && w.startsWith(n.name))) break;
          }
          ends.push(s.end);
        }
        if (isFinal) {
          // Only the final feed needs to know whether the leftover is just comments.
          const restStart = statements.length ? statements[statements.length - 1].end : 0;
          try { if (acorn.parse(src.slice(restStart), OPTIONS).body.length === 0) ends.push(-1); } catch (e) {}
        }
        return ends;
      };
    })();
    """
}
#endif
