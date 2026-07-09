//! Structural parser for tabula, a Clausewitz-style data format:
//!
//! ```text
//! legion = {
//!     name = "Legio I"        # comments run to end of line
//!     strength = 4800
//!     cohorts = { 1 2 3 }     # blocks can be array-like
//!     morale > 0.5            # comparison operators
//! }
//! legion = { name = "Legio II" }   # duplicate keys are legal
//! ```
//!
//! The parser is purely structural: keys, operators, atoms (scalars and
//! quoted strings), and nested blocks. No key has special meaning.
//!
//! Everything lives in an [`Arena`]: node storage, child slices, error
//! storage, and the key/value strings (copied out of the source). The tree
//! borrows only the arena — the source buffer can be dropped as soon as
//! `parse` returns — and the whole tree is freed with the arena.
//!
//! Parsing never fails: [`parse`] always returns a [`ParseResult`] holding
//! whatever tree could be recovered plus every error encountered.

use arena::{AVec, Arena};

/// What a node is. Zero value = `Atom` (with an empty `value`, that is
/// the ZII "nothing" node).
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum Kind {
    /// Scalar or quoted string; the text (and number, if numeric) is in
    /// `value`.
    #[default]
    Atom,
    /// `{ ... }`; contents are in `children`, `value` is empty.
    Block,
}

/// Operator between key and value. Zero value = `None`, meaning the node
/// is a bare value with no key (an array element).
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum Op {
    #[default]
    None,
    Eq, // =
    Lt, // <
    Gt, // >
    Le, // <=
    Ge, // >=
    Ne, // !=
}

/// One fat struct covers every syntactic form; unused fields stay at their
/// zero value.
///
/// | form            | key   | op     | kind    | value.text | children |
/// |-----------------|-------|--------|---------|------------|----------|
/// | `a = 1`         | `"a"` | `Eq`   | `Atom`  | `"1"`      | empty    |
/// | `a = "x"`       | `"a"` | `Eq`   | `Atom`  | `"x"`      | empty    |
/// | `a = { ... }`   | `"a"` | `Eq`   | `Block` | `""`       | items    |
/// | `a > 5`         | `"a"` | `Gt`   | `Atom`  | `"5"`      | empty    |
/// | bare `1`        | `""`  | `None` | `Atom`  | `"1"`      | empty    |
/// | bare `{ ... }`  | `""`  | `None` | `Block` | `""`       | items    |
///
/// `Node::default()` is a valid empty atom. No `Drop` anywhere, so nodes
/// live in the arena.
#[derive(Clone, Copy, Debug, Default)]
pub struct Node<'a> {
    pub key: &'a str,
    pub op: Op,
    pub kind: Kind,
    pub value: Value<'a>,
    pub children: &'a [Node<'a>],
}

/// An atom's value, fat-struct style: always the raw text, plus the parsed
/// number when an unquoted atom is numeric. Zero value = empty non-number.
#[derive(Clone, Copy, PartialEq, Debug, Default)]
pub struct Value<'a> {
    pub is_number: bool,
    pub text: &'a str,
    pub number: f32, // If is_number is false, can be whatever
}

impl<'a> Value<'a> {
    /// Value of an unquoted atom: fills `number` when the text parses as
    /// one. Quoted strings skip this — `"12"` stays text.
    pub fn from_text(text: &'a str) -> Value<'a> {
        let number = text.parse::<f32>();
        Value {
            is_number: number.is_ok(),
            text,
            number: number.unwrap_or(0.0),
        }
    }
}

impl<'a> core::fmt::Display for Value<'a> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        // `text` is always filled, even for numbers, and preserves the
        // source spelling (`4800` vs `4.8e3`).
        core::fmt::Display::fmt(self.text, f)
    }
}

impl<'a> Node<'a> {
    pub fn is_block(&self) -> bool {
        self.kind == Kind::Block
    }

    /// First child with this key.
    pub fn get(&self, key: &str) -> Option<&Node<'a>> {
        self.children.iter().find(|c| c.key == key)
    }

    /// All children with this key (duplicate keys are legal and common).
    pub fn get_all<'n>(&'n self, key: &'n str) -> impl Iterator<Item = &'n Node<'a>> {
        self.children.iter().filter(move |c| c.key == key)
    }

    /// `value` of the first child with this key, if it is an atom.
    pub fn get_value(&self, key: &str) -> Option<Value<'a>> {
        let node = self.get(key)?;
        (node.kind == Kind::Atom).then_some(node.value)
    }

    /// Text of the first child with this key, if it is an atom.
    pub fn get_text(&self, key: &str) -> Option<&'a str> {
        self.get_value(key).map(|v| v.text)
    }

    /// Number of the first child with this key, if it is a numeric atom.
    pub fn get_number(&self, key: &str) -> Option<f32> {
        self.get_value(key)
            .filter(|v| v.is_number)
            .map(|v| v.number)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum ErrorKind {
    /// Zero value: no error.
    #[default]
    None,
    UnexpectedChar,
    UnclosedString,
    UnclosedBlock,
    UnexpectedCloseBrace,
    ExpectedValue,
    TooDeep,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct ParseError {
    pub kind: ErrorKind,
    /// Byte offset into the source.
    pub offset: usize,
    /// 1-based.
    pub line: u32,
    /// 1-based, in bytes.
    pub col: u32,
}

impl core::fmt::Display for ParseError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        let msg = match self.kind {
            ErrorKind::None => "no error",
            ErrorKind::UnexpectedChar => "unexpected character",
            ErrorKind::UnclosedString => "unclosed string",
            ErrorKind::UnclosedBlock => "unclosed block",
            ErrorKind::UnexpectedCloseBrace => "unexpected '}'",
            ErrorKind::ExpectedValue => "expected a value",
            ErrorKind::TooDeep => "blocks nested too deeply",
        };
        write!(f, "{}:{}: {msg}", self.line, self.col)
    }
}

impl std::error::Error for ParseError {}

/// What [`parse`] produces: the recovered tree plus every error, in one
/// flat struct. Zero value = no roots, no errors.
///
/// `roots` are the file's top-level items — a file is a sequence of them,
/// not a single node. On errors the parser recovers and keeps going, so
/// `roots` holds whatever could still be parsed (possibly nothing).
#[derive(Clone, Copy, Debug, Default)]
pub struct ParseResult<'a> {
    pub roots: &'a [Node<'a>],
    pub errors: &'a [ParseError],
}

impl<'a> ParseResult<'a> {
    pub fn is_ok(&self) -> bool {
        self.errors.is_empty()
    }
}

const MAX_DEPTH: u32 = 500;
/// Past this, the source is junk; stop accumulating and finish.
const MAX_ERRORS: usize = 100;

/// Parse a whole source file. Never fails; see [`ParseResult`].
///
/// Everything in the result lives in `arena`.
pub fn parse<'a>(arena: &'a Arena, src: &str) -> ParseResult<'a> {
    let mut p = Parser {
        text: src,
        pos: 0,
        arena,
        errors: AVec::new_in(arena),
    };
    let roots = p.parse_items(0);
    ParseResult {
        roots,
        errors: p.errors.into_slice(),
    }
}

struct Parser<'a, 's> {
    text: &'s str,
    pos: usize,
    arena: &'a Arena,
    errors: AVec<'a, ParseError>,
}

/// Bytes that end a bare scalar. All ASCII, so slicing at them always
/// lands on a UTF-8 boundary.
fn is_terminator(b: u8) -> bool {
    matches!(
        b,
        b' ' | b'\t' | b'\r' | b'\n' | b'{' | b'}' | b'=' | b'<' | b'>' | b'!' | b'#' | b'"'
    )
}

impl<'a, 's> Parser<'a, 's> {
    /// Copy a source slice into the arena so nodes borrow only the arena.
    fn intern(&self, str: &str) -> &'a str {
        self.arena.alloc_str(str)
    }

    fn peek(&self) -> Option<u8> {
        self.text.as_bytes().get(self.pos).copied()
    }

    fn skip_trivia(&mut self) {
        let bytes = self.text.as_bytes();
        while let Some(&b) = bytes.get(self.pos) {
            match b {
                b' ' | b'\t' | b'\r' | b'\n' => self.pos += 1,
                b'#' => {
                    while let Some(&b) = bytes.get(self.pos) {
                        self.pos += 1;
                        if b == b'\n' {
                            break;
                        }
                    }
                }
                _ => return,
            }
        }
    }

    fn error(&self, kind: ErrorKind) -> ParseError {
        let (mut line, mut col) = (1u32, 1u32);
        for &b in &self.text.as_bytes()[..self.pos] {
            if b == b'\n' {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }
        }
        ParseError {
            kind,
            offset: self.pos,
            line,
            col,
        }
    }

    fn push_error(&mut self, error: ParseError) {
        self.errors.push(error);
        if self.errors.len() >= MAX_ERRORS {
            self.pos = self.text.len();
        }
    }

    fn record(&mut self, kind: ErrorKind) {
        let error = self.error(kind);
        self.push_error(error);
    }

    /// Skip past the offending input so parsing can continue: advance to
    /// the next whitespace or '}' (never consuming a '}', which may close
    /// an enclosing block).
    fn recover(&mut self) {
        let bytes = self.text.as_bytes();
        while let Some(&b) = bytes.get(self.pos) {
            if b == b'}' || b.is_ascii_whitespace() {
                return;
            }
            self.pos += 1;
        }
    }

    /// Items until EOF or an unconsumed '}' (at depth 0 a stray '}' is
    /// recorded and skipped instead). Infallible: item errors are recorded
    /// and recovered from.
    fn parse_items(&mut self, depth: u32) -> &'a [Node<'a>] {
        let mut items = AVec::new_in(self.arena);
        loop {
            self.skip_trivia();
            match self.peek() {
                None => break,
                Some(b'}') => {
                    if depth > 0 {
                        break;
                    }
                    self.record(ErrorKind::UnexpectedCloseBrace);
                    self.pos += 1;
                }
                _ => match self.parse_item(depth) {
                    Ok(node) => items.push(node),
                    Err(error) => {
                        self.push_error(error);
                        self.recover();
                    }
                },
            }
        }
        items.into_slice()
    }

    /// `term (op term)?` — a keyed pair or a bare value.
    fn parse_item(&mut self, depth: u32) -> Result<Node<'a>, ParseError> {
        let first = self.parse_term(depth)?;
        if first.kind != Kind::Block {
            self.skip_trivia();
            if let Some(op) = self.try_op()? {
                self.skip_trivia();
                let value = self.parse_term(depth)?;
                return Ok(Node {
                    key: first.value.text,
                    op,
                    ..value
                });
            }
        }
        Ok(first)
    }

    fn try_op(&mut self) -> Result<Option<Op>, ParseError> {
        let bytes = self.text.as_bytes();
        let trailing_eq = bytes.get(self.pos + 1) == Some(&b'=');
        let (op, len) = match self.peek() {
            Some(b'=') => (Op::Eq, 1),
            Some(b'<') if trailing_eq => (Op::Le, 2),
            Some(b'<') => (Op::Lt, 1),
            Some(b'>') if trailing_eq => (Op::Ge, 2),
            Some(b'>') => (Op::Gt, 1),
            Some(b'!') if trailing_eq => (Op::Ne, 2),
            Some(b'!') => return Err(self.error(ErrorKind::UnexpectedChar)),
            _ => return Ok(None),
        };
        self.pos += len;
        Ok(Some(op))
    }

    /// A keyless term: atom or block. `key`/`op` stay zero.
    fn parse_term(&mut self, depth: u32) -> Result<Node<'a>, ParseError> {
        match self.peek() {
            None | Some(b'}') => Err(self.error(ErrorKind::ExpectedValue)),
            Some(b'=') | Some(b'<') | Some(b'>') | Some(b'!') => {
                Err(self.error(ErrorKind::UnexpectedChar))
            }
            Some(b'{') => {
                if depth >= MAX_DEPTH {
                    return Err(self.error(ErrorKind::TooDeep));
                }
                self.pos += 1;
                let children = self.parse_items(depth + 1);
                if self.peek() == Some(b'}') {
                    self.pos += 1;
                } else {
                    // EOF inside the block: keep what we parsed.
                    self.record(ErrorKind::UnclosedBlock);
                }
                Ok(Node {
                    kind: Kind::Block,
                    children,
                    ..Node::default()
                })
            }
            Some(b'"') => {
                self.pos += 1;
                let start = self.pos;
                let bytes = self.text.as_bytes();
                while let Some(&b) = bytes.get(self.pos) {
                    if b == b'"' {
                        let text = self.intern(&self.text[start..self.pos]);
                        self.pos += 1;
                        // Quoted atoms are always textual, never numbers.
                        return Ok(Node {
                            value: Value {
                                text,
                                ..Value::default()
                            },
                            ..Node::default()
                        });
                    }
                    self.pos += 1;
                }
                Err(self.error(ErrorKind::UnclosedString))
            }
            Some(_) => {
                let start = self.pos;
                let bytes = self.text.as_bytes();
                while let Some(&b) = bytes.get(self.pos) {
                    if is_terminator(b) {
                        break;
                    }
                    self.pos += 1;
                }
                let text = self.intern(&self.text[start..self.pos]);
                Ok(Node {
                    value: Value::from_text(text),
                    ..Node::default()
                })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_one<'a>(arena: &'a Arena, src: &str) -> &'a [Node<'a>] {
        let result = parse(arena, src);
        assert!(result.is_ok(), "unexpected errors: {:?}", result.errors);
        result.roots
    }

    #[test]
    fn key_value_atoms() {
        let arena = Arena::new();
        let items = parse_one(&arena, "a = 1\nname = brutus\ndate = 1444.11.11");
        assert_eq!(items.len(), 3);
        assert_eq!(
            (items[0].key, items[0].op, items[0].value.text),
            ("a", Op::Eq, "1")
        );
        assert_eq!(items[1].value.text, "brutus");
        assert_eq!(items[2].value.text, "1444.11.11");
        assert!(items.iter().all(|n| n.kind == Kind::Atom));
    }

    #[test]
    fn numbers() {
        let arena = Arena::new();
        let items = parse_one(
            &arena,
            "a = 4800 b = -0.5 c = brutus d = \"12\" e = 1444.11.11",
        );
        let value = |i: usize| items[i].value;
        assert!(value(0).is_number && value(0).number == 4800.0);
        assert!(value(1).is_number && value(1).number == -0.5);
        assert!(!value(2).is_number);
        assert!(!value(3).is_number, "quoted numbers stay text");
        assert!(!value(4).is_number, "dates are not numbers");
        assert_eq!(value(4).text, "1444.11.11");
    }

    #[test]
    fn value_display() {
        let arena = Arena::new();
        let items = parse_one(&arena, "a = 4800 b = \"Ave, Roma\"");
        assert_eq!(items[0].value.to_string(), "4800");
        assert_eq!(format!("{:>10}", items[1].value), " Ave, Roma");
    }

    #[test]
    fn quoted_strings() {
        let arena = Arena::new();
        let items = parse_one(&arena, r#"title = "Ave, Roma" "bare string""#);
        assert_eq!(
            (items[0].kind, items[0].value.text),
            (Kind::Atom, "Ave, Roma")
        );
        assert_eq!(
            (items[1].key, items[1].kind, items[1].value.text),
            ("", Kind::Atom, "bare string")
        );
    }

    #[test]
    fn nested_blocks_and_arrays() {
        let arena = Arena::new();
        let items = parse_one(
            &arena,
            "legion = { name = \"Legio I\" strength = 4800 cohorts = { 1 2 3 } camp = { site = rome } }",
        );
        let legion = &items[0];
        assert!(legion.is_block());
        assert_eq!(legion.get_text("name"), Some("Legio I"));
        assert_eq!(legion.get_number("strength"), Some(4800.0));
        assert_eq!(legion.get_number("name"), None, "text atom is not a number");

        let cohorts = legion.get("cohorts").unwrap();
        let vals: Vec<_> = cohorts.children.iter().map(|c| c.value.number).collect();
        assert_eq!(vals, [1.0, 2.0, 3.0]);
        assert!(
            cohorts
                .children
                .iter()
                .all(|c| c.key.is_empty() && c.op == Op::None)
        );

        assert_eq!(legion.get("camp").unwrap().get_text("site"), Some("rome"));
    }

    #[test]
    fn duplicate_keys() {
        let arena = Arena::new();
        let items = parse_one(&arena, "root = { option = { x = 1 } option = { x = 2 } }");
        let opts: Vec<_> = items[0].get_all("option").collect();
        assert_eq!(opts.len(), 2);
        assert_eq!(opts[1].get_text("x"), Some("2"));
    }

    #[test]
    fn comparison_operators() {
        let arena = Arena::new();
        let items = parse_one(&arena, "a > 1 b < 2 c >= 3 d <= 4 e != 5 f = 6");
        let ops: Vec<_> = items.iter().map(|n| n.op).collect();
        assert_eq!(ops, [Op::Gt, Op::Lt, Op::Ge, Op::Le, Op::Ne, Op::Eq]);
    }

    #[test]
    fn comments_and_whitespace() {
        let arena = Arena::new();
        let items = parse_one(
            &arena,
            "# header\na = 1 # trailing\n\n\t b = 2\n# eof comment",
        );
        assert_eq!(items.len(), 2);
        assert_eq!(items[1].value.text, "2");
    }

    #[test]
    fn anonymous_blocks_and_empty_block() {
        let arena = Arena::new();
        let items = parse_one(&arena, "{ 1 2 } empty = { }");
        assert_eq!((items[0].key, items[0].kind), ("", Kind::Block));
        assert_eq!(items[0].children.len(), 2);
        assert!(items[1].is_block() && items[1].children.is_empty());
    }

    #[test]
    fn quoted_keys() {
        let arena = Arena::new();
        let items = parse_one(&arena, r#""my key" = value"#);
        assert_eq!((items[0].key, items[0].value.text), ("my key", "value"));
    }

    #[test]
    fn empty_input() {
        let arena = Arena::new();
        assert!(parse_one(&arena, "").is_empty());
        assert!(parse_one(&arena, "  # just a comment").is_empty());
    }

    #[test]
    fn tree_outlives_source() {
        let arena = Arena::new();
        let items = {
            let src = String::from("a = { b = \"hi\" }");
            parse_one(&arena, &src)
            // src dropped here; the tree must not borrow it
        };
        assert_eq!(items[0].get_text("b"), Some("hi"));
    }

    #[test]
    fn zii_default_node() {
        let node = Node::default();
        assert_eq!(
            (node.key, node.op, node.kind, node.value.text),
            ("", Op::None, Kind::Atom, "")
        );
        assert!(!node.value.is_number);
        assert!(node.children.is_empty());
    }

    #[test]
    fn zii_default_result() {
        let result = ParseResult::default();
        assert!(result.is_ok());
        assert!(result.roots.is_empty());
    }

    #[test]
    fn errors() {
        let arena = Arena::new();
        let kind = |src| parse(&arena, src).errors[0].kind;
        assert_eq!(kind("a = { b = 1"), ErrorKind::UnclosedBlock);
        assert_eq!(kind("a = \"oops"), ErrorKind::UnclosedString);
        assert_eq!(kind("} b = 1"), ErrorKind::UnexpectedCloseBrace);
        assert_eq!(kind("a = }"), ErrorKind::ExpectedValue);
        assert_eq!(kind("a ="), ErrorKind::ExpectedValue);
        assert_eq!(kind("= 1"), ErrorKind::UnexpectedChar);
        assert_eq!(kind("a ! b"), ErrorKind::UnexpectedChar);
    }

    #[test]
    fn error_position() {
        let arena = Arena::new();
        let result = parse(&arena, "a = 1\nb = \"unclosed");
        assert_eq!(
            (result.errors[0].line, result.errors[0].kind),
            (2, ErrorKind::UnclosedString)
        );
    }

    #[test]
    fn recovery_keeps_parsing() {
        let arena = Arena::new();
        let result = parse(&arena, "a = 1\n= oops\nb = 2");
        assert!(!result.is_ok());
        assert_eq!(result.errors[0].kind, ErrorKind::UnexpectedChar);
        // 'a = 1', bare 'oops', 'b = 2' — the bad '=' is skipped.
        let items = result.roots;
        assert_eq!(items.len(), 3);
        assert_eq!((items[0].key, items[0].value.text), ("a", "1"));
        assert_eq!((items[2].key, items[2].value.text), ("b", "2"));
    }

    #[test]
    fn recovery_keeps_partial_block() {
        let arena = Arena::new();
        let result = parse(&arena, "a = { b = 1"); // EOF inside block
        assert_eq!(
            result.errors,
            [ParseError {
                kind: ErrorKind::UnclosedBlock,
                offset: 11,
                line: 1,
                col: 12,
            }]
        );
        // The partial block is still in the tree.
        assert_eq!(result.roots[0].get_text("b"), Some("1"));
    }

    #[test]
    fn junk_input_does_not_loop_or_panic() {
        let arena = Arena::new();
        for src in ["}}}}", "= = = =", "{{{", "a = = 1", "!!!", "\"", "{ } }"] {
            let result = parse(&arena, src);
            assert!(!result.is_ok(), "expected errors for {src:?}");
        }
    }

    #[test]
    fn utf8_in_atoms() {
        let arena = Arena::new();
        let items = parse_one(&arena, "città = \"Römisches Reich\" 皇帝 = 帝国");
        assert_eq!(items[0].key, "città");
        assert_eq!(items[0].value.text, "Römisches Reich");
        assert_eq!((items[1].key, items[1].value.text), ("皇帝", "帝国"));
    }
}
