
handle_completitions :: (request: LSP_Request_Message_Completion) {
    push_allocator(temp);

    file_path := normalize_path(request.params.textDocument.uri);

    file := get_file(file_path);
    if !file {
        lsp_respond(request.id, null);
        return;
    }

    cursor_location := lsp_location_to_node_location(request.params.position, file_path);

    // We don't wanna to give completions inside comments.
    if inside_comment(cursor_location) {
        lsp_respond(request.id, null);
        return;
    }

    cursor_node := get_node_by_location(file, cursor_location);

    // When cursor_node is null, check if there's a `.` before the cursor.
    // This handles positions past node boundaries (e.g., after `e.` where the
    // binary_op ends at the dot but cursor is at the newline).
    dot_ok := false;
    dot_fields: [..]*Declaration;
    if !cursor_node && cursor_location.c0 > 0 {
        lsp_pos: LSP_Position;
        lsp_pos.line = cast(u32) cursor_location.l0;
        lsp_pos.character = cast(u32) cursor_location.c0;
        line_text := find_line_in_memory_file(file_path, lsp_pos);
        if line_text.count > 0 && cursor_location.c0 - 1 < line_text.count {
            ch := line_text[cursor_location.c0 - 1];
            if ch == #char "." {
                    extract_dot_var_name: string;
                var_start := cursor_location.c0 - 2;
                while var_start >= 0 && line_text[var_start] != #char " " && line_text[var_start] != #char "\t" {
                    var_start -= 1;
                }
                if var_start < cursor_location.c0 - 2 {
                    start_i := var_start + 1;
                    var_len := cursor_location.c0 - 2 - start_i + 1;
                    if var_len > 0 {
                        extract_dot_var_name = copy_string(to_string(*line_text[start_i], var_len));
                    }
                }
                while extract_dot_var_name.count > 0 && extract_dot_var_name[extract_dot_var_name.count - 1] == #char "." {
                    extract_dot_var_name.count -= 1;
                }
                if extract_dot_var_name.count > 0 {
                    // get_node_by_location with .BLOCK filter often fails because
                    // the parser sometimes doesn't set accurate end locations on BLOCKs.
                    // Manually scan file.nodes for the deepest (last) BLOCK starting
                    // at or before the cursor line.
                    block_node: *Node = null;
                    for node: file.nodes {
                        if node.kind == .BLOCK && node.location.l0 <= cursor_location.l0 {
                            block_node = node;
                        }
                    }
                    if block_node {
                        block := cast(*Block) block_node;
                        for member, idx: block.members {
                            if member.location.l0 > cursor_location.l0 {
                                continue;
                            }
                            if member.location.l0 == cursor_location.l0 && member.location.c0 > cursor_location.c0 {
                                continue;
                            }

                            type_node: *Node;
                            if member.kind == .DECLARATION && member.(*Declaration).name == extract_dot_var_name {
                                decl := cast(*Declaration) member;
                                type_source: *Node = decl.type_inst;
                                if !type_source { type_source = decl.expression; }
                                if type_source {
                                    if type_source.kind == .IDENTIFIER {
                                        ts_ident := cast(*Identifier) type_source;
                                        type_decls := get_declarations(
                                            get_file(ts_ident.location.file),
                                            ts_ident, *ts_ident.location,
                                            ts_ident.name
                                        );
                                        if type_decls.count > 0 {
                                            type_node = get_node_type(type_decls[0]);
                                        }
                                    } else {
                                        type_node = get_node_type(type_source);
                                    }
                                }
                            } else if member.kind == .COMPOUND_DECLARATION {
                                target_idx := resolve_compound_var_index(member, extract_dot_var_name);
                                if target_idx >= 0 {
                                    cd := cast(*Compound_Declaration) member;
                                    type_node = resolve_compound_var_type(cd, target_idx);
                                }
                            }

                            if type_node {
                                fields := get_type_fields(type_node);
                                if fields.count > 0 {
                                    dot_ok = true;
                                    dot_fields = fields;
                                    break;
                                }
                            }
                        }
                    }

                    // Block scan missed it — scan all file nodes for the declaration.
                    if !dot_ok {
                        dot_ok, dot_fields = dot_completion_file_scan_fallback(file, cursor_location, extract_dot_var_name);
                    }
                }
            }
        }
    }

    if cursor_node {
        // Prefer source-text receiver scan before node-tree dot resolution.
        // Node-tree resolution can choose the type declaration (Type.) rather
        // than the instance declaration (v.) when cursor sits at dot boundary.
        if !dot_ok {
            dot_ok, dot_fields = dot_completion_file_scan_fallback(file, cursor_location);
        }

        // Dot completion via node tree (for nodes that have valid parents)
        if !dot_ok {
            dot_ok, dot_fields = handle_dot_completitions(request, cursor_node, cursor_location);
        }

        // If node-tree dot resolution failed, try file-node scan fallback
        if !dot_ok {
            dot_ok, dot_fields = dot_completion_file_scan_fallback(file, cursor_location);
        }

        if handle_assignment_completitions(request, cursor_node) {
            return;
        }

        if handle_case_completions(request, cursor_node) {
            return;
        }

        if handle_types_in_declaration(request, cursor_node) {
            return;
        }

        if handle_struct_literal_completitions(request, cursor_node) {
            return;
        }
    }

    // Dot completions: only struct fields/constants, no keywords or general decls.
    if dot_ok && dot_fields.count > 0 {
        send_completions_decls(request, dot_fields, file=file);
        return;
    }

    // General
    decls := get_declarations(file, cursor_node, *cursor_location);

    // Extract prefix: what user has typed so far.
    prefix: string;
    if cursor_node && cursor_node.kind == .IDENTIFIER {
        ident := cast(*Identifier) cursor_node;
        prefix = ident.name;
    }

    send_completions_decls(request, decls, file=file, prefix=prefix);
}
handle_completitions_load :: (request: LSP_Request_Message_Completion, file: *Program_File, directive_load: *Directive_Load) {
    completions: [..]LSP_Completion_Item;
    current_file_dir := path_strip_filename(file.path);

    visit_file :: (info: *File_Visit_Info, completions: *[..]LSP_Completion_Item) {
        if !info.is_directory && !contains(info.short_name, ".jai") return;

        array_add(completions, .{
            label=info.short_name,
            kind=xx (ifx info.is_directory then LSP_Completion_Item.Kind.Folder else LSP_Completion_Item.Kind.File),
            insertText=info.short_name,
            insertTextFormat=xx LSP_Completion_Item.Insert_Text_Format.SNIPPET,
            labelDetails = .{ description=info.full_name }
        });
    }

    path_to_visit := current_file_dir;
    if contains(directive_load.file, "/") {
        path_to_visit = tprint("%/%", path_to_visit, directive_load.file);
    }

    is_dir, ok := is_directory(path_to_visit);
    if !is_dir || !ok {
        lsp_respond(request.id, null);
        return;
    }

    visit_files(path_to_visit, false, *completions, visit_file, true, true);

    lsp_respond(request.id, completions);
}

handle_completitions_import :: (request: LSP_Request_Message_Completion, directive_import: *Directive_Import) {
    completions: [..]LSP_Completion_Item;

    modules_dir := sprint("%/modules", server.args.jai_path);

    visit_modules :: (info: *File_Visit_Info, completions: *[..]LSP_Completion_Item) {
        if !info.is_directory && !contains(info.short_name, ".jai") return;

        module_name := info.short_name;
        if !info.is_directory {
            module_name = replace(info.short_name, ".jai", "");
        } else {
            if !file_exists(tprint("%/module.jai", info.full_name)) return;
        }

        array_add(completions, .{
            label=module_name,
            kind=xx LSP_Completion_Item.Kind.Module,
            insertText=module_name,
            insertTextFormat=xx LSP_Completion_Item.Insert_Text_Format.SNIPPET,
            labelDetails = .{ description=info.full_name }
        });
    }

    // Compiler modules
    visit_files(modules_dir, false, *completions, visit_modules, true, true);

    // Local modules
    for local_module: server.local_modules {
        local_modules_dir := tprint("%/%", server.project_root, local_module);
        visit_files(local_modules_dir, false, *completions, visit_modules, true, true);
    }

    lsp_respond(request.id, completions);
}

handle_dot_completitions :: (request: LSP_Request_Message_Completion, cursor_node: *Node, cursor_location: Node.Location) -> (bool, [..]*Declaration) {
    empty: [..]*Declaration;

    if !cursor_node {
        return false, empty;
    }

    op: *Binary_Operation;
    if is_dot_binary_op(cursor_node) {
        op = cast(*Binary_Operation) cursor_node;
    } else if is_dot_binary_op(cursor_node.parent) {
        op = cast(*Binary_Operation) cursor_node.parent;
    } else {
        return false, empty;
    }

    root_binary_op := op;
    while root_binary_op.right && root_binary_op.right.kind == .BINARY_OPERATION {
        right := cast(*Binary_Operation) root_binary_op.right;
        if right.operation != .DOT || is_after(cursor_location, right.location) {
            break;
        }

        root_binary_op = right;
    }

    if root_binary_op.operation != .DOT {
        return false, empty;
    }

    path: [..]*Node;

    // Expand a BINARY_OPERATION DOT into [left, right, ...] recursively.
    flatten_dot_path :: (node: *Node, out: *[..]*Node) {
        if node.kind == .BINARY_OPERATION {
            op := cast(*Binary_Operation) node;
            if op.operation == .DOT {
                if op.left  flatten_dot_path(op.left,  out);
                if op.right flatten_dot_path(op.right, out);
                return;
            }
        }
        array_add(out, node);
    }

    flatten_dot_path(root_binary_op.left, *path);

    current := root_binary_op.parent;
    while current && current.kind == .BINARY_OPERATION {
        current_op := cast(*Binary_Operation) current;
        if current_op.operation != .DOT {
            break;
        }

        if current_op.left {
            flatten_dot_path(current_op.left, *path);
        }

        current = current.parent;
    }

    array_reverse(path);

    type := get_path_type(path);
    if type {
        fields := get_type_fields(type);
        if fields.count > 0 {
            return true, fields;
        }
    }

    // Fallback: get_path_type returns the unresolved IDENTIFIER node itself
    // when it can't find the declaration. Scan enclosing BLOCK for local
    // variable declarations instead.
    var_name: string;
    if root_binary_op.left && root_binary_op.left.kind == .IDENTIFIER {
        left_ident := cast(*Identifier) root_binary_op.left;
        var_name = left_ident.name;
    }

    if var_name.count > 0 {
        current_node: *Node = root_binary_op;
        block: *Block;
        while current_node {
            if current_node.kind == .BLOCK {
                block = cast(*Block) current_node;
                break;
            }
            current_node = current_node.parent;
        }

        if block {
            for member, idx: block.members {
                // Skip members that appear AFTER the cursor position
                // NOTE: is_after is unreliable here (column check doesn't
                // account for different lines). Use explicit line/col compare.
                if member.location.l0 > cursor_location.l0 {
                    continue;
                }
                if member.location.l0 == cursor_location.l0 && member.location.c0 > cursor_location.c0 {
                    continue;
                }

                type_node: *Node;

                if member.kind == .DECLARATION && member.(*Declaration).name == var_name {
                    decl := cast(*Declaration) member;
                    type_source: *Node = decl.type_inst;
                    if !type_source { type_source = decl.expression; }
                    if type_source {
                        if type_source.kind == .IDENTIFIER {
                            ts_ident := cast(*Identifier) type_source;
                            type_decls := get_declarations(
                                get_file(ts_ident.location.file),
                                ts_ident, *ts_ident.location,
                                ts_ident.name
                            );
                            if type_decls.count > 0 {
                                type_node = get_node_type(type_decls[0]);
                            }
                        } else {
                            type_node = get_node_type(type_source);
                        }
                    }
                } else if member.kind == .COMPOUND_DECLARATION {
                    target_idx := resolve_compound_var_index(member, var_name);
                    if target_idx >= 0 {
                        cd := cast(*Compound_Declaration) member;
                        type_node = resolve_compound_var_type(cd, target_idx);
                    }
                }

                if type_node {
                    fields := get_type_fields(type_node);
                    if fields.count > 0 {
                        return true, fields;
                    }
                }
            }
        }
    }

    return false, empty;
}

handle_types_in_declaration :: (request: LSP_Request_Message_Completion, cursor_node: *Node) -> bool {
    if cursor_node.kind == .UNARY_OPERATION && cursor_node.parent && cursor_node.parent.kind == .DECLARATION {
        node_type := get_node_type(cursor_node.parent);

        return handle_completitions_for_node(request, node_type);
    }


    return false;
}

handle_case_completions :: (request: LSP_Request_Message_Completion, cursor_node: *Node) -> bool {
    if cursor_node.kind == .UNARY_OPERATION && cursor_node.parent && cursor_node.parent.kind == .CASE {
        case_node := cast(*Case)cursor_node.parent;

        if case_node.parent && case_node.parent.kind == .BLOCK && case_node.parent.parent && case_node.parent.parent.kind == .IF {
            if_node := cast(*If)case_node.parent.parent;

            case_type := get_node_type(if_node.condition, true);
            if !case_type {
                return false;
            }

            return handle_completitions_for_node(request, case_type);
        }
    }

    return false;
}

handle_struct_literal_completitions :: (request: LSP_Request_Message_Completion, cursor_node: *Node) -> bool {
    // Walk up parent chain to find enclosing struct literal
    literal_node: *Literal;
    current := cursor_node;
    while current {
        if current.kind == .LITERAL && current.(*Literal).value_type == Literal.Value_Type.STRUCT {
            literal_node = cast(*Literal) current;
            break;
        }
        current = current.parent;
    }

    if !literal_node return false;

    // Get struct type — either explicit (Vector3.{...}) or inferred (.{...})
    type_node := literal_node.values.struct_literal_info.type;

    if !type_node {
        // Dotless struct literal — infer type from parent declaration
        parent := literal_node.parent;
        while parent {
            if parent.kind == .DECLARATION {
                decl := cast(*Declaration) parent;
                if decl.type_inst {
                    if decl.type_inst.kind == .TYPE_INSTANTIATION {
                        ti := cast(*Type_Instantiation) decl.type_inst;
                        type_node = ti.expression;
                    } else {
                        type_node = decl.type_inst;
                    }
                }
                break;
            }
            parent = parent.parent;
        }
    }

    if !type_node return false;

    // Resolve identifier to actual struct/type node
    resolved_type := get_node_type(type_node);
    if !resolved_type resolved_type = type_node;

    // Get all fields of the struct type
    all_fields: [..]*Declaration;
    defer array_free(all_fields);
    add_all_fields_of(*all_fields, resolved_type);

    if all_fields.count == 0 return false;

    // Get already-assigned field names from the struct literal body
    assigned: [..]string;
    defer array_free(assigned);
    for body_node: literal_node.values.struct_literal_info.body {
        if body_node.kind == .BINARY_OPERATION {
            op := cast(*Binary_Operation) body_node;
            if op.operation == .ASSIGN && op.left && op.left.kind == .IDENTIFIER {
                array_add(*assigned, op.left.(*Identifier).name);
            }
        }
    }

    // Filter out already-assigned fields
    result: [..]*Declaration;
    defer array_free(result);
    for field: all_fields {
        skip := false;
        for assigned_name: assigned {
            if field.name == assigned_name { skip = true; break; }
        }
        if !skip array_add(*result, field);
    }

    send_completions_decls(request, result);
    return true;
}

handle_assignment_completitions :: (request: LSP_Request_Message_Completion, cursor_node: *Node) -> bool {
    op: *Binary_Operation;
    if cursor_node.kind == .BINARY_OPERATION {
        op = cast(*Binary_Operation, cursor_node);
    } else if cursor_node.parent && cursor_node.parent.kind == .BINARY_OPERATION {
        op = cast(*Binary_Operation, cursor_node.parent);
    } else {
        return false;
    }

    // Any binary operation with a resolvable left side triggers left-side completions.
    // DOT operations are handled separately by handle_dot_completitions.
    if op.operation == .DOT {
        return false;
    }

    // @TODO: support more types!
    if cursor_node.kind != .UNARY_OPERATION {
        return false;
    }

    left_type := get_node_type(op, true);
    if !left_type {
        return false;
    }

    return handle_completitions_for_node(request, left_type);
}

// ── Local variable scanner ──────────────────────────────────────────────────

// Recursively scan a BLOCK and its sub-blocks for a local variable declaration
// before cursor_position. Returns the declaration (or null).
scan_var_in_block :: (block: *Block, var_name: string, cursor_location: Node.Location) -> *Declaration {
    for member: block.members {
        if cursor_location.l0 < member.location.l0 continue;

        if member.kind == .DECLARATION {
            decl := cast(*Declaration) member;
            if decl.name == var_name return decl;
        } else if member.kind == .COMPOUND_DECLARATION {
            cd := cast(*Compound_Declaration) member;
            for item: cd.members {
                if item.kind != .COMPOUND_DECLARATION_ITEM continue;
                cdi := cast(*Compound_Declaration_Item) item;
                if cdi.expression.kind != .IDENTIFIER continue;
                if (cast(*Identifier) cdi.expression).name == var_name return cast(*Declaration) cd;
            }
        }

        // Recurse into sub-blocks
        if member.kind == .BLOCK {
            r := scan_var_in_block(cast(*Block) member, var_name, cursor_location);
            if r return r;
        } else if member.kind == .IF {
            if_node := cast(*If) member;
            if if_node._then {
                r := scan_var_in_block(cast(*Block) if_node._then, var_name, cursor_location);
                if r return r;
            }
            if if_node._else {
                r := scan_var_in_block(cast(*Block) if_node._else, var_name, cursor_location);
                if r return r;
            }
        } else if member.kind == .FOR {
            for_node := cast(*For) member;
            if for_node.body {
                r := scan_var_in_block(cast(*Block) for_node.body, var_name, cursor_location);
                if r return r;
            }
        } else if member.kind == .WHILE {
            while_node := cast(*While) member;
            if while_node.body {
                r := scan_var_in_block(cast(*Block) while_node.body, var_name, cursor_location);
                if r return r;
            }
        }
    }
    return null;
}

// ── Compound declaration helpers ──────────────────────────────────────────

// Scan file.nodes for a declaration matching the variable before a dot.
// Used as fallback when block scan and node-tree dot resolution both fail.
dot_completion_file_scan_fallback :: (file: *Program_File, cursor_location: Node.Location, var_name_hint: string = "") -> (bool, [..]*Declaration) {
    empty: [..]*Declaration;

    // Extract variable name from source text if not provided
    var_name := var_name_hint;
    if var_name.count == 0 {
        lsp_pos: LSP_Position;
        lsp_pos.line = cast(u32) cursor_location.l0;
        lsp_pos.character = cast(u32) cursor_location.c0;
        line_text := find_line_in_memory_file(file.path, lsp_pos);
        if line_text.count > 0 {
            // Determine where the variable name ends (before the dot)
            dot_col: s32 = -1;
            // Try: cursor is on the dot (var. → char = '.')
            if cursor_location.c0 < line_text.count && line_text[cursor_location.c0] == #char "." {
                dot_col = cast(s32) cursor_location.c0;
            }
            // Try: cursor is after the dot (var.fi → char before cursor = '.')
            if dot_col < 0 && cursor_location.c0 > 0 && cursor_location.c0 - 1 < line_text.count && line_text[cursor_location.c0 - 1] == #char "." {
                dot_col = cast(s32) cursor_location.c0 - 1;
            }
            // Try: cursor past end of line — check last char if it's '.'
            if dot_col < 0 && line_text.count > 0 && line_text[line_text.count - 1] == #char "." {
                dot_col = cast(s32) line_text.count - 1;
            }
            if dot_col >= 0 {
                var_start := dot_col - 1;
                while var_start >= 0 && ((line_text[var_start] >= #char "a" && line_text[var_start] <= #char "z") || (line_text[var_start] >= #char "A" && line_text[var_start] <= #char "Z") || (line_text[var_start] >= #char "0" && line_text[var_start] <= #char "9") || line_text[var_start] == #char "_" || line_text[var_start] == #char ".") {
                    var_start -= 1;
                }
                start_i := var_start + 1;
                var_len := dot_col - start_i;
                if var_len > 0 {
                    var_name = copy_string(to_string(*line_text[start_i], var_len));
                }
            }
        }
    }
    if var_name.count == 0 return false, empty;

    // Double/trailing dots like `rs..` can leave `var_name` ending in `.`.
    // Treat that as the same receiver path (`rs`) instead of creating an
    // empty final path segment and indexing past the string end.
    while var_name.count > 0 && var_name[var_name.count - 1] == #char "." {
        var_name.count -= 1;
    }
    if var_name.count == 0 return false, empty;

    // Phase 1 — scan top-level declarations (file.nodes)
    for node: file.nodes {
        if node.kind == .DECLARATION && node.(*Declaration).name == var_name {
            decl := cast(*Declaration) node;
            type_source: *Node = decl.type_inst;
            if !type_source { type_source = decl.expression; }
            if type_source {
                // Pass PROCEDURE_CALL directly so polymorphic args are
                // available for per-instantiation #insert field filtering.
                node_to_resolve := type_source;
                if type_source.kind == .PROCEDURE_CALL {
                    node_to_resolve = type_source;
                } else {
                    node_to_resolve = get_node_type(type_source);
                }
                fields := get_type_fields(node_to_resolve);
                append_inserted_fields_for_decl_exact(*fields, decl);
                if fields.count > 0 {
                    return true, fields;
                }
            }
        } else if node.kind == .COMPOUND_DECLARATION {
            target_idx := resolve_compound_var_index(node, var_name);
            if target_idx >= 0 {
                cd := cast(*Compound_Declaration) node;
                type_node := resolve_compound_var_type(cd, target_idx);
                if type_node {
                    fields := get_type_fields(type_node);
                    if fields.count > 0 {
                        return true, fields;
                    }
                }
            }
        }
    }

    // Phase 2 — scan procedure bodies for local variables
    for node: file.nodes {
        if node.kind != .DECLARATION continue;
        root_decl := cast(*Declaration) node;
        if !root_decl.expression || root_decl.expression.kind != .PROCEDURE continue;
        proc := cast(*Procedure) root_decl.expression;
        if !proc.body continue;

        local_decl := scan_var_in_block(proc.body, var_name, cursor_location);
        if local_decl {
            // Resolve type from the local declaration
            type_source: *Node;
            if local_decl.kind == .DECLARATION {
                d := cast(*Declaration) local_decl;
                type_source = d.type_inst;
                if !type_source type_source = d.expression;
            } else if local_decl.kind == .COMPOUND_DECLARATION {
                cd := cast(*Compound_Declaration) local_decl;
                type_source = cast(*Node) cd.type_inst;
            }
            if type_source {
                // Pass PROCEDURE_CALL directly so polymorphic args are
                // available for per-instantiation #insert field filtering.
                node_to_resolve := type_source;
                if type_source.kind == .PROCEDURE_CALL {
                    node_to_resolve = type_source;
                } else {
                    node_to_resolve = get_node_type(type_source);
                }
                fields := get_type_fields(node_to_resolve);
                if local_decl.kind == .DECLARATION {
                    append_inserted_fields_for_decl_exact(*fields, cast(*Declaration) local_decl);
                }
                if fields.count > 0 {
                    return true, fields;
                }
            }
        }
    }

    // Phase 3 — multi-segment path fallback (e.g. "engine.packages").
    // Keep polymorphic instantiations as PROCEDURE_CALL nodes so implicit
    // fields like Engine($packages).packages can map to call arguments.
    if var_name.count > 0 {
        dot_pos := -1;
        for i: 0 .. var_name.count - 1 {
            if var_name[i] == #char "." dot_pos = i;
        }

        if dot_pos > 0 {
            seg_count := 1;
            for c: var_name {
                if c == #char "." seg_count += 1;
            }

            seg_names: [..]string;
            seg_start: int;
            for idx: 0 .. seg_count - 1 {
                next_dot := -1;
                for i: seg_start .. var_name.count - 1 {
                    if var_name[i] == #char "." {
                        next_dot = i;
                        break;
                    }
                }

                if next_dot >= 0 {
                    seg_len := next_dot - seg_start;
                    array_add(*seg_names, to_string(*var_name[seg_start], seg_len));
                    seg_start = next_dot + 1;
                } else {
                    array_add(*seg_names, to_string(*var_name[seg_start], var_name.count - seg_start));
                }
            }

            resolve_type_source_for_path :: (source: *Node) -> *Node {
                if !source return null;
                if source.kind == .PROCEDURE_CALL return source;
                if source.kind == .TYPE_INSTANTIATION {
                    ti := cast(*Type_Instantiation) source;
                    if ti.expression return ti.expression;
                }
                return get_node_type(source);
            }

            first_var := seg_names[0];
            found_decl: *Declaration;
            for node: file.nodes {
                if node.kind == .DECLARATION && node.(*Declaration).name == first_var {
                    found_decl = cast(*Declaration) node;
                    break;
                }
            }
            if !found_decl {
                for node: file.nodes {
                    if node.kind != .DECLARATION continue;
                    root_decl := cast(*Declaration) node;
                    if !root_decl.expression || root_decl.expression.kind != .PROCEDURE continue;
                    proc := cast(*Procedure) root_decl.expression;
                    if !proc.body continue;

                    local := scan_var_in_block(proc.body, first_var, cursor_location);
                    if local && local.kind == .DECLARATION {
                        found_decl = cast(*Declaration) local;
                        break;
                    }
                }
            }

            if found_decl {
                type_source: *Node = found_decl.type_inst;
                if !type_source type_source = found_decl.expression;
                current_type := resolve_type_source_for_path(type_source);
                ok := current_type != null;

                for i: 1 .. seg_names.count - 1 {
                    if !ok break;

                    field_name := seg_names[i];
                    field_type: *Node;
                    found_field: bool;

                    if current_type.kind == .STRUCT {
                        _struct := cast(*Struct) current_type;
                        if !_struct.block { ok = false; break; }

                        for member: _struct.block.members {
                            if member.kind != .DECLARATION continue;
                            mdecl := cast(*Declaration) member;
                            if mdecl.name != field_name continue;

                            field_type = mdecl.type_inst;
                            if !field_type field_type = mdecl.expression;
                            found_field = true;
                            break;
                        }
                    } else if current_type.kind == .PROCEDURE_CALL {
                        pc := cast(*Procedure_Call) current_type;
                        if !pc.procedure || pc.procedure.kind != .IDENTIFIER { ok = false; break; }

                        pc_decls := get_identifier_decls(cast(*Identifier) pc.procedure);
                        for d: pc_decls {
                            _struct := find_struct_of_expression(d.expression);
                            if !_struct continue;

                            if _struct.block {
                                for member: _struct.block.members {
                                    if member.kind != .DECLARATION continue;
                                    mdecl := cast(*Declaration) member;
                                    if mdecl.name != field_name continue;

                                    field_type = mdecl.type_inst;
                                    if !field_type field_type = mdecl.expression;
                                    found_field = true;
                                    break;
                                }
                            }

                            if !found_field && _struct.polymorphic_arguments.count > 0 {
                                for arg, arg_i: _struct.polymorphic_arguments {
                                    param_name := get_polymorphic_param_name(arg);
                                    if param_name.count > 0 && param_name == field_name && arg_i < pc.arguments.count {
                                        field_type = pc.arguments[arg_i];
                                        found_field = true;
                                        break;
                                    }
                                }
                            }

                            if found_field break;
                        }
                    } else {
                        ok = false;
                        break;
                    }

                    if !found_field || !field_type {
                        ok = false;
                        break;
                    }

                    current_type = resolve_type_source_for_path(field_type);
                    if !current_type ok = false;
                }

                if ok {
                    fields := get_type_fields(current_type);
                    if fields.count > 0 return true, fields;
                }
            }
        }
    }
    return false, empty;
}

// Resolve var index in a,b,c := expr() compound declaration.
resolve_compound_var_index :: (member: *Node, name: string) -> int {
    if member.kind != .COMPOUND_DECLARATION return -1;
    cd := cast(*Compound_Declaration) member;
    for item, idx: cd.members {
        if item.kind == .COMPOUND_DECLARATION_ITEM {
            cdi := cast(*Compound_Declaration_Item) item;
            if cdi.expression.kind == .IDENTIFIER {
                if (cast(*Identifier) cdi.expression).name == name return idx;
            }
        }
    }
    return -1;
}

// Resolve type of the idx-th variable in a compound declaration.
resolve_compound_var_type :: (cd: *Compound_Declaration, idx: int) -> *Node {
    if !cd.type_inst || !cd.type_inst.expression return null;
    expr := cd.type_inst.expression;
    if expr.kind == .PROCEDURE_CALL {
        proc_node := get_node_type(expr, stop_at_procedure=true);
        if proc_node && proc_node.kind == .PROCEDURE {
            proc := cast(*Procedure) proc_node;
            if idx < proc.returns.count {
                return get_node_type(proc.returns[idx].expression);
            }
        }
    } else if expr.kind == .COMMA_SEPARATED_EXPRESSION {
        cse := cast(*Comma_Separated_Expression) expr;
        if idx < cse.members.count {
            return get_node_type(cse.members[idx]);
        }
    }
    return null;
}

// ── Inserted/harvested field helpers ────────────────────────────────────────

append_unique_completion_decl :: (decls: *[..]*Declaration, decl: *Declaration) {
    for existing: decls.* {
        if existing.name == decl.name return;
    }
    array_add(decls, decl);
}

get_decl_type_id :: (decl: *Declaration) -> u64, bool {
    if !decl return 0, false;
    key := decl_type_key(decl.location.file, decl.location.l0, decl.location.c0, decl.name);
    ok, type_id := table_find(*server.decl_type_ids, key);
    if ok return type_id, true;
    fallback_key := decl_type_key_fallback(decl.location.file, decl.name);
    ok, type_id = table_find(*server.decl_type_ids, fallback_key);
    if ok return type_id, true;
    return 0, false;
}

append_inserted_fields_for_type_id :: (decls: *[..]*Declaration, type_id: u64) -> bool {
    if type_id == 0 return false;
    ok, inserted := table_find(*server.inserted_fields_by_type_id, type_id);
    if !ok return false;

    for field: inserted {
        append_unique_completion_decl(decls, field);
    }
    return true;
}

append_inserted_fields_for_decl_exact :: (decls: *[..]*Declaration, decl: *Declaration) -> bool {
    type_id, ok := get_decl_type_id(decl);
    if !ok return false;
    return append_inserted_fields_for_type_id(decls, type_id);
}

append_inserted_fields_for_name :: (decls: *[..]*Declaration, name: string) -> bool {
    found: bool;
    ok, inserted_by_name := table_find(*server.inserted_fields_by_name, name);
    if ok {
        for field: inserted_by_name {
            append_unique_completion_decl(decls, field);
        }
        found = true;
    }

    for inserted, source_decl: server.inserted_fields {
        if !source_decl || source_decl.name != name continue;
        for field: inserted {
            append_unique_completion_decl(decls, field);
        }
        found = true;
    }
    return found;
}

append_inserted_fields_for_bake_source :: (decls: *[..]*Declaration, decl: *Declaration) -> bool {
    if !decl.expression || decl.expression.kind != .DIRECTIVE_BAKE_ARGUMENTS return false;

    dba := cast(*Directive_Bake_Arguments) decl.expression;
    if !dba.expression return false;

    if dba.expression.kind == .IDENTIFIER {
        ident := cast(*Identifier) dba.expression;
        return append_inserted_fields_for_name(decls, ident.name);
    }

    if dba.expression.kind == .PROCEDURE_CALL {
        pc := cast(*Procedure_Call) dba.expression;
        if pc.procedure && pc.procedure.kind == .IDENTIFIER {
            ident := cast(*Identifier) pc.procedure;
            return append_inserted_fields_for_name(decls, ident.name);
        }
    }

    return false;
}

append_inserted_fields_for_bake_decl_name :: (decls: *[..]*Declaration, name: string) -> bool {
    for file: server.files {
        if !file continue;
        for node: file.nodes {
            if node.kind != .DECLARATION continue;
            decl := cast(*Declaration) node;
            if decl.name != name continue;
            if append_inserted_fields_for_bake_source(decls, decl) return true;
        }
    }
    return false;
}

// ── Harvested field filtering for polymorphic instantiation ────────────────

// Check if a harvested field name matches a type-instantiation argument.
// Handles the common `sprint("%, %_2, ...", param, ...)` pattern where
// generated field names equal the argument value or have an `_N` suffix:
//   Test_Type("hello") → fields "hello", "hello_2", "hello_3"
harvested_field_matches_arg :: (name: string, arg: *Node) -> bool {
    if !arg || arg.kind != .LITERAL return false;
    lit := cast(*Literal) arg;
    if lit.value_type != .STRING return false;
    arg_val := lit._string;
    if arg_val.count == 0 return false;
    // Exact match: "hello" == "hello"
    if name == arg_val return true;
    // Prefix match: "hello_2" starts with "hello_"
    if name.count > arg_val.count
        && find_index_from_left(name, arg_val) == 0
        && name[arg_val.count] == #char "_"
    {
        return true;
    }
    return false;
}

harvested_field_matches_any_arg :: (name: string, args: []*Node) -> bool {
    for arg: args {
        if harvested_field_matches_arg(name, arg) return true;
    }
    return false;
}

// Like append_inserted_fields_for_decl but filters harvested fields to only
// include those whose names match the given type-instantiation arguments.
// Handles the common `sprint("%, %_2, ...", param, ...)` pattern where
// generated field names equal string-literal argument values.
// When no args match (non-string args or no args), falls back to unfiltered
// to avoid hiding all harvested fields from non-string-arg instantiations.
append_inserted_fields_filtered :: (decls: *[..]*Declaration, decl: *Declaration, filter_args: []*Node) {
    ok, inserted := table_find(*server.inserted_fields, decl);
    if !ok {
        // Fall back to name-keyed cache, also with filtering
        ok, inserted_by_name := table_find(*server.inserted_fields_by_name, decl.name);
        if ok {
            had_match: bool;
            for field: inserted_by_name {
                if harvested_field_matches_any_arg(field.name, filter_args) {
                    append_unique_completion_decl(decls, field);
                    had_match = true;
                }
            }
            if !had_match {
                // No field matched the filter args. Could be a non-string-arg
                // instantiation (e.g. Vec4 :: Vector(4) where arg is integer).
                // Add all fields to avoid hiding harvested completions.
                for field: inserted_by_name {
                    append_unique_completion_decl(decls, field);
                }
            }
        }
        return;
    }
    had_match: bool;
    for field: inserted {
        if harvested_field_matches_any_arg(field.name, filter_args) {
            append_unique_completion_decl(decls, field);
            had_match = true;
        }
    }
    if !had_match {
        // Fallback: add all when filter matched nothing
        for field: inserted {
            append_unique_completion_decl(decls, field);
        }
    }
}

append_inserted_fields_for_decl :: (decls: *[..]*Declaration, decl: *Declaration, label: string = "") {
    if append_inserted_fields_for_decl_exact(decls, decl) return;

    ok, inserted := table_find(*server.inserted_fields, decl);
    if !ok {
        // Declarations can be re-parsed between diagnostics harvest and
        // completion. Pointer-key lookup then misses even though the source
        // declaration name is stable. Fall back to matching the harvested key
        // declaration name; this covers compiler struct dumps for baked types.
        if append_inserted_fields_for_name(decls, decl.name) return;
        if append_inserted_fields_for_bake_source(decls, decl) return;
        return;
    }

    for field: inserted {
        append_unique_completion_decl(decls, field);
    }
}

// Collect type fields for a node without sending any response.
// Returns decls in declaration form (caller converts to LSP items).
get_type_fields :: (node: *Node) -> [..]*Declaration {
    decls: [..]*Declaration;

    // Macro so inline-declared arrays survive to parent scope.
    add_decls_from_internal_array_struct :: (decls: *[..]*Declaration, resizable: bool, type: *Node) #expand {
        internal_array_struct := get_internal_array_struct(resizable);
        if !internal_array_struct { return; }

        for member: internal_array_struct.block.members {
            if member.kind != .DECLARATION continue;
            decl := cast(*Declaration) member;
            if decl.name == "data" && type {
                data_decl := Declaration.{
                    name = "data",
                    type_inst = *(Unary_Operation.{
                        operation=.POINTER, expression=type
                    }),
                };
                array_add(decls, *data_decl);
                continue;
            }
            array_add(decls, decl);
        }
    }

    if node.kind == {
        case .UNION; #through;
        case .ENUM; #through;
        case .STRUCT;
            _struct := cast(*Struct) node;
            add_all_fields_of(*decls, node);

            // Add polymorphic parameter names as synthetic fields
            for arg: _struct.polymorphic_arguments {
                param_name := get_polymorphic_param_name(arg);
                if param_name.count == 0 continue;
                synth_decl := New(Declaration);
                synth_decl.name = param_name;
                synth_decl.const = false;
                synth_decl.has_elsewhere = false;
                append_unique_completion_decl(*decls, synth_decl);
            }

            // Add compiler-harvested #insert fields
            // NOTE: STRUCT case is hit from get_node_type which loses type
            // args, so no filtering here. Callers that have type args should
            // pass PROCEDURE_CALL directly to get_type_fields instead.
            if node.parent && node.parent.kind == .DECLARATION {
                parent_decl := cast(*Declaration) node.parent;
                append_inserted_fields_for_decl_exact(*decls, parent_decl);
            }
        case .TYPE_INSTANTIATION;
            ti := cast(*Type_Instantiation) node;
            // If the target expression is an IDENTIFIER, resolve it to its
            // declaration and get the underlying struct's fields.
            if ti.expression && ti.expression.kind == .IDENTIFIER {
                ident := cast(*Identifier) ti.expression;
                ident_decls := get_identifier_decls(ident);
                type_decls: [..]*Declaration;
                array_add(*type_decls, .. ident_decls);

                if type_decls.count == 0 && ident.location.file.count > 0 {
                    local_file := get_file(ident.location.file);
                    if local_file {
                        ok, local_decl := table_find(*local_file.declarations, ident.name);
                        if ok append_unique_completion_decl(*type_decls, local_decl);
                    }
                }
                // Collect type-instantiation arguments for #insert field filtering
                ti_args: [..]*Node;
                if ti.expression && ti.expression.kind == .PROCEDURE_CALL {
                    ti_pc := cast(*Procedure_Call) ti.expression;
                    array_add(*ti_args, .. ti_pc.arguments);
                }

                for d: type_decls {
                    _struct := find_struct_of_expression(d.expression);
                    if _struct {
                        add_all_fields_of(*decls, _struct);
                        if ti_args.count > 0 {
                            append_inserted_fields_filtered(*decls, d, ti_args);
                        } else {
                            append_inserted_fields_for_decl(*decls, d, "ti-struct");
                        }

                        if _struct.polymorphic_arguments.count > 0 {
                            for arg, arg_i: _struct.polymorphic_arguments {
                                param_name := get_polymorphic_param_name(arg);
                                if param_name.count > 0 {
                                    synth_decl := New(Declaration);
                                    synth_decl.name = param_name;
                                    synth_decl.const = false;
                                    synth_decl.has_elsewhere = false;
                                    if arg_i < ti_args.count {
                                        synth_decl.type_inst = ti_args[arg_i];
                                    }
                                    append_unique_completion_decl(*decls, synth_decl);
                                }
                            }
                        }
                    }
                }
            }

        case .PROCEDURE_CALL;
            proc_call := cast(*Procedure_Call) node;
            if proc_call.procedure && proc_call.procedure.kind == .IDENTIFIER {
                ident := cast(*Identifier) proc_call.procedure;
                ident_decls := get_identifier_decls(ident);
                proc_type_decls: [..]*Declaration;
                array_add(*proc_type_decls, .. ident_decls);

                if proc_type_decls.count == 0 {
                    if ident.location.file.count > 0 {
                        local_file := get_file(ident.location.file);
                        if local_file {
                            ok, local_decl := table_find(*local_file.declarations, ident.name);
                            if ok append_unique_completion_decl(*proc_type_decls, local_decl);
                        }
                    }
                    if proc_type_decls.count == 0 {
                        for f: server.files {
                            ok, found_decl := table_find(*f.declarations, ident.name);
                            if ok append_unique_completion_decl(*proc_type_decls, found_decl);
                        }
                    }
                }
                for d: proc_type_decls {
                    _struct := find_struct_of_expression(d.expression);
                    if _struct {
                        add_all_fields_of(*decls, _struct);
                        append_inserted_fields_filtered(*decls, d, proc_call.arguments);

                        if _struct.polymorphic_arguments.count > 0 {
                            for arg, arg_i: _struct.polymorphic_arguments {
                                param_name := get_polymorphic_param_name(arg);
                                if param_name.count > 0 {
                                    synth_decl := New(Declaration);
                                    synth_decl.name = param_name;
                                    synth_decl.const = false;
                                    synth_decl.has_elsewhere = false;
                                    if arg_i < proc_call.arguments.count {
                                        synth_decl.type_inst = proc_call.arguments[arg_i];
                                    } else {
                                        synth_decl.type_inst = *empty_identifier;
                                    }
                                    append_unique_completion_decl(*decls, synth_decl);
                                }
                            }
                        }
                    } else {
                        append_inserted_fields_filtered(*decls, d, proc_call.arguments);
                    }
                }

                if decls.count == 0 {
                    if !append_inserted_fields_for_name(*decls, ident.name) {
                        // For polymorphic instantiations, also filter name-based fallback
                        ok, by_name_fields := table_find(*server.inserted_fields_by_name, ident.name);
                        if ok && proc_call.arguments.count > 0 {
                            for field: by_name_fields {
                                if harvested_field_matches_any_arg(field.name, proc_call.arguments) {
                                    append_unique_completion_decl(*decls, field);
                                }
                            }
                        }
                        if decls.count == 0 {
                            append_inserted_fields_for_bake_decl_name(*decls, ident.name);
                        }
                    }
                }
            }

        case .ARRAY_TYPE;
            array_type := cast(*Array_Type, node);
            add_decls_from_internal_array_struct(*decls, array_type.resizable, array_type.element_type);

        case .IDENTIFIER;
            identifier := cast(*Identifier, node);
            if identifier.name == "string" {
                internal_string_struct := get_internal_string_struct();
                if internal_string_struct {
                    inner := get_type_fields(internal_string_struct);
                    array_add(*decls, .. inner);
                }
            }

        case .LITERAL;
            literal := cast(*Literal, node);
            if literal.value_type == .STRING {
                internal_string_struct := get_internal_string_struct();
                if internal_string_struct {
                    inner := get_type_fields(internal_string_struct);
                    array_add(*decls, .. inner);
                }
            } else if literal.value_type == .ARRAY {
                array_literal_info := literal.values.array_literal_info;
                add_decls_from_internal_array_struct(*decls, false, array_literal_info.element_type);
            }

        case .DIRECTIVE_IMPORT;
            import := cast(*Directive_Import) node;
            module_file_path := get_module_import_path(import, node.location.file);
            module_file := get_file(module_file_path);
            if module_file {
                for get_declarations(module_file, only_loaded=true) {
                    array_add(*decls, it);
                }
            }
    }

    return decls;
}

handle_completitions_for_node :: (request: LSP_Request_Message_Completion, node: *Node) -> bool {
    decls := get_type_fields(node);
    if decls.count == 0 {
        return false;
    }
    send_completions_decls(request, decls);
    return true;
}

add_basic_keywords :: (completions: *[..]LSP_Completion_Item) {
    array_add(completions, .{label="string", insertText="string", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="bool", insertText="bool", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="int", insertText="int", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="s64", insertText="s64", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="s32", insertText="s32", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="s16", insertText="s16", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="s8", insertText="s8", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="u8", insertText="u8", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="u16", insertText="u16", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="u32", insertText="u32", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="u64", insertText="u64", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="float", insertText="float", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="float32", insertText="float32", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="float64", insertText="float64", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="Any", insertText="Any", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});

    array_add(completions, .{label="struct", insertText="struct", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="enum", insertText="enum", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="enum_flags", insertText="enum_flags", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});

    array_add(completions, .{label="return", insertText="return", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="break", insertText="break", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="case", insertText="case", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="remove", insertText="remove", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="continue", insertText="continue", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="if", insertText="if", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="else", insertText="else", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="for", insertText="for", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="then", insertText="then", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
    array_add(completions, .{label="using", insertText="using", kind=cast(u8) LSP_Completion_Item.Kind.Keyword});
}

get_comment_before_decl :: (file: *Program_File, decl: *Declaration) -> string {
    if !file || file.comments.count == 0 return "";

    decl_line := decl.location.l0;
    collected: [..]string;
    defer array_free(collected);

    // Expected line where the comment's last content line should be:
    // Jai lexer sets l1 to line AFTER consuming newline, so effective last line is l1 - 1.
    expect_line := decl_line - 1;
    i := file.comments.count - 1;
    while i >= 0 {
        comment := file.comments[i];
        i -= 1;

        // comment.l1 is the line after the newline was consumed
        // effective last line of content = l1 - 1
        comment_last_line := comment.l1 - 1;

        // Skip comments that end on or after the declaration line
        if comment_last_line >= decl_line continue;

        gap := expect_line - comment_last_line;
        if gap == 0 {
            // Comment ends on expected line — include if standalone (not trailing inline)
            if comment.c0 < 8 {
                // Strip leading whitespace
                text := comment.string_value;
                start := 0;
                while start < text.count && text[start] <= #char " " { start += 1; }
                if start < text.count {
                    trimmed: string;
                    trimmed.data = text.data + start;
                    trimmed.count = text.count - start;
                    array_add(*collected, copy_string(trimmed));
                }
                expect_line = comment_last_line - 1;
            }
            // else: inline comment (trailing after code) — skip, don't break
        } else if gap > 0 && collected.count > 0 {
            break;  // blank line separates doc block from declaration
        }
    }

    if collected.count == 0 return "";

    array_reverse(collected);

    builder: String_Builder;
    first := true;
    for collected {
        if !first append(*builder, "\n");
        first = false;
        append(*builder, it);
    }
    return builder_to_string(*builder);
}

send_completions_decls :: (request: LSP_Request_Message_Completion, decls: []*Declaration, should_add_basic_keywords := false, file: *Program_File = null, prefix: string = "") {
    completions: [..]LSP_Completion_Item;
    defer array_free(completions);

    if should_add_basic_keywords {
        add_basic_keywords(*completions);
    }

    ast_print_to_string :: (node: *Node) -> string {
        builder: String_Builder;
        ast_print(*builder, node); // @Memory @TODO: we need to free this afterwards!!
        return builder_to_string(*builder);
    }

    truncated := false;
    for decl: decls {
        if !decl.expression && !decl.type_inst continue;

        // Filter by what user typed. Empty prefix = no filter.
        if prefix.count > 0 && !begins_with(decl.name, prefix) continue;

        preview_node: *Node;
        if decl.expression {
            preview_node = decl.expression;
        } else {
            preview_node = decl.type_inst;
        }

        item: LSP_Completion_Item;
        item.label = decl.name;
        item.insertText = decl.name;
        item.insertTextFormat=xx LSP_Completion_Item.Insert_Text_Format.SNIPPET;
        item.labelDetails.description = "---";
        item.documentation = get_comment_before_decl(file, decl);

        if preview_node.kind == {
            case .PROCEDURE;
                item.kind = xx LSP_Completion_Item.Kind.Function;
                procedure := cast(*Procedure) preview_node;
                item.deprecated = procedure.deprecated_note.count > 0;

                if server.user_options.auto_insert_parentheses {
                    item.insertText = sprint("%($0)", decl.name);
                } else {
                    item.insertText = decl.name;
                }

                item.labelDetails.description = ast_print_to_string(preview_node);

            case .STRUCT;
                item.kind = xx LSP_Completion_Item.Kind.Struct;
                item.labelDetails.description = "struct";

            case .ENUM;
                item.kind = xx LSP_Completion_Item.Kind.Enum;
                item.labelDetails.description = "enum";

            case;
                item.kind = xx LSP_Completion_Item.Kind.Variable;
                item.labelDetails.description = ast_print_to_string(preview_node);
        }

        array_add(*completions, item);

        // Safety cap: if prefix-filtered results still exceed MAX_COMPLETIONS,
        // mark incomplete so the client re-requests as user types more.
        if completions.count >= MAX_COMPLETIONS {
            truncated = true;
            break;
        }
    }

    if truncated {
        lsp_respond(request.id, LSP_Completion_List.{isIncomplete=true, items=completions});
    } else {
        lsp_respond(request.id, completions);
    }
}
