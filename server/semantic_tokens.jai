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

    // Deduplicate consecutive entries at same (line, character)
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

    encoded: [..]int;
    delta_encode_tokens(entries, *encoded);

    result: LSP_SemanticTokens;
    result.data = encoded;

    lsp_respond(request.id, result);
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

    // Deduplicate
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

    // Filter by range
    filtered: [..]Token_Entry;
    for entry: entries {
        if entry.line < range.start.line continue;
        if entry.line == range.start.line && entry.character < range.start.character continue;
        if entry.line > range.end.line break;
        if entry.line == range.end.line && entry.character >= range.end.character break;
        array_add(*filtered, entry);
    }

    encoded: [..]int;
    delta_encode_tokens(filtered, *encoded);

    result: LSP_SemanticTokens;
    result.data = encoded;

    lsp_respond(request.id, result);
}

// ── Token collection (flat iteration) ─────────────────────────────────────

// Iterate ALL AST nodes (flat) + ALL comment tokens.
// No recursion — file.nodes contains every parse tree node in source order.
collect_all_tokens :: (file: *Program_File, entries: *[..]Token_Entry) {
    for node: file.nodes {
        emit_token_for_node(node, entries);
    }
    for comment: file.comments {
        emit_comment_token(comment, entries);
    }
}

emit_token_for_node :: (node: *Node, entries: *[..]Token_Entry) {
    if !node return;

    token_type, modifiers, got := classify_node(node);
    if !got return;

    loc := node.location;
    length := compute_token_length(node, token_type);

    // Skip truly multi-line tokens (not declarations/keywords which we cap)
    if loc.l0 != loc.l1 && node.kind != .DECLARATION && token_type != TOKEN_TYPE_KEYWORD && token_type != TOKEN_TYPE_MACRO return;

    if length <= 0 return;

    entry: Token_Entry;
    entry.line = xx loc.l0;
    entry.character = xx loc.c0;
    entry.length = xx length;
    entry.token_type = token_type;
    entry.token_modifiers = modifiers;
    array_add(entries, entry);
}

emit_comment_token :: (comment: Comment_Token, entries: *[..]Token_Entry) {
    if comment.l0 != comment.l1 return; // Skip multi-line

    entry: Token_Entry;
    entry.line = xx comment.l0;
    entry.character = xx comment.c0;
    entry.length = xx (comment.c1 - comment.c0);
    entry.token_type = TOKEN_TYPE_COMMENT;
    entry.token_modifiers = 0;
    array_add(entries, entry);
}

// ── Node classification ───────────────────────────────────────────────────

// Map any AST node to (token_type, modifier_bits, should_emit).
// Uses parent chain for context (parameter detection, etc.)
classify_node :: (node: *Node) -> u32, u32, bool {
    parent := node.parent;

    if node.kind == {
        // ── Declarations: function / struct / enum / variable ──────
        case .DECLARATION;
            decl := cast(*Declaration) node;
            modifiers: u32 = MODIFIER_DECLARATION;
            if decl.const { modifiers |= MODIFIER_READONLY; }

            token_type: u32;
            if decl.expression {
                if decl.expression.kind == .PROCEDURE {
                    token_type = TOKEN_TYPE_FUNCTION;
                } else if decl.expression.kind == .STRUCT {
                    token_type = TOKEN_TYPE_STRUCT;
                } else if decl.expression.kind == .UNION {
                    token_type = TOKEN_TYPE_STRUCT;
                } else if decl.expression.kind == .ENUM {
                    token_type = TOKEN_TYPE_ENUM;
                } else {
                    token_type = TOKEN_TYPE_VARIABLE;
                }
            } else {
                token_type = TOKEN_TYPE_VARIABLE;
            }

            // Override: procedure arguments → parameter
            if parent && parent.kind == .PROCEDURE {
                proc := cast(*Procedure) parent;
                for arg: proc.arguments {
                    if arg == node { token_type = TOKEN_TYPE_PARAMETER; break; }
                }
                for ret: proc.returns {
                    if ret.expression == node { token_type = TOKEN_TYPE_PARAMETER; break; }
                }
            }

            // Override: enum members → enumMember
            if parent && parent.kind == .ENUM {
                token_type = TOKEN_TYPE_ENUM_MEMBER;
            }

            // Override: struct/union members → property
            if parent && (parent.kind == .STRUCT || parent.kind == .UNION) {
                token_type = TOKEN_TYPE_PROPERTY;
            }

            return token_type, modifiers, true;

        // ── Identifiers (context-sensitive) ───────────────────────
        case .IDENTIFIER;
            modifiers: u32 = 0;

            if parent {
                // Procedure call target → function
                if parent.kind == .PROCEDURE_CALL {
                    pc := cast(*Procedure_Call) parent;
                    if pc.procedure == node {
                        return TOKEN_TYPE_FUNCTION, 0, true;
                    }
                }

                // Type reference (inside type annotation, cast, etc.)
                if parent.kind == .TYPE_INSTANTIATION {
                    return TOKEN_TYPE_TYPE, 0, true;
                }

                // For-loop iteration variables
                if parent.kind == .FOR {
                    f := cast(*For) parent;
                    if node == f.value || node == f.index || node == f.iterator {
                        modifiers = MODIFIER_DECLARATION;
                    }
                }
            }

            // Fallback: resolve what this identifier refers to via declaration lookup
            {
                ident := cast(*Identifier) node;
                decls := get_identifier_decls(ident);
                if decls.count > 0 {
                    decl := decls[0];
                    if decl.expression {
                        if decl.expression.kind == .PROCEDURE {
                            return TOKEN_TYPE_FUNCTION, 0, true;
                        }
                        if decl.expression.kind == .STRUCT || decl.expression.kind == .UNION {
                            return TOKEN_TYPE_TYPE, 0, true;
                        }
                        if decl.expression.kind == .ENUM {
                            return TOKEN_TYPE_TYPE, 0, true;
                        }
                    }
                    // Enum member reference
                    if decl.parent && decl.parent.kind == .ENUM {
                        return TOKEN_TYPE_ENUM_MEMBER, 0, true;
                    }
                }
            }

            return TOKEN_TYPE_VARIABLE, modifiers, true;

        // ── Literals: string / number / bool ───────────────────────
        case .LITERAL;
            lit := cast(*Literal) node;
            if lit.value_type == {
                case .STRING;
                    return TOKEN_TYPE_STRING, 0, true;
                case .INT; #through;
                case .FLOAT;
                    return TOKEN_TYPE_NUMBER, 0, true;
            }
            return 0, 0, false; // bool, array, struct literals → skip

        // ── Comments (AST comment nodes, not lexer comments) ───────
        case .COMMENT;
            return TOKEN_TYPE_COMMENT, 0, true;

        // ── Notes (@deprecated, etc.) ──────────────────────────────
        case .NOTE;
            return TOKEN_TYPE_DECORATOR, 0, true;

        // ── Directives → macro ─────────────────────────────────────
        case .DIRECTIVE_IMPORT; #through;
        case .DIRECTIVE_LOAD; #through;
        case .DIRECTIVE_RUN; #through;
        case .DIRECTIVE_AS; #through;
        case .DIRECTIVE_PLACE; #through;
        case .DIRECTIVE_OVERLAY; #through;
        case .DIRECTIVE_TYPE; #through;
        case .DIRECTIVE_CODE; #through;
        case .DIRECTIVE_ADD_CONTEXT; #through;
        case .DIRECTIVE_ASSERT; #through;
        case .DIRECTIVE_BYTES; #through;
        case .DIRECTIVE_LIBRARY; #through;
        case .DIRECTIVE_NO_RESET; #through;
        case .DIRECTIVE_INSERT; #through;
        case .DIRECTIVE_LOCATION; #through;
        case .DIRECTIVE_MODULE_PARAMETERS; #through;
        case .DIRECTIVE_PLACEHOLDER; #through;
        case .DIRECTIVE_PROCEDURE_OF_CALL; #through;
        case .DIRECTIVE_PROCEDURE_NAME; #through;
        case .DIRECTIVE_PROGRAM_EXPORT; #through;
        case .DIRECTIVE_THIS; #through;
        case .DIRECTIVE_POKE_NAME; #through;
        case .DIRECTIVE_BAKE_ARGUMENTS; #through;
        case .DIRECTIVE_BAKE_CONSTANTS; #through;
        case .DIRECTIVE_DYNAMIC_SPECIALIZE; #through;
        case .DIRECTIVE_CALLER_CODE; #through;
        case .DIRECTIVE_CALLER_LOCATION; #through;
        case .DIRECTIVE_FILE; #through;
        case .DIRECTIVE_FILEPATH; #through;
        case .DIRECTIVE_LINE; #through;
        case .DIRECTIVE_THROUGH; #through;
        case .DIRECTIVE_SCOPE; #through;
        case .DIRECTIVE_CHAR; #through;
        case .DIRECTIVE_COMPILE_TIME; #through;
        case .DIRECTIVE_DISCARD; #through;
        case .DIRECTIVE_EXISTS; #through;
        case .DIRECTIVE_CONTEXT; #through;
        case .DIRECTIVE_STRING;
            return TOKEN_TYPE_MACRO, 0, true;

        // ── Keywords ───────────────────────────────────────────────
        case .RETURN; #through;
        case .FOR; #through;
        case .WHILE; #through;
        case .IF; #through;
        case .BREAK; #through;
        case .CONTINUE; #through;
        case .DEFER; #through;
        case .REMOVE; #through;
        case .CAST; #through;
        case .CASE; #through;
        case .USING; #through;
        case .STRUCT; #through;
        case .ENUM; #through;
        case .UNION;
            return TOKEN_TYPE_KEYWORD, 0, true;

        // ── Operators ──────────────────────────────────────────────
        case .BINARY_OPERATION; #through;
        case .UNARY_OPERATION;
            return TOKEN_TYPE_OPERATOR, 0, true;

        // ── Operator overload (keyword 'operator') ─────────────────
        case .OPERATOR_OVERLOAD;
            return TOKEN_TYPE_KEYWORD, 0, true;

        // ── Inline assembly ────────────────────────────────────────
        case .INLINE_ASSEMBLY;
            return TOKEN_TYPE_KEYWORD, 0, true;

        // ── Quick lambda '->' ──────────────────────────────────────
        case .QUICK_LAMBDA;
            return TOKEN_TYPE_OPERATOR, 0, true;
    }

    return 0, 0, false;
}

// ── Helpers ────────────────────────────────────────────────────────────────

compute_token_length :: (node: *Node, token_type: u32) -> int {
    if node.kind == .DECLARATION {
        decl := cast(*Declaration) node;
        return decl.name.count;
    }
    if token_type == TOKEN_TYPE_KEYWORD {
        return keyword_length_for_node(node);
    }
    if token_type == TOKEN_TYPE_MACRO {
        return macro_length_for_node(node);
    }
    if token_type == TOKEN_TYPE_OPERATOR {
        loc := node.location;
        return loc.c1 - loc.c0; // operators are single-line and well-sized
    }
    loc := node.location;
    return loc.c1 - loc.c0;
}

keyword_length_for_node :: (node: *Node) -> int {
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
    loc := node.location;
    return loc.c1 - loc.c0;
}

macro_length_for_node :: (node: *Node) -> int {
    loc := node.location;
    return loc.c1 - loc.c0;
}

// ── Sorting & dedup ────────────────────────────────────────────────────────

sort_token_entries :: (entries: []Token_Entry) {
    for i: 1 .. entries.count - 1 {
        key := entries[i];
        j := i - 1;
        while j >= 0 && token_entry_less(key, entries[j]) {
            entries[j + 1] = entries[j];
            j -= 1;
        }
        entries[j + 1] = key;
    }
}

token_entry_less :: (a: Token_Entry, b: Token_Entry) -> bool {
    if a.line < b.line return true;
    if a.line > b.line return false;
    return a.character < b.character;
}

// ── Delta encoding ─────────────────────────────────────────────────────────

delta_encode_tokens :: (entries: []Token_Entry, out: *[..]int) {
    prev_line: int = 0;
    prev_char: int = 0;

    for entry: entries {
        delta_line := xx entry.line - prev_line;
        if delta_line == 0 {
            delta_char := xx entry.character - prev_char;
            array_add(out, 0);
            array_add(out, delta_char);
        } else {
            array_add(out, delta_line);
            array_add(out, xx entry.character);
        }

        array_add(out, xx entry.length);
        array_add(out, xx entry.token_type);
        array_add(out, xx entry.token_modifiers);

        prev_line = xx entry.line;
        prev_char = xx entry.character;
    }
}
