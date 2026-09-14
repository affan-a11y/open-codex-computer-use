#if canImport(JavaScriptCore)
import Foundation
import JavaScriptCore

/// Splits a streaming JavaScript prefix into the pieces that may run now, using a
/// real parser (acorn, in its own JSContext). A complete statement is held while a
/// later token could still extend it: `if` without `else`, `try` without `finally`,
/// or an unterminated expression whose next token has not fully arrived
/// (JavaScript's own semicolon-insertion rules).
///
/// A program is written as one `try` per part, so waiting for whole top-level
/// statements means waiting for the part's fallback routes to finish generating
/// before its first action runs. The scan therefore steps *into* an open `try`:
/// its header, its body's statements, its `catch`/`finally` heads and its closing
/// brace come back as separate ops, and the runtime keeps the try's semantics
/// around them. Offsets are UTF-16 code units.
final class StreamStatementParser: @unchecked Sendable {  // the JSVirtualMachine lock serializes calls
    /// `run` executes the source up to `end`; the rest are the try's own edges.
    enum Kind: String {
        case run, openTry = "try", startCatch = "catch", startFinally = "finally", close
    }

    struct Op {
        let kind: Kind
        /// End offset (exclusive) of the text this op consumes.
        let end: Int
        /// The catch binding's name, when it has one.
        let name: String
    }

    struct Scan {
        let ops: [Op]
        /// The text after the last op is only whitespace/comments.
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

    /// `open`: how many `try` blocks the caller is already inside, so a leading
    /// `}` is read as one of their edges rather than a parse error.
    func scan(_ source: String, isFinal: Bool, open: Int = 0) -> Scan {
        guard let result = scanFunction.call(withArguments: [source, isFinal, open]) else {
            return Scan(ops: [], restIsBlank: false)
        }
        let raw = result.objectForKeyedSubscript("ops")?.toArray() as? [[String: Any]] ?? []
        let ops = raw.compactMap { op -> Op? in
            guard let kind = (op["k"] as? String).flatMap(Kind.init(rawValue:)),
                let end = (op["e"] as? NSNumber)?.intValue else { return nil }
            return Op(kind: kind, end: end, name: op["n"] as? String ?? "")
        }
        return Scan(ops: ops, restIsBlank: result.objectForKeyedSubscript("rest")?.toBool() ?? false)
    }

    private static let harness = """
    (function () {
      const OPTIONS = { ecmaVersion: 'latest', sourceType: 'script', allowReturnOutsideFunction: true,
                        allowAwaitOutsideFunction: true, allowHashBang: true, allowReserved: true };
      const EXPRESSION_WORDS = ['in', 'instanceof'];
      const EDGE_WORDS = ['catch', 'finally'];
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
      // The first few tokens, whitespace and comments already skipped.
      function tokens(src, limit) {
        const out = [];
        const p = new acorn.Parser(OPTIONS, src);
        try {
          for (let i = 0; i < limit; i++) {
            p.nextToken();
            const eof = p.type === acorn.tokTypes.eof;
            out.push({ eof: eof, label: p.type.label, keyword: p.type.keyword,
                       value: eof ? '' : String(p.value === undefined ? '' : p.value),
                       start: p.start, end: p.end });
            if (eof) break;
          }
        } catch (e) { /* a broken literal ends the lookahead */ }
        return out;
      }
      // `try {` at the head: its body's statements can run before the catch is written.
      function openTry(src) {
        const t = tokens(src, 2);
        if (t.length < 2 || t[0].keyword !== 'try' || t[1].label !== '{') return null;
        return { k: 'try', e: t[1].end };
      }
      // A `}` at the head closes the open try, or hands it to `catch`/`finally`.
      function closeTry(src, isFinal) {
        const t = tokens(src, 8);
        if (!t.length || t[0].label !== '}') return null;
        const next = t[1];
        if (!next || next.eof) return isFinal ? { k: 'close', e: t[0].end } : null;
        const word = next.keyword || (next.label === 'name' ? next.value : '');
        if (word === 'catch') {
          let i = 2, name = '';
          if (t[i] && t[i].label === '(') {
            if (!t[i + 1] || t[i + 1].eof) return null;
            name = t[i + 1].value;
            if (!t[i + 2] || t[i + 2].label !== ')') return null;
            i += 3;
          }
          if (!t[i] || t[i].label !== '{') return null;
          return { k: 'catch', e: t[i].end, n: name };
        }
        if (word === 'finally') {
          if (!t[2] || t[2].label !== '{') return null;
          return { k: 'finally', e: t[2].end };
        }
        // The next token is still streaming and could grow into catch or finally.
        if (!isFinal && next.end >= src.length && next.label === 'name' &&
            EDGE_WORDS.some(w => w.length > word.length && w.startsWith(word))) return null;
        return { k: 'close', e: next.label === ';' ? next.end : t[0].end };
      }
      globalThis.__ocuScan = function (src, isFinal, open) {
        const ops = [];
        let cursor = 0;
        let depth = open | 0;
        for (;;) {
          const rest = src.slice(cursor);
          const statements = collect(rest, true);
          let taken = 0;
          for (const s of statements) {
            if (!isFinal && s.words.length) {
              const n = s.next;
              if (n.eof) break;
              // The next token is still streaming and could grow into a continuation keyword.
              if (n.end >= rest.length && n.name !== null &&
                  s.words.some(w => w.length > n.name.length && w.startsWith(n.name))) break;
            }
            ops.push({ k: 'run', e: cursor + s.end });
            taken = s.end;
          }
          if (taken) { cursor += taken; continue; }
          if (statements.length) break;  // a complete statement waiting on its next token
          const edge = openTry(rest) || (depth ? closeTry(rest, isFinal) : null);
          if (!edge) break;
          ops.push({ k: edge.k, e: cursor + edge.e, n: edge.n || '' });
          depth += edge.k === 'try' ? 1 : edge.k === 'close' ? -1 : 0;
          cursor += edge.e;
        }
        let rest = false;
        if (isFinal) {
          // Only the final feed needs to know whether the leftover is just comments.
          try { rest = acorn.parse(src.slice(cursor), OPTIONS).body.length === 0; } catch (e) {}
        }
        return { ops: ops, rest: rest };
      };
    })();
    """
}
#endif
