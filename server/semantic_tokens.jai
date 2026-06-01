// Semantic Tokens — LSP semantic highlighting from AST + comments
//
// Walks the AST top-down from global_block.members and comments (file.comments),
// maps each node/comment to an LSP semantic token type + modifiers,
// sorts by source position, delta-encodes, and responds.
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
    collect_node_tokens(file, *entries);
    collect_comment_tokens(file, *entries);

    // AST nodes are in source order; comments are in lexer order.
    // Both are roughly sorted already. Run insertion sort to guarantee order.
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
    collect_node_tokens(file, *entries);
    collect_comment_tokens(file, *entries);
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

    encoded: [..]int;
    delta_encode_tokens(filtered, *encoded);

    result: LSP_SemanticTokens;
    result.data = encoded;

    lsp_respond(request.id, result);
}

// Walk the AST top-down from global block members and emit token entries.
// Uses recursion, NOT the flat file.nodes list (which would double-process).
collect_node_tokens :: (file: *Program_File, entries: *[..]Token_Entry) {
    for node: file.global_block.members {
        process_node(node, entries, false);
    }
}

process_node :: (node: *Node, entries: *[..]Token_Entry, inside_struct: bool) {
    if !node return;

    token_type, modifiers, got := node_to_token_type_and_modifiers(node, inside_struct);
    if got {
        loc := node.location;
        length := loc.c1 - loc.c0;

        // For declarations, use actual name length (location spans full declaration)
        if node.kind == .DECLARATION {
            decl := cast(*Declaration) node;
            length = decl.name.count;
        }

        // For keywords, use keyword text length (location spans keyword + expression)
        if token_type == TOKEN_TYPE_KEYWORD {
            length = keyword_length_for_node(node);
        }

        // Skip multi-line tokens — only highlight single-line names
        if loc.l0 != loc.l1 && node.kind != .DECLARATION {
            length = 0;
        }

        if length > 0 {
            entry: Token_Entry;
            entry.line = xx loc.l0;
            entry.character = xx loc.c0;
            entry.length = xx length;
            entry.token_type = token_type;
            entry.token_modifiers = modifiers;
            array_add(entries, entry);
        }
    }

    // Recurse into children that may contain semantic tokens.
    if node.kind == {
        case .DECLARATION;
            decl := cast(*Declaration) node;
            if decl.expression {
                process_node(decl.expression, entries, inside_struct);
            }

        case .BLOCK;
            block := cast(*Block) node;
            for member: block.members {
                process_node(member, entries, inside_struct);
            }

        case .STRUCT;
            s := cast(*Struct) node;
            if s.block {
                for member: s.block.members {
                    process_node(member, entries, true);
                }
            }
            for param: s.polymorphic_arguments {
                add_simple_entry(param, entries, TOKEN_TYPE_TYPE_PARAM, 0);
            }

        case .UNION;
            u := cast(*Union) node;
            if u.block {
                for member: u.block.members {
                    process_node(member, entries, true);
                }
            }
            for param: u.polymorphic_arguments {
                add_simple_entry(param, entries, TOKEN_TYPE_TYPE_PARAM, 0);
            }

        case .ENUM;
            _enum := cast(*Enum) node;
            if _enum.block {
                for member: _enum.block.members {
                    process_node(member, entries, true);
                }
            }

        case .PROCEDURE;
            proc := cast(*Procedure) node;
            // Procedure arguments → parameter
            for arg: proc.arguments {
                add_simple_entry(arg, entries, TOKEN_TYPE_PARAMETER, 0);
            }
            // Returns
            for ret: proc.returns {
                if ret.expression {
                    add_simple_entry(ret.expression, entries, TOKEN_TYPE_PARAMETER, 0);
                }
            }
            // Recurse into body
            if proc.body {
                for member: proc.body.members {
                    process_node(member, entries, inside_struct);
                }
            }

        case .FOR;
            f := cast(*For) node;
            for field: *Node.[f.value, f.index, f.iterator] {
                if field {
                    add_simple_entry(field, entries, TOKEN_TYPE_VARIABLE, MODIFIER_DECLARATION);
                }
            }
            if f.body && f.body.kind == .BLOCK {
                for member: cast(*Block, f.body).members {
                    process_node(member, entries, inside_struct);
                }
            }

        case .WHILE;
            w := cast(*While) node;
            if w.body && w.body.kind == .BLOCK {
                for member: cast(*Block, w.body).members {
                    process_node(member, entries, inside_struct);
                }
            }

        case .IF;
            iff := cast(*If) node;
            for branch: *Node.[iff._then, iff._else] {
                if !branch continue;
                block := ifx branch.kind == .BLOCK then cast(*Block) branch else null;
                if !block continue;
                for member: block.members {
                    process_node(member, entries, inside_struct);
                }
            }

        case .USING;
            u := cast(*Using) node;
            if u.expression {
                process_node(u.expression, entries, inside_struct);
            }
    }
}

// Collect comment tokens from the lexer's comment buffer.
collect_comment_tokens :: (file: *Program_File, entries: *[..]Token_Entry) {
    for comment: file.comments {
        // Token fields are accessible directly via #as using
        if comment.l0 != comment.l1 continue; // Skip multi-line comments

        entry: Token_Entry;
        entry.line = xx comment.l0;
        entry.character = xx comment.c0;
        entry.length = xx (comment.c1 - comment.c0);
        entry.token_type = TOKEN_TYPE_COMMENT;
        entry.token_modifiers = 0;
        array_add(entries, entry);
    }
}

// Map a single AST node to its semantic token type and modifier bits.
// Returns (token_type, modifiers, should_emit).
node_to_token_type_and_modifiers :: (node: *Node, inside_struct: bool) -> u32, u32, bool {
    if node.kind == {
        case .DECLARATION;
            decl := cast(*Declaration) node;
            modifiers: u32 = MODIFIER_DECLARATION;
            if decl.const {
                modifiers |= MODIFIER_READONLY;
            }
            if decl.notes {
                for note: decl.notes {
                    if contains(note.value, "deprecated") {
                        modifiers |= MODIFIER_DEPRECATED;
                        break;
                    }
                }
            }

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
                } else if inside_struct {
                    token_type = TOKEN_TYPE_PROPERTY;
                } else {
                    token_type = TOKEN_TYPE_VARIABLE;
                }
            } else if inside_struct {
                token_type = TOKEN_TYPE_PROPERTY;
            } else {
                token_type = TOKEN_TYPE_VARIABLE;
            }

            return token_type, modifiers, true;

        case .IDENTIFIER;
            ident := cast(*Identifier) node;
            // Skip identifiers that are part of larger expressions (handled by parent)
            return TOKEN_TYPE_VARIABLE, 0, true;

        case .NOTE;
            return TOKEN_TYPE_DECORATOR, 0, true;

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
        case .DIRECTIVE_SCOPE;
            return TOKEN_TYPE_MACRO, 0, true;

        case .RETURN; #through;
        case .FOR; #through;
        case .WHILE; #through;
        case .IF; #through;
        case .BREAK; #through;
        case .CONTINUE; #through;
        case .DEFER; #through;
        case .REMOVE; #through;
        case .CAST;
            return TOKEN_TYPE_KEYWORD, 0, true;

        case .USING;
            return TOKEN_TYPE_KEYWORD, 0, true;

        case .STRUCT;
            return TOKEN_TYPE_KEYWORD, 0, true;

        case .ENUM;
            return TOKEN_TYPE_KEYWORD, 0, true;

        case .UNION;
            return TOKEN_TYPE_KEYWORD, 0, true;
    }

    return 0, 0, false;
}

// Return the length of a keyword token (just the keyword itself, not the expression).
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
    }
    return xx (node.location.c1 - node.location.c0); // fallback
}

// Add a simple one-node entry (used for parameters, polymorphic args, etc.)
add_simple_entry :: (node: *Node, entries: *[..]Token_Entry, token_type: u32, modifiers: u32) {
    if !node return;
    loc := node.location;
    length := loc.c1 - loc.c0;

    // Use actual name length for declarations
    if node.kind == .DECLARATION {
        decl := cast(*Declaration) node;
        length = decl.name.count;
    }

    if length <= 0 return;

    entry: Token_Entry;
    entry.line = xx loc.l0;
    entry.character = xx loc.c0;
    entry.length = xx length;
    entry.token_type = token_type;
    entry.token_modifiers = modifiers;
    array_add(entries, entry);
}

// Insertion sort — simple but fine for the typical token count per file.
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

// LSP delta encoding: [deltaLine, deltaStart, length, tokenType, tokenModifiers] per token
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
