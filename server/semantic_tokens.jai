// Semantic Tokens — LSP semantic highlighting from AST + comments
//
// Iterates file.nodes (flat list of ALL AST nodes in parse order) and
// file.comments (lexer comment buffer). Each node maps to an LSP token
// type + modifiers. No recursion needed — file.nodes already contains
// every node from the parse tree.
//
// Token type indices correspond to SEMANTIC_TOKEN_TYPES in lsp_interface.jai

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

// Modifier bitmasks — indices into SEMANTIC_TOKEN_MODIFIERS
MODIFIER_DECLARATION     :: 1 << 0;
MODIFIER_DEFINITION      :: 1 << 1;
MODIFIER_READONLY        :: 1 << 2;
MODIFIER_STATIC          :: 1 << 3;
MODIFIER_DEPRECATED      :: 1 << 4;
MODIFIER_ABSTRACT        :: 1 << 5;
MODIFIER_DEFAULT_LIBRARY :: 1 << 9;

Token_Entry :: struct {
    line: u32;
    character: u32;
    length: u32;
    token_type: u32;
    token_modifiers: u32;
}

// ── Handlers ──────────────────────────────────────────────────────────────

handle_semantic_tokens_full :: (request: LSP_Request_Message_SemanticTokens) {
    push_allocator(temp);

    uri := request.params.textDocument.uri;
    file_path := normalize_path(uri);

    file := get_file(file_path);
    if !file {
        log_error("SemanticTokens: file not parsed yet: %", file_path);
        lsp_respond(request.id, null);
        return;
    }

    entries: [..]Token_Entry;
    collect_all_tokens(file, *entries);
    sort_token_entries(entries);

    // Dedup
    if entries.count > 1 {
        write: int = 1;
        for read: 1 .. entries.count - 1 {
            if entries[read].line != entries[write - 1].line || entries[read].character != entries[write - 1].character {
                entries[write] = entries[read];
                write += 1;
            }
        }
        entries.count = write;
    }

    delta_encode_and_respond(entries, request.id);
}

handle_semantic_tokens_range :: (request: LSP_Request_Message_SemanticTokens_Range) {
    push_allocator(temp);

    uri := request.params.textDocument.uri;
    file_path := normalize_path(uri);

    file := get_file(file_path);
    if !file {
        log_error("SemanticTokens range: file not parsed yet: %", file_path);
        lsp_respond(request.id, null);
        return;
    }

    range := request.params.range;

    entries: [..]Token_Entry;
    collect_all_tokens(file, *entries);
    sort_token_entries(entries);

    // Filter by range
    filtered: [..]Token_Entry;
    for entry: entries {
        if entry.line < range.start.line continue;
        if entry.line == range.start.line && entry.character < range.start.character continue;
        if entry.line > range.end.line break;
        if entry.line == range.end.line && entry.character >= range.end.character break;
        array_add(*filtered, entry);
    }

    delta_encode_and_respond(filtered, request.id);
}

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

// ── Token collection ─────────────────────────────────────────────────────

collect_all_tokens :: (file: *Program_File, entries: *[..]Token_Entry) {
    for node: file.nodes {
        emit_node_token(node, entries);
    }
    for comment: file.comments {
        if comment.l0 == comment.l1 { // skip multi-line
            entry: Token_Entry;
            entry.line = xx comment.l0;
            entry.character = xx comment.c0;
            entry.length = xx (comment.c1 - comment.c0);
            entry.token_type = TOKEN_TYPE_COMMENT;
            entry.token_modifiers = 0;
            array_add(entries, entry);
        }
    }
}

emit_node_token :: (node: *Node, entries: *[..]Token_Entry) {
    if !node return;

    token_type, modifiers, got := classify_node(node);
    if got {
        span := token_span(node, token_type);
        if span.length > 0 {
            entry: Token_Entry;
            entry.line = xx span.line;
            entry.character = xx span.col;
            entry.length = xx span.length;
            entry.token_type = token_type;
            entry.token_modifiers = modifiers;
            array_add(entries, entry);
        }
    }

    // Side-tokens: declaration operators, directive strings
    emit_declaration_operator(node, entries);
    emit_directive_string(node, entries);
}

Token_Span :: struct { line: int; col: int; length: int; }

token_span :: (node: *Node, token_type: u32) -> Token_Span {
    loc := node.location;
    col := loc.c0;
    len := loc.c1 - loc.c0;

    if node.kind == .DECLARATION {
        decl := cast(*Declaration) node;
        len = decl.name.count;
    } else if token_type == TOKEN_TYPE_KEYWORD {
        len = keyword_length(node);
    } else if token_type == TOKEN_TYPE_OPERATOR && node.kind == .BINARY_OPERATION {
        bin := cast(*Binary_Operation) node;
        if bin.left && bin.right && bin.left.location.c1 > 0 && bin.right.location.c0 > bin.left.location.c1 {
            col = bin.left.location.c1;
            len = bin.right.location.c0 - bin.left.location.c1;
        } else { len = 0; }
    } else if token_type == TOKEN_TYPE_OPERATOR && node.kind == .UNARY_OPERATION {
        u := cast(*Unary_Operation) node;
        if u.expression && u.expression.location.c0 > col {
            len = u.expression.location.c0 - col;
        }
    }

    // Skip multi-line tokens except declarations and keywords
    if loc.l0 != loc.l1 && node.kind != .DECLARATION && token_type != TOKEN_TYPE_KEYWORD && token_type != TOKEN_TYPE_MACRO {
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

// ── Side tokens ───────────────────────────────────────────────────────────

emit_declaration_operator :: (node: *Node, entries: *[..]Token_Entry) {
    if node.kind == .DECLARATION {
        decl := cast(*Declaration) node;
        op_col := decl.location.c0 + decl.name.count;
        op_len := 2;
        if !decl.const && decl.type_inst && !decl.expression { op_len = 1; op_col = decl.location.c0 + decl.name.count; }
        else { op_col += 1; }
        add_token_entry(xx decl.location.l0, xx op_col, xx op_len, TOKEN_TYPE_OPERATOR, 0, entries);
    }
    if node.kind == .COMPOUND_DECLARATION {
        cd := cast(*Compound_Declaration) node;
        if cd.members.count == 0 return;
        last := cd.members[cd.members.count - 1];
        op_col := last.location.c0 + (last.location.c1 - last.location.c0);
        op_len := 2;
        if !cd.const && cd.type_inst && cd.type_inst.name.count > 0 { op_len = 1; }
        else { op_col += 1; }
        add_token_entry(xx last.location.l0, xx op_col, xx op_len, TOKEN_TYPE_OPERATOR, 0, entries);
    }
}

emit_directive_string :: (node: *Node, entries: *[..]Token_Entry) {
    if node.kind == .DIRECTIVE_IMPORT {
        di := cast(*Directive_Import) node;
        if di.module.count > 0 {
            start := node.location.c1 - di.module.count - 2; // quotes
            add_token_entry(xx node.location.l0, xx start, xx (di.module.count + 2), TOKEN_TYPE_STRING, 0, entries);
        }
    }
    if node.kind == .DIRECTIVE_LOAD {
        dl := cast(*Directive_Load) node;
        if dl.file.count > 0 {
            start := node.location.c1 - dl.file.count - 2;
            add_token_entry(xx node.location.l0, xx start, xx (dl.file.count + 2), TOKEN_TYPE_STRING, 0, entries);
        }
    }
}

add_token_entry :: (line: int, col: int, len: int, tt: u32, mod: u32, entries: *[..]Token_Entry) {
    if len <= 0 return;
    entry: Token_Entry;
    entry.line = xx line;
    entry.character = xx col;
    entry.length = xx len;
    entry.token_type = tt;
    entry.token_modifiers = mod;
    array_add(entries, entry);
}

// ── Declaration helpers ────────────────────────────────────────────────────

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

// ── Identifier helpers ─────────────────────────────────────────────────────

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
    // Struct literal prefix: Type.{} — left of dot is type, right is struct literal
    if parent.kind == .BINARY_OPERATION {
        bin := cast(*Binary_Operation) parent;
        if bin.operation == .DOT && bin.left == node && bin.right && bin.right.kind != .IDENTIFIER {
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

classify_identifier :: (node: *Node, parent: *Node) -> u32, u32, bool {
    mod: u32 = 0;
    if parent {
        if is_procedure_call_target(node, parent) return TOKEN_TYPE_FUNCTION, 0, true;
        if is_in_type_position(node, parent) return TOKEN_TYPE_TYPE, 0, true;
        if parent.kind == .FOR {
            f := cast(*For) parent;
            if node == f.value || node == f.index || node == f.iterator { mod = MODIFIER_DECLARATION; }
        }
    }
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
    return TOKEN_TYPE_VARIABLE, mod, true;
}

// ── Node classification ───────────────────────────────────────────────────

classify_node :: (node: *Node) -> u32, u32, bool {
    parent := node.parent;

    if node.kind == {
        case .DECLARATION;
            {
                decl := cast(*Declaration) node;
                mod: u32 = MODIFIER_DECLARATION;
                if decl.const { mod |= MODIFIER_READONLY; }
                tt := declaration_type(decl);
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

        case .IDENTIFIER;
            {
                mod: u32 = 0;
                if parent {
                    if is_procedure_call_target(node, parent) return TOKEN_TYPE_FUNCTION, 0, true;
                    if is_in_type_position(node, parent) return TOKEN_TYPE_TYPE, 0, true;
                    if parent.kind == .FOR {
                        f := cast(*For) parent;
                        if node == f.value || node == f.index || node == f.iterator { mod = MODIFIER_DECLARATION; }
                    }
                }
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
    {
        ident := cast(*Identifier) node;
        if ident.name.count > 0 {
            c := ident.name[0];
            if c >= #char "A" && c <= #char "Z" {
                return TOKEN_TYPE_TYPE, 0, true;
            }
        }
    }

    return TOKEN_TYPE_VARIABLE, mod, true;
            }

        case .LITERAL;
            lit := cast(*Literal) node;
            if lit.value_type == { case .STRING; return TOKEN_TYPE_STRING, 0, true; }
            if lit.value_type == { case .INT; #through; case .FLOAT; return TOKEN_TYPE_NUMBER, 0, true; }
            return 0, 0, false;

        case .COMMENT;    return TOKEN_TYPE_COMMENT,   0, true;
        case .NOTE;       return TOKEN_TYPE_DECORATOR, 0, true;

        // Directives → macro
        case .DIRECTIVE_IMPORT; #through; case .DIRECTIVE_LOAD; #through; case .DIRECTIVE_RUN; #through;
        case .DIRECTIVE_AS; #through; case .DIRECTIVE_PLACE; #through; case .DIRECTIVE_OVERLAY; #through;
        case .DIRECTIVE_TYPE; #through; case .DIRECTIVE_CODE; #through; case .DIRECTIVE_ADD_CONTEXT; #through;
        case .DIRECTIVE_ASSERT; #through; case .DIRECTIVE_BYTES; #through; case .DIRECTIVE_LIBRARY; #through;
        case .DIRECTIVE_NO_RESET; #through; case .DIRECTIVE_INSERT; #through; case .DIRECTIVE_LOCATION; #through;
        case .DIRECTIVE_MODULE_PARAMETERS; #through; case .DIRECTIVE_PLACEHOLDER; #through;
        case .DIRECTIVE_PROCEDURE_OF_CALL; #through; case .DIRECTIVE_PROCEDURE_NAME; #through;
        case .DIRECTIVE_PROGRAM_EXPORT; #through; case .DIRECTIVE_THIS; #through; case .DIRECTIVE_POKE_NAME; #through;
        case .DIRECTIVE_BAKE_ARGUMENTS; #through; case .DIRECTIVE_BAKE_CONSTANTS; #through;
        case .DIRECTIVE_DYNAMIC_SPECIALIZE; #through; case .DIRECTIVE_CALLER_CODE; #through;
        case .DIRECTIVE_CALLER_LOCATION; #through; case .DIRECTIVE_FILE; #through; case .DIRECTIVE_FILEPATH; #through;
        case .DIRECTIVE_LINE; #through; case .DIRECTIVE_THROUGH; #through; case .DIRECTIVE_SCOPE; #through;
        case .DIRECTIVE_CHAR; #through; case .DIRECTIVE_COMPILE_TIME; #through; case .DIRECTIVE_DISCARD; #through;
        case .DIRECTIVE_EXISTS; #through; case .DIRECTIVE_CONTEXT; #through; case .DIRECTIVE_STRING;
            return TOKEN_TYPE_MACRO, 0, true;

        // Keywords
        case .RETURN; #through; case .FOR; #through; case .WHILE; #through; case .IF; #through;
        case .BREAK; #through; case .CONTINUE; #through; case .DEFER; #through; case .REMOVE; #through;
        case .CAST; #through; case .CASE; #through; case .USING; #through; case .STRUCT; #through;
        case .ENUM; #through; case .UNION; #through; case .OPERATOR_OVERLOAD; #through; case .INLINE_ASSEMBLY;
            return TOKEN_TYPE_KEYWORD, 0, true;

        // Operators
        case .BINARY_OPERATION; #through; case .UNARY_OPERATION;
            return TOKEN_TYPE_OPERATOR, 0, true;

        case .QUICK_LAMBDA;
            return TOKEN_TYPE_OPERATOR, 0, true;
    }

    return 0, 0, false;
}

// ── Sorting ───────────────────────────────────────────────────────────────

sort_token_entries :: (entries: []Token_Entry) {
    for i: 1 .. entries.count - 1 {
        key := entries[i];
        j := i - 1;
        while j >= 0 && (entries[j].line > key.line || (entries[j].line == key.line && entries[j].character > key.character)) {
            entries[j + 1] = entries[j];
            j -= 1;
        }
        entries[j + 1] = key;
    }
}
