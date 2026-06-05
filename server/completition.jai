
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
    dot_ok := false;
    dot_fields: [..]*Declaration;
    // (dot_fields populated by handle_dot_completitions below)

    if cursor_node {
        // We don't wanna to give completions inside strings.
        if cursor_node.kind == .DIRECTIVE_STRING || (cursor_node.kind == Node.Kind.LITERAL && cursor_node.(*Literal).value_type == .STRING) {
            lsp_respond(request.id, null);
            return;
        }

        if cursor_node.kind == .DIRECTIVE_IMPORT {
            handle_completitions_import(request, xx cursor_node);
            return;
        }

        if cursor_node.kind == .DIRECTIVE_LOAD {
            handle_completitions_load(request, file, xx cursor_node);
            return;
        }

        dot_ok, dot_fields = handle_dot_completitions(request, cursor_node, cursor_location);

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

    // General
    decls := get_declarations(file, cursor_node, *cursor_location);

    // Prepend type fields from dot completions (e.g. my_var. → fields first)
    if dot_ok && dot_fields.count > 0 {
        combined: [..]*Declaration;
        array_add(*combined, .. dot_fields);
        array_add(*combined, .. decls);
        decls = combined;
    }

    // Extract prefix: what user has typed so far.
    // If cursor is on an IDENTIFIER, its name is the partial word.
    prefix: string;
    if cursor_node && cursor_node.kind == .IDENTIFIER {
        ident := cast(*Identifier) cursor_node;
        prefix = ident.name;
    }

    send_completions_decls(request, decls, should_add_basic_keywords=true, file=file, prefix=prefix);
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

    array_add(*path, root_binary_op.left);

    current := root_binary_op.parent;
    while current && current.kind == .BINARY_OPERATION {
        current_op := cast(*Binary_Operation) current;
        if current_op.operation != .DOT {
            break;
        }

        if current_op.left {
            array_add(*path, current_op.left);
        }

        current = current.parent;
    }

    array_reverse(path);

    type := get_path_type(path);
    if !type {
        return false, empty;
    }

    fields := get_type_fields(type);
    if fields.count > 0 {
        return true, fields;
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
            add_all_fields_of(*decls, node);

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
