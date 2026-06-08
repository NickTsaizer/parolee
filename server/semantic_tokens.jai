// ── Semantic Tokens ──────────────────────────────────────────────────────
// LSP semantic highlighting from flat AST node list + comment buffer.
// Architecture:
//   Handler  →  Collector (walks nodes+comments)  →  Sorter  →  Deduper  →  DeltaEncoder  →  LSP respond
//   Handler delegates to shared pipeline; range variant adds line filter.
//
// Token type indices correspond to SEMANTIC_TOKEN_TYPES in lsp_interface.jai

// ── Token type constants ─────────────────────────────────────────────────

TOKEN_TYPE_NAMESPACE     :: 0;
TOKEN_TYPE_TYPE          :: 1;
TOKEN_TYPE_ENUM          :: 3;
TOKEN_TYPE_STRUCT        :: 5;
TOKEN_TYPE_TYPE_PARAM    :: 6;
TOKEN_TYPE_PARAMETER     :: 7;
TOKEN_TYPE_VARIABLE      :: 8;
TOKEN_TYPE_PROPERTY      :: 9;
TOKEN_TYPE_ENUM_MEMBER   :: 10;
TOKEN_TYPE_FUNCTION      :: 11;
TOKEN_TYPE_MACRO         :: 13;
TOKEN_TYPE_KEYWORD       :: 14;
TOKEN_TYPE_MODIFIER      :: 15;
TOKEN_TYPE_COMMENT       :: 16;
TOKEN_TYPE_STRING        :: 17;
TOKEN_TYPE_NUMBER        :: 18;
TOKEN_TYPE_OPERATOR      :: 19;
TOKEN_TYPE_DECORATOR     :: 20;

// ── Modifier bitmasks ── indices into SEMANTIC_TOKEN_MODIFIERS

MODIFIER_DECLARATION     :: 1 << 0;
MODIFIER_DEFINITION      :: 1 << 1;
MODIFIER_READONLY        :: 1 << 2;
MODIFIER_STATIC          :: 1 << 3;
MODIFIER_DEPRECATED      :: 1 << 4;
MODIFIER_ABSTRACT        :: 1 << 5;
MODIFIER_DEFAULT_LIBRARY :: 1 << 9;

// ── Types ────────────────────────────────────────────────────────────────

Token_Entry :: struct {
    line: u32;
    character: u32;
    length: u32;
    token_type: u32;
    token_modifiers: u32;
}

Token_Span :: struct { line: int; col: int; length: int; }

// ── Handler pipeline: full + range ──────────────────────────────────────
// Both delegates to build_semantic_tokens with optional line bounds.

handle_semantic_tokens_full :: (request: LSP_Request_Message_SemanticTokens) {
    build_semantic_tokens(request.id, request.params.textDocument.uri, .{}, .{});
}

handle_semantic_tokens_range :: (request: LSP_Request_Message_SemanticTokens_Range) {
    r := request.params.range;
    lsp_start: Node.Location = .{l0=r.start.line, c0=r.start.character, l1=r.start.line, c1=r.start.character};
    lsp_end: Node.Location = .{l0=r.end.line, c0=r.end.character, l1=r.end.line, c1=r.end.character};
    build_semantic_tokens(request.id, request.params.textDocument.uri, lsp_start, lsp_end);
}

build_semantic_tokens :: (id: JSON_Value, uri: string, range_start: Node.Location, range_end: Node.Location) {
    if server.token_busy { lsp_respond(id, null); return; }
    server.token_busy = true;
    defer server.token_busy = false;

    push_allocator(temp);

    file_path := normalize_path(uri);
    file := get_file(file_path);
    if !file {
        log_error("SemanticTokens: file not parsed yet: %", file_path);
        lsp_respond(id, null);
        return;
    }

    has_range := range_start.l0 > 0 || range_end.l0 > 0;

    // Collect all tokens (range-aware: skips nodes outside bounds)
    entries: [..]Token_Entry;
    collect_tokens(file, *entries, range_start, range_end, has_range);

    // Sort by (line, character) for delta encoding
    sort_token_entries(entries);

    // Dedup adjacent duplicates
    dedup_token_entries(*entries);

    // For range requests, also clip by character bounds
    if has_range {
        clip_range(entries, *entries, range_start, range_end);
    }

    delta_encode_and_respond(entries, id);
}

// ── Token collection ────────────────────────────────────────────────────
// Unified collector: when has_range is true, early-skips nodes outside
// [line_start, line_end] using node.location (nodes are in file order).

collect_tokens :: (file: *Program_File, entries: *[..]Token_Entry,
                   range_start: Node.Location, range_end: Node.Location, has_range: bool)
{
    // Nodes — flat AST list
    for node: file.nodes {
        if has_range {
            loc := node.location;
            if loc.l1 < xx range_start.l0 continue;  // ends before range
            if loc.l0 > xx range_end.l0 break;        // starts after range (file order)
        }
        emit_node_token(node, entries);
    }

    // Comments — lexer buffer
    for comment: file.comments {
        if comment.l0 != comment.l1 continue;  // skip multi-line
        if has_range {
            if comment.l0 < xx range_start.l0 || comment.l0 > xx range_end.l0 continue;
        }
        add_entry(xx comment.l0, xx comment.c0, xx (comment.c1 - comment.c0), TOKEN_TYPE_COMMENT, 0, entries);
    }
}

emit_node_token :: (node: *Node, entries: *[..]Token_Entry) {
    if !node return;

    token_type, modifiers, got := classify_node(node);
    if got {
        span := token_span(node, token_type);
        if span.length > 0 {
            add_entry(span.line, span.col, span.length, token_type, modifiers, entries);
        }
    }

    // Side-tokens emitted alongside main node
    emit_declaration_operator(node, entries);
    emit_directive_string(node, entries);
}

// ── Token span ──────────────────────────────────────────────────────────
// Computes highlightable span for a classified node.
// Varies by node kind: Declaration uses name, Keyword uses computed length,
// Operators use the operator character, everything else uses raw location.

token_span :: (node: *Node, token_type: u32) -> Token_Span {
    loc := node.location;
    col := loc.c0;
    len := loc.c1 - loc.c0;

    if node.kind == .DECLARATION {
        decl := cast(*Declaration) node;
        len = decl.name.count;
    } else if token_type == TOKEN_TYPE_KEYWORD {
        len = keyword_length(node);
    } else if token_type == TOKEN_TYPE_OPERATOR {
        if node.kind == .BINARY_OPERATION {
            bin := cast(*Binary_Operation) node;
            if bin.left && bin.right && bin.left.location.c1 > 0 && bin.right.location.c0 > bin.left.location.c1 {
                col = bin.left.location.c1;
                len = bin.right.location.c0 - bin.left.location.c1;
            } else { len = 0; }
        } else if node.kind == .UNARY_OPERATION {
            u := cast(*Unary_Operation) node;
            if u.expression && u.expression.location.c0 > col {
                len = u.expression.location.c0 - col;
            }
        }
    }

    // Multi-line tokens: skip unless they're declarations, keywords, or macros
    // (those use name/computed length, not raw span)
    if loc.l0 != loc.l1 && node.kind != .DECLARATION
        && token_type != TOKEN_TYPE_KEYWORD && token_type != TOKEN_TYPE_MACRO
    {
        len = 0;
    }

    return .{loc.l0, col, len};
}

keyword_length :: (node: *Node) -> int {
    if node.kind == {
        case .RETURN; return 6;
        case .FOR; return 3;
        case .WHILE; return 5;
        case .IF; return 2;
        case .BREAK; return 5;
        case .CONTINUE; return 8;
        case .DEFER; return 5;
        case .REMOVE; return 6;
        case .CAST; return 4;
        case .USING; return 5;
        case .STRUCT; return 6;
        case .ENUM; return 4;
        case .UNION; return 5;
        case .CASE; return 4;
        case .OPERATOR_OVERLOAD; return 8;
        case .INLINE_ASSEMBLY; return 6;
    }
    return node.location.c1 - node.location.c0;
}

// ── Side-token emitters ──────────────────────────────────────────────────
// Emit extra token entries for declaration operators (::, :) and
// directive string arguments (#import "path", #load "path").

emit_declaration_operator :: (node: *Node, entries: *[..]Token_Entry) {
    if node.kind == .DECLARATION {
        decl := cast(*Declaration) node;
        op_col := decl.location.c0 + decl.name.count;
        op_len := 2;
        if decl.type_inst {
            // name : Type or name : Type = expr — single colon
            op_len = 1;
            op_col = decl.location.c0 + decl.name.count;
        } else {
            // name :: expr or name := expr — double operator (::, :=)
            op_col += 1;
            // op_len stays 2
        }
        add_entry(xx decl.location.l0, xx op_col, xx op_len, TOKEN_TYPE_OPERATOR, 0, entries);
    }
    if node.kind == .COMPOUND_DECLARATION {
        cd := cast(*Compound_Declaration) node;
        if cd.type_inst {
            // Determine operator length from AST
            op_len := 1;
            if cd.const {
                op_len = 2;  // ::
            } else if !cd.type_inst.type_inst {
                op_len = 2;  // :=
            }
            // Determine operator position from source text.
            // cd.type_inst.location is zeroed (auto-generated Declaration),
            // but cd.type_inst.expression / .type_inst have real parser locations.
            rhs: *Node = cd.type_inst.type_inst;
            if !rhs { rhs = cd.type_inst.expression; }
            if rhs && rhs.location.c0 > 0 {
                lsp_pos: LSP_Position;
                lsp_pos.line = cast(u32) rhs.location.l0;
                lsp_pos.character = 0;
                line_text := find_line_in_memory_file(rhs.location.file, lsp_pos);
                if line_text.count > 0 {
                    search_from := rhs.location.c0 - 4;
                    if search_from < 0 { search_from = 0; }
                    search_to := rhs.location.c0;
                    if search_to > line_text.count { search_to = line_text.count; }
                    if search_from < search_to {
                        for i: search_from..search_to - 1 {
                            if line_text[i] == #char ":" {
                                add_entry(xx rhs.location.l0, xx i, xx op_len, TOKEN_TYPE_OPERATOR, 0, entries);
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
}

emit_directive_string :: (node: *Node, entries: *[..]Token_Entry) {
    if node.kind == .DIRECTIVE_IMPORT {
        di := cast(*Directive_Import) node;
        if di.module.count > 0 {
            start := node.location.c1 - di.module.count - 2;  // quotes
            if start >= 0 {
                add_entry(xx node.location.l0, xx start, xx (di.module.count + 2), TOKEN_TYPE_STRING, 0, entries);
            }
        }
    }
    if node.kind == .DIRECTIVE_LOAD {
        dl := cast(*Directive_Load) node;
        if dl.file.count > 0 {
            start := node.location.c1 - dl.file.count - 2;
            if start >= 0 {
                add_entry(xx node.location.l0, xx start, xx (dl.file.count + 2), TOKEN_TYPE_STRING, 0, entries);
            }
        }
    }
}

add_entry :: (line: int, col: int, len: int, tt: u32, mod: u32, entries: *[..]Token_Entry) {
    if len <= 0 return;
    if col < 0 return;   // negative col = bogus position, skip
    if line < 0 return;  // negative line = bogus position, skip
    entry: Token_Entry = .{line=xx line, character=xx col, length=xx len, token_type=tt, token_modifiers=mod};
    array_add(entries, entry);
}

// ── Node classification ──────────────────────────────────────────────────
// classify_node dispatches by node.kind into specialized classifiers.
// Each returns (token_type, modifiers, found).

classify_node :: (node: *Node) -> u32, u32, bool {
    parent := node.parent;

    if node.kind == {
        case .DECLARATION;
            tt, mod, _ := classify_declaration(node, parent);
            return tt, mod, true;
        case .IDENTIFIER;
            tt, mod, _ := classify_identifier(node, parent);
            return tt, mod, true;
        case .LITERAL;
            tt, mod, _ := classify_literal(node);
            return tt, mod, true;
        case .COMMENT;
            return TOKEN_TYPE_COMMENT, 0, true;
        case .NOTE;
            return TOKEN_TYPE_DECORATOR, 0, true;
        case .DIRECTIVE_IMPORT;  #through;
        case .DIRECTIVE_LOAD;    #through;
        case .DIRECTIVE_RUN;     #through;
        case .DIRECTIVE_AS;      #through;
        case .DIRECTIVE_PLACE;   #through;
        case .DIRECTIVE_OVERLAY; #through;
        case .DIRECTIVE_TYPE;    #through;
        case .DIRECTIVE_CODE;    #through;
        case .DIRECTIVE_ADD_CONTEXT;          #through;
        case .DIRECTIVE_ASSERT;               #through;
        case .DIRECTIVE_BYTES;                #through;
        case .DIRECTIVE_LIBRARY;              #through;
        case .DIRECTIVE_NO_RESET;             #through;
        case .DIRECTIVE_INSERT;               #through;
        case .DIRECTIVE_LOCATION;             #through;
        case .DIRECTIVE_MODULE_PARAMETERS;    #through;
        case .DIRECTIVE_PLACEHOLDER;          #through;
        case .DIRECTIVE_PROCEDURE_OF_CALL;    #through;
        case .DIRECTIVE_PROCEDURE_NAME;       #through;
        case .DIRECTIVE_PROGRAM_EXPORT;       #through;
        case .DIRECTIVE_THIS;                 #through;
        case .DIRECTIVE_POKE_NAME;            #through;
        case .DIRECTIVE_BAKE_ARGUMENTS;       #through;
        case .DIRECTIVE_BAKE_CONSTANTS;       #through;
        case .DIRECTIVE_DYNAMIC_SPECIALIZE;   #through;
        case .DIRECTIVE_CALLER_CODE;          #through;
        case .DIRECTIVE_CALLER_LOCATION;      #through;
        case .DIRECTIVE_FILE;                 #through;
        case .DIRECTIVE_FILEPATH;             #through;
        case .DIRECTIVE_LINE;                 #through;
        case .DIRECTIVE_THROUGH;              #through;
        case .DIRECTIVE_SCOPE;                #through;
        case .DIRECTIVE_CHAR;                 #through;
        case .DIRECTIVE_COMPILE_TIME;         #through;
        case .DIRECTIVE_DISCARD;              #through;
        case .DIRECTIVE_EXISTS;               #through;
        case .DIRECTIVE_CONTEXT;              #through;
        case .DIRECTIVE_STRING;
            return TOKEN_TYPE_MACRO, 0, true;
        case .RETURN;            #through;
        case .FOR;               #through;
        case .WHILE;             #through;
        case .IF;                #through;
        case .BREAK;             #through;
        case .CONTINUE;          #through;
        case .DEFER;             #through;
        case .REMOVE;            #through;
        case .CAST;              #through;
        case .CASE;              #through;
        case .USING;             #through;
        case .STRUCT;            #through;
        case .ENUM;              #through;
        case .UNION;             #through;
        case .OPERATOR_OVERLOAD; #through;
        case .INLINE_ASSEMBLY;
            return TOKEN_TYPE_KEYWORD, 0, true;
        case .BINARY_OPERATION;  #through;
        case .UNARY_OPERATION;   #through;
        case .QUICK_LAMBDA;
            return TOKEN_TYPE_OPERATOR, 0, true;
    }

    return 0, 0, false;
}

// ── Declaration classification ──────────────────────────────────────────

declaration_type :: (decl: *Declaration) -> u32 {
    if !decl.expression return TOKEN_TYPE_VARIABLE;
    if decl.expression.kind == .PROCEDURE return TOKEN_TYPE_FUNCTION;
    if decl.expression.kind == .STRUCT   return TOKEN_TYPE_STRUCT;
    if decl.expression.kind == .UNION    return TOKEN_TYPE_STRUCT;
    if decl.expression.kind == .ENUM     return TOKEN_TYPE_ENUM;
    return TOKEN_TYPE_VARIABLE;
}

classify_declaration :: (node: *Node, parent: *Node) -> u32, u32, bool {
    decl := cast(*Declaration) node;
    mod: u32 = MODIFIER_DECLARATION;
    if decl.const { mod |= MODIFIER_READONLY; }

    tt := declaration_type(decl);

    // Contextual overrides: parameter in procedure, member in enum/struct/union
    if parent {
        if parent.kind == .PROCEDURE {
            proc := cast(*Procedure) parent;
            for arg: proc.arguments { if arg == node { tt = TOKEN_TYPE_PARAMETER; break; } }
            for ret: proc.returns { if ret.expression == node { tt = TOKEN_TYPE_PARAMETER; break; } }
        }
        if parent.kind == .ENUM { tt = TOKEN_TYPE_ENUM_MEMBER; }
        if parent.kind == .STRUCT || parent.kind == .UNION { tt = TOKEN_TYPE_PROPERTY; }
    }

    return tt, mod, true;
}

// ── Identifier classification ───────────────────────────────────────────
// Order: contextual checks (procedure call, type position) → declaration
// lookup (expression kind, parent enum) → fallback (variable).

classify_identifier :: (node: *Node, parent: *Node) -> u32, u32, bool {
    // Contextual: the position of the identifier determines its role
    if parent {
        if is_procedure_call_target(node, parent) return TOKEN_TYPE_FUNCTION, 0, true;
        if is_in_type_position(node, parent) return TOKEN_TYPE_TYPE, 0, true;
        if parent.kind == .FOR {
            f := cast(*For) parent;
            if node == f.value || node == f.index || node == f.iterator {
                return TOKEN_TYPE_VARIABLE, MODIFIER_DECLARATION, true;
            }
        }
        if parent.kind == .COMPOUND_DECLARATION_ITEM {
            item := cast(*Compound_Declaration_Item) parent;
            if item.item_kind == .DECLARATION {
                return TOKEN_TYPE_VARIABLE, MODIFIER_DECLARATION, true;
            }
        }
    }

    // Declaration lookup: what was this identifier bound to?
    ident := cast(*Identifier) node;
    decls := get_identifier_decls(ident);
    if decls.count > 0 {
        decl := decls[0];
        if decl.expression {
            if decl.expression.kind == .PROCEDURE return TOKEN_TYPE_FUNCTION, 0, true;
            if decl.expression.kind == .STRUCT || decl.expression.kind == .UNION return TOKEN_TYPE_TYPE, 0, true;
            if decl.expression.kind == .ENUM return TOKEN_TYPE_TYPE, 0, true;
        }
        if decl.parent && decl.parent.kind == .ENUM return TOKEN_TYPE_ENUM_MEMBER, 0, true;
    }

    // Heuristic: uppercase-first identifiers are likely types (Type.{}, Type.field, etc.)
    if ident.name.count > 0 {
        c := ident.name[0];
        if c >= #char "A" && c <= #char "Z" {
            return TOKEN_TYPE_TYPE, 0, true;
        }
    }

    return TOKEN_TYPE_VARIABLE, 0, true;
}

// ── Literal classification ──────────────────────────────────────────────

classify_literal :: (node: *Node) -> u32, u32, bool {
    lit := cast(*Literal) node;
    if lit.value_type == { case .STRING; return TOKEN_TYPE_STRING, 0, true; }
    if lit.value_type == { case .INT; #through; case .FLOAT; return TOKEN_TYPE_NUMBER, 0, true; }
    return 0, 0, false;
}

// ── Context helpers ──────────────────────────────────────────────────────

is_procedure_call_target :: (node: *Node, parent: *Node) -> bool {
    if parent.kind != .PROCEDURE_CALL return false;
    pc := cast(*Procedure_Call) parent;
    return pc.procedure == node;
}

is_in_type_position :: (node: *Node, parent: *Node) -> bool {
    if !parent return false;
    if parent.kind == .TYPE_INSTANTIATION return true;
    if parent.kind == .DECLARATION && cast(*Declaration, parent).type_inst == node return true;
    if parent.kind == .RETURN_VALUE && cast(*Return_Value, parent).expression == node return true;
    if parent.kind == .CAST && cast(*Cast, parent).cast_expression == node return true;
    if parent.kind == .ARRAY_TYPE {
        at := cast(*Array_Type) parent;
        if at.element_type == node || at.dimension == node return true;
    }
    // Struct literal prefix: Type.{} — left of dot is type, right is struct literal.
    // NOT chain access: a.b.c — right side is another DOT (BINARY_OPERATION).
    if parent.kind == .BINARY_OPERATION {
        bin := cast(*Binary_Operation) parent;
        if bin.operation == .DOT && bin.left == node && bin.right &&
           bin.right.kind != .IDENTIFIER && bin.right.kind != .BINARY_OPERATION {
            return true;
        }
    }
    if parent.kind == .UNARY_OPERATION {
        u := cast(*Unary_Operation) parent;
        if u.expression == node {
            gp := u.parent;
            if !gp return false;
            if gp.kind == .CAST return true;
            if gp.kind == .DECLARATION && cast(*Declaration, gp).type_inst == parent return true;
            if gp.kind == .RETURN_VALUE && cast(*Return_Value, gp).expression == parent return true;
            if gp.kind == .ARRAY_TYPE return true;
        }
    }
    return false;
}

// ── Sorting ─────────────────────────────────────────────────────────────
// Quicksort with median-of-three pivot selection. O(n log n).

sort_token_entries :: (entries: []Token_Entry) {
    if entries.count <= 1 return;
    quicksort_token_entries(entries, 0, entries.count - 1);
}

quicksort_token_entries :: (entries: []Token_Entry, low: int, high: int) {
    if low >= high return;

    // Median-of-three pivot
    mid := (low + high) / 2;
    if entries[low].line > entries[mid].line || (entries[low].line == entries[mid].line && entries[low].character > entries[mid].character) {
        swap_entries(*entries[low], *entries[mid]);
    }
    if entries[low].line > entries[high].line || (entries[low].line == entries[high].line && entries[low].character > entries[high].character) {
        swap_entries(*entries[low], *entries[high]);
    }
    if entries[mid].line > entries[high].line || (entries[mid].line == entries[high].line && entries[mid].character > entries[high].character) {
        swap_entries(*entries[mid], *entries[high]);
    }

    pivot := entries[mid];
    swap_entries(*entries[mid], *entries[high]);

    // Partition: < pivot → left, >= pivot → right
    store := low;
    for i: low .. high - 1 {
        if entries[i].line < pivot.line || (entries[i].line == pivot.line && entries[i].character < pivot.character) {
            swap_entries(*entries[i], *entries[store]);
            store += 1;
        }
    }

    swap_entries(*entries[store], *entries[high]);

    quicksort_token_entries(entries, low, store - 1);
    quicksort_token_entries(entries, store + 1, high);
}

swap_entries :: (a: *Token_Entry, b: *Token_Entry) {
    tmp := (.*)a;
    (.*)a = (.*)b;
    (.*)b = tmp;
}

// ── Dedup ───────────────────────────────────────────────────────────────
// Collapses adjacent duplicate (line, character) pairs.
// Expects entries to be sorted first.

dedup_token_entries :: (ea: *[..]Token_Entry) {
    count := ea.count;
    if count <= 1 return;
    data := ea.data;
    write: int = 1;
    for read: 1 .. count - 1 {
        prev := data[write - 1];
        cur := data[read];
        if cur.line != prev.line || cur.character != prev.character {
            data[write] = cur;
            write += 1;
        }
    }
    ea.count = write;
}

// ── Range clip ──────────────────────────────────────────────────────────
// Filters entries to [range_start, range_end) and re-assigns to output slice.
// Only called for range requests — sorts/collection already bounded by line.

clip_range :: (src: []Token_Entry, dst: *[..]Token_Entry, range_start: Node.Location, range_end: Node.Location) {
    start_line := xx range_start.l0;
    start_char := xx range_start.c0;
    end_line := xx range_end.l0;
    end_char := xx range_end.c0;
    dst.count = 0;
    for entry: src {
        if entry.line < start_line continue;
        if entry.line == start_line && entry.character < start_char continue;
        if entry.line > end_line break;
        if entry.line == end_line && entry.character >= end_char break;
        array_add(dst, entry);
    }
}

// ── Delta encoding ──────────────────────────────────────────────────────
// LSP delta encoding: first entry is absolute, subsequent are relative
// to previous entry. Used for both full and range responses.

delta_encode_and_respond :: (entries: []Token_Entry, id: JSON_Value) {
    encoded: [..]int;
    prev_line: int = 0;
    prev_char: int = 0;

    for entry: entries {
        delta_line := xx entry.line - prev_line;
        if delta_line == 0 {
            delta_char := xx entry.character - prev_char;
            array_add(*encoded, 0);
            array_add(*encoded, delta_char);
        } else {
            array_add(*encoded, delta_line);
            array_add(*encoded, xx entry.character);
        }

        array_add(*encoded, xx entry.length);
        array_add(*encoded, xx entry.token_type);
        array_add(*encoded, xx entry.token_modifiers);

        prev_line = xx entry.line;
        prev_char = xx entry.character;
    }

    result: LSP_SemanticTokens;
    result.data = encoded;
    lsp_respond(id, result);
}
